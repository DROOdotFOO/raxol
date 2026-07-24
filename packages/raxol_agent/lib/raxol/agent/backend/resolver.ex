defmodule Raxol.Agent.Backend.Resolver do
  @moduledoc """
  Single source of truth for "which provider, which key, which model" —
  turning the user's environment and stored references into a ready
  `Raxol.Agent.ExecutorConfig`.

  This replaces the per-example `cond` blocks that each re-read env vars, and
  fills the gap that left `mix raxol.code` blind (it defaulted to a local
  server and never populated `auth`). Every agent surface — the coding TUI,
  the agent framework, the MCP/headless default — resolves credentials here so
  provider onboarding has one shape.

  ## Precedence

  For an explicit `:harness`, the key is resolved in this order:

    1. an explicit `:api_key` opt,
    2. a 1Password reference (from `Raxol.Agent.Backend.Credentials` or a
       `RAXOL_<HARNESS>_OP` env var) read via the `op` CLI,
    3. the provider's env var(s) (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...).

  With no `:harness`, `resolve/1` auto-detects: it walks the provider registry
  and returns the first provider that resolves a key (or a stored keyless
  provider), then falls back to the generic `AI_API_KEY`/`AI_BASE_URL` trio,
  and finally `:no_provider` — the honest signal that the caller should show a
  setup prompt rather than crash against a placeholder endpoint.
  """

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.ExecutorConfig

  # Provider registry. `keyless: true` providers need no API key (local
  # servers, the free LLM7 endpoint, Mock); `env_keys` are checked in order.
  # Detection walks this list top-to-bottom, so hosted/keyed providers rank
  # ahead of local ones — a keyless provider is only auto-selected when the
  # user has explicitly stored a reference for it.
  @providers [
    %{
      harness: :anthropic,
      label: "Anthropic (Claude)",
      env_keys: ["ANTHROPIC_API_KEY"],
      model_env: "ANTHROPIC_MODEL",
      keyless: false
    },
    %{
      harness: :openai,
      label: "OpenAI",
      env_keys: ["OPENAI_API_KEY"],
      model_env: "OPENAI_MODEL",
      keyless: false
    },
    %{
      harness: :kimi,
      label: "Kimi (Moonshot)",
      env_keys: ["KIMI_API_KEY", "MOONSHOT_API_KEY"],
      model_env: "KIMI_MODEL",
      keyless: false
    },
    %{
      harness: :openrouter,
      label: "OpenRouter",
      env_keys: ["OPENROUTER_API_KEY"],
      model_env: "OPENROUTER_MODEL",
      keyless: false
    },
    %{
      harness: :longcat,
      label: "LongCat (Meituan)",
      env_keys: ["LONGCAT_API_KEY"],
      model_env: "LONGCAT_MODEL",
      keyless: false
    },
    %{
      harness: :lumo,
      label: "Proton Lumo",
      env_keys: ["PROTON_ACCESS_TOKEN"],
      model_env: nil,
      keyless: false
    },
    %{
      harness: :ollama,
      label: "Ollama (local)",
      env_keys: [],
      model_env: "OLLAMA_MODEL",
      keyless: true
    },
    %{
      harness: :lm_studio,
      label: "LM Studio (local)",
      env_keys: [],
      model_env: nil,
      keyless: true
    },
    %{harness: :llm7, label: "LLM7 (free, no key)", env_keys: [], model_env: nil, keyless: true},
    %{harness: :mock, label: "Mock (offline)", env_keys: [], model_env: nil, keyless: true}
  ]

  @by_string Map.new(@providers, &{to_string(&1.harness), &1.harness})

  @type source :: :explicit | :op | :env | :generic | :configured
  @type resolution ::
          {:ok, ExecutorConfig.t(), source()}
          | {:no_key, atom()}
          | :no_provider

  @doc """
  Resolve `opts` to `{:ok, config, source}`, `{:no_key, harness}`, or
  `:no_provider`.

  Recognized opts: `:harness` (atom or string), `:api_key`, `:model`,
  `:base_url`. A `{:no_key, harness}` means the harness was named explicitly
  but no credential could be resolved for it.
  """
  @spec resolve(keyword()) :: resolution()
  def resolve(opts \\ []) do
    case explicit_harness(opts) do
      nil -> auto_detect(opts)
      harness -> resolve_explicit(harness, opts)
    end
  end

  @doc """
  Per-provider availability, for the setup panel and `/login` status.

  Each entry is `%{harness, label, keyless?, available?, source}` where
  `source` is the resolution source when available, else `nil`. Availability
  probing may shell out to `op` for stored references, so treat this as a
  point-in-time snapshot rather than a hot path.
  """
  @spec status() :: [map()]
  def status do
    Enum.map(@providers, fn spec ->
      {available?, source} =
        case detect_available(spec, []) do
          {:ok, _config, src} -> {true, src}
          _ -> {false, nil}
        end

      %{
        harness: spec.harness,
        label: spec.label,
        keyless?: spec.keyless,
        available?: available?,
        source: source
      }
    end)
  end

  @doc "The provider registry as `%{harness, label, keyless?}` entries."
  @spec providers() :: [map()]
  def providers do
    Enum.map(@providers, &%{harness: &1.harness, label: &1.label, keyless?: &1.keyless})
  end

  @doc """
  Detection diagnostics for the setup panel: the `op` CLI state plus, per
  provider, an actionable `note` when it is unavailable (a stored `op://`
  reference that needs `op signin`, or an env var that is set but empty).

  Returns `%{op: op_status, providers: [%{harness, label, keyless?,
  available?, source, note}]}`. Probing may shell out to `op` for stored
  references, so treat it as a point-in-time snapshot.
  """
  @spec diagnostics() :: %{op: atom(), providers: [map()]}
  def diagnostics do
    op = Credentials.op_status()
    %{op: op, providers: Enum.map(@providers, &provider_diag(&1, op))}
  end

  defp provider_diag(spec, op) do
    {available?, source} =
      case detect_available(spec, []) do
        {:ok, _config, src} -> {true, src}
        _ -> {false, nil}
      end

    %{
      harness: spec.harness,
      label: spec.label,
      keyless?: spec.keyless,
      available?: available?,
      source: source,
      note: diag_note(spec, available?, op)
    }
  end

  defp diag_note(_spec, true, _op), do: nil

  defp diag_note(spec, false, op) do
    cond do
      op_ref(spec.harness) && op != :ok -> op_hint(op)
      empty_env_key(spec) -> "#{empty_env_key(spec)} is set but empty"
      true -> nil
    end
  end

  defp op_hint(:not_signed_in), do: "op reference stored, run `op signin`"
  defp op_hint(:absent), do: "op reference stored, but the `op` CLI is not installed"
  defp op_hint(_status), do: nil

  defp empty_env_key(%{env_keys: keys}) do
    Enum.find(keys, fn key -> System.get_env(key) == "" end)
  end

  @doc "Map a harness string to its known atom without minting new atoms."
  @spec harness_from_string(String.t()) :: {:ok, atom()} | :error
  def harness_from_string(str) when is_binary(str) do
    case Map.fetch(@by_string, str) do
      {:ok, harness} -> {:ok, harness}
      :error -> :error
    end
  end

  # -- explicit harness -------------------------------------------------------

  defp resolve_explicit(harness, opts) do
    case spec_for(harness) do
      nil ->
        # Unknown to the registry (e.g. a native harness): build a bare config
        # and let the Selector accept or reject it.
        {:ok, build_config(harness, nil, model_opt(opts), base_url_opt(opts)), :explicit}

      spec ->
        resolve_explicit_spec(spec, opts)
    end
  end

  defp resolve_explicit_spec(%{keyless: true} = spec, opts) do
    {:ok, build_config(spec.harness, nil, resolve_model(spec, opts), base_url_opt(opts)),
     :explicit}
  end

  defp resolve_explicit_spec(spec, opts) do
    case resolve_key(spec, opts) do
      {:ok, key, source} ->
        {:ok, build_config(spec.harness, key, resolve_model(spec, opts), base_url_opt(opts)),
         source}

      :none ->
        {:no_key, spec.harness}
    end
  end

  # -- auto detection ---------------------------------------------------------

  defp auto_detect(opts) do
    Enum.find_value(@providers, fn spec -> ok_or_nil(detect_available(spec, opts)) end) ||
      detect_generic(opts) ||
      :no_provider
  end

  defp ok_or_nil({:ok, _config, _source} = ok), do: ok
  defp ok_or_nil(_), do: nil

  # A provider is auto-available when it resolves a key, or — for a keyless
  # provider — only when the user has stored a reference for it (so a bare
  # localhost server is never silently selected as the default).
  defp detect_available(%{keyless: true} = spec, opts) do
    if configured?(spec.harness) do
      {:ok, build_config(spec.harness, nil, resolve_model(spec, opts), stored_base_url(spec)),
       :configured}
    else
      :none
    end
  end

  defp detect_available(spec, opts) do
    case resolve_key(spec, Keyword.delete(opts, :api_key)) do
      {:ok, key, source} ->
        {:ok, build_config(spec.harness, key, resolve_model(spec, opts), stored_base_url(spec)),
         source}

      :none ->
        :none
    end
  end

  # The generic escape hatch: any OpenAI-compatible endpoint via AI_API_KEY
  # (+ optional AI_BASE_URL / AI_MODEL), mapped onto the :openai harness.
  defp detect_generic(opts) do
    case env_first(["AI_API_KEY"]) do
      nil ->
        nil

      key ->
        base_url = Keyword.get(opts, :base_url) || System.get_env("AI_BASE_URL")
        model = Keyword.get(opts, :model) || System.get_env("AI_MODEL")
        {:ok, build_config(:openai, key, model, base_url), :generic}
    end
  end

  # -- key resolution ---------------------------------------------------------

  defp resolve_key(spec, opts) do
    first_ok([
      fn -> explicit_key(opts) end,
      fn -> op_key(spec) end,
      fn -> env_key(spec) end
    ])
  end

  defp first_ok([]), do: :none

  defp first_ok([f | rest]) do
    case f.() do
      {:ok, _key, _source} = ok -> ok
      _ -> first_ok(rest)
    end
  end

  defp explicit_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key, :explicit}
      _ -> :none
    end
  end

  # A 1Password reference from the stored map or a RAXOL_<HARNESS>_OP env var,
  # resolved via the `op` CLI. A missing `op` binary or an unresolved ref
  # falls through to env-var resolution rather than failing.
  defp op_key(spec) do
    case op_ref(spec.harness) do
      nil ->
        :none

      ref ->
        case Credentials.read_ref(ref) do
          {:ok, secret} -> {:ok, secret, :op}
          {:error, _reason} -> :none
        end
    end
  end

  defp op_ref(harness) do
    case Credentials.fetch(harness) do
      {:ok, %{op_ref: ref}} -> ref
      _ -> System.get_env("RAXOL_#{harness |> to_string() |> String.upcase()}_OP")
    end
  end

  defp env_key(%{env_keys: keys}), do: wrap(env_first(keys), :env)

  defp wrap(nil, _source), do: :none
  defp wrap(value, source), do: {:ok, value, source}

  defp env_first(keys) do
    Enum.find_value(keys, fn key ->
      case System.get_env(key) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  # -- config building --------------------------------------------------------

  defp build_config(harness, key, model, base_url) do
    ExecutorConfig.new(
      harness: harness,
      model: model,
      auth: if(is_binary(key) and key != "", do: %{api_key: key}, else: %{}),
      opts: base_url_kw(base_url)
    )
  end

  defp base_url_kw(url) when is_binary(url) and url != "", do: [base_url: url]
  defp base_url_kw(_url), do: []

  # Model precedence: explicit opt > stored entry > provider model env var.
  defp resolve_model(spec, opts) do
    model_opt(opts) || stored_model(spec) || model_env(spec)
  end

  defp model_opt(opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp model_env(%{model_env: env}) when is_binary(env) do
    case System.get_env(env) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp model_env(_spec), do: nil

  defp stored_model(spec), do: stored_field(spec.harness, :model)
  defp stored_base_url(spec), do: stored_field(spec.harness, :base_url)

  defp stored_field(harness, field) do
    case Credentials.fetch(harness) do
      {:ok, entry} -> Map.get(entry, field)
      :none -> nil
    end
  end

  defp base_url_opt(opts), do: Keyword.get(opts, :base_url)

  # -- helpers ----------------------------------------------------------------

  defp configured?(harness) do
    match?({:ok, _}, Credentials.fetch(harness)) or not is_nil(op_ref(harness))
  end

  defp explicit_harness(opts) do
    case Keyword.get(opts, :harness) do
      nil -> nil
      harness when is_atom(harness) -> harness
      harness when is_binary(harness) -> harness_atom(harness)
    end
  end

  defp harness_atom(str) do
    case harness_from_string(str) do
      {:ok, harness} -> harness
      # Unknown string harness: hand it back as-is via a safe existing-atom
      # lookup so the Selector can raise the canonical unknown-harness error.
      :error -> safe_existing_atom(str)
    end
  end

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> :__unknown_harness__
  end

  defp spec_for(harness), do: Enum.find(@providers, &(&1.harness == harness))
end
