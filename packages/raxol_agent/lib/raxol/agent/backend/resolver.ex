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

  ## Auto-detection never spends

  Auto-detection considers only providers that cost nothing per request: a
  subscription the user already holds, a local server, or a free tier.
  Providers billed in API credits are skipped even when fully configured, so
  an unattended run cannot quietly draw down a prepaid balance. Reaching one
  is explicit: name it (`--backend openrouter`, `harness: :openrouter`) or set
  `RAXOL_ALLOW_PAID_API=1` to restore the walk-everything order.

  A backend the catalog marks `detectable?: false` is skipped by the walk
  regardless of billing, and stays fully nameable. The registry itself is a
  projection of `Raxol.Agent.Backend.Catalog` rather than a second list, which
  is what makes every catalog entry reachable by name (ADR-0034).
  """

  alias Raxol.Agent.Backend.Catalog
  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.ExecutorConfig

  # What one `op read` may cost inside `diagnostics/0`.
  #
  # Deliberately far below the 15s interactive default, which is sized so a
  # human can approve a 1Password prompt. Nobody is on the other side of
  # `/inspect`, so the only thing that budget buys there is a wait for an
  # approval that is not coming. And because a timeout demotes `op` to
  # `:unresponsive` for the rest of the sweep, this is the ceiling for the whole
  # diagnostic rather than the price of each provider.
  @diagnostic_op_timeout_ms 1_500

  # Provider registry, PROJECTED from `Raxol.Agent.Backend.Catalog` rather than
  # declared here. ADR-0034 measured this list, the selector's module table and
  # `ExecutorConfig.backend()` disagreeing about which backends exist: `:cursor`
  # was selectable in code and unnameable through `@by_string` below, purely
  # because the hand-written copy that used to live here had never gained it. A
  # filter cannot fall out of date the way a copy did.
  #
  # `keyless: true` providers need no API key (local servers, the free LLM7
  # endpoint, Mock), which is exactly "the catalog declares no env keys for it";
  # `env_keys` are checked in order. `native_module` is set only for native
  # harnesses, because its PRESENCE is what routes `detect_available/2` to the
  # vendor-CLI probe instead of key resolution.
  @providers Enum.map(Catalog.by_kind([:http, :native, :mock]), fn entry ->
               spec = %{
                 harness: entry.id,
                 label: entry.label,
                 env_keys: entry.env_keys,
                 model_env: entry.model_env,
                 keyless: entry.env_keys == [],
                 billing: entry.billing,
                 detectable?: entry.detectable?
               }

               if entry.kind == :native,
                 do: Map.put(spec, :native_module, entry.module),
                 else: spec
             end)

  # Detection walks this list top-to-bottom, and a keyless local provider is
  # only auto-selected when the user has explicitly stored a reference for it.
  # A backend the catalog marks undetectable is absent HERE and still present in
  # `@providers`, so it stays nameable while never being chosen on the user's
  # behalf by a PATH probe.
  #
  # `billing` is what auto-detection routes on. `:api_credits` means a request
  # draws down a prepaid balance, so those are NEVER auto-selected -- reaching
  # one takes an explicit `--backend`/`harness:` or `RAXOL_ALLOW_PAID_API=1`.
  # Everything else is already paid for: a `:subscription` the user holds, a
  # `:local` server, or a `:free` tier. Ordering still matters within the
  # allowed set, and the subscription harness comes first because it is the
  # one that costs nothing extra AND is a frontier model.
  @detectable_providers Enum.filter(@providers, & &1.detectable?)

  @by_string Map.new(@providers, &{to_string(&1.harness), &1.harness})

  @type source :: :explicit | :op | :env | :generic | :configured | :subscription
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
    opts = seal_internal_opts(opts)

    case explicit_harness(opts) do
      nil -> auto_detect(opts)
      harness -> resolve_explicit(harness, opts)
    end
  end

  # `:skip_op` is INTERNAL to the diagnostic path and is dropped here rather
  # than trusted.
  #
  # It reads as harmless -- "do not shell out to `op`" -- but what it actually
  # does is silence the vault and let resolution fall through to environment
  # variables. A caller that set it, deliberately or by forwarding an opts list
  # it did not audit, would get a credential from `$ANTHROPIC_API_KEY` where the
  # operator had stored an `op://` reference, and nothing would say so. The
  # comment on `resolve_key/2` asserted only this path sets it; a comment is not
  # a boundary, and this function is public.
  @internal_opts [:skip_op]

  defp seal_internal_opts(opts) when is_list(opts),
    do: Keyword.drop(opts, @internal_opts)

  defp seal_internal_opts(opts), do: opts

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

  The `op` state is read ONCE and, when it is unusable, the per-provider `op`
  probes are skipped entirely. See `provider_diag/2`.
  """
  @type diagnostic_op_status :: :absent | :not_signed_in | :ok | :unresponsive

  @spec diagnostics() :: %{op: diagnostic_op_status(), providers: [map()]}
  def diagnostics do
    op = Credentials.op_status()

    # Threaded, not mapped, so one unresponsive vault stops the sweep.
    #
    # Skipping when `op_status/0` says the CLI is unusable covers signed-out and
    # absent. It does NOT cover the state that is slowest: signed in, so
    # `op whoami` exits 0 and the status reads `:ok`, while every `op read`
    # still waits on a desktop authorization the user has not given. There the
    # skip never fires and each provider pays a full budget in series.
    #
    # A timed-out read is evidence about the VAULT rather than about the
    # provider whose reference happened to be first, so the first one demotes
    # `op` to `:unresponsive` for the rest of the sweep and the others are
    # answered from the same knowledge without paying for it again. Worst case
    # is one diagnostic budget, not one per provider.
    {providers, final_op} =
      Enum.map_reduce(@providers, op, &provider_diag/2)

    %{op: final_op, providers: providers}
  end

  # A stored `op://` reference cannot resolve while the CLI is absent or signed
  # out, so probing one here is a shell-out per provider that is guaranteed to
  # fail. Against a LOCKED vault each probe additionally raises a desktop
  # authorization prompt and then waits out the full `op` timeout, and there is
  # one per provider: measured, that turned `/inspect` into a 12-to-22 second
  # stall where `op_status/0` alone accounted for under 7s of it.
  #
  # Skipping costs no information. `diag_note/3` already answers a stored
  # reference under a signed-out CLI with "run `op signin`" -- the same
  # conclusion the probe spends 15 seconds arriving at.
  defp provider_diag(spec, op) do
    {op_result, op} = probe_op_ref(spec, op)
    {available?, source} = diag_availability(spec, op_result)

    diag = %{
      harness: spec.harness,
      label: spec.label,
      keyless?: spec.keyless,
      available?: available?,
      source: source,
      note: diag_note(spec, available?, op)
    }

    {diag, op}
  end

  # The diagnostic owns the `op` probe outright, rather than letting
  # `resolve_key/2` do it: only from here can a timeout be seen for what it is
  # and charged to the vault instead of to this provider.
  #
  # A diagnostic budget rather than the interactive one. The 15s default is
  # sized so a human can approve a 1Password prompt; nobody is waiting on the
  # other side of `/inspect`, and the wait it buys is a wait for an approval
  # that is not coming.
  defp probe_op_ref(spec, op) do
    ref = op_ref(spec.harness)

    cond do
      op != :ok -> {:skipped, op}
      is_nil(ref) -> {:skipped, op}
      true -> read_diag_ref(ref, op)
    end
  end

  defp read_diag_ref(ref, op) do
    case Credentials.read_ref(ref, timeout_ms: @diagnostic_op_timeout_ms) do
      {:ok, secret} -> {{:ok, secret}, op}
      # Evidence about the vault, not about this provider: demote once so the
      # remaining providers are answered without each paying the budget again.
      {:error, :op_timeout} -> {:unresponsive, :unresponsive}
      {:error, _other} -> {:failed, op}
    end
  end

  # `skip_op: true` unconditionally, because `probe_op_ref/2` has already had
  # its turn. Letting `resolve_key/2` try again would spend a second budget to
  # reach the answer we are already holding.
  defp diag_availability(_spec, {:ok, _secret}), do: {true, :op}

  defp diag_availability(spec, _op_result) do
    case detect_available(spec, skip_op: true) do
      {:ok, _config, src} -> {true, src}
      _ -> {false, nil}
    end
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

  defp op_hint(:unresponsive),
    do: "op reference stored, but the vault did not answer -- unlock 1Password"

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

  # Auto-detection never spends money. A provider billed in `:api_credits` is
  # skipped no matter how well configured it is -- including the generic
  # `AI_API_KEY` endpoint, which is someone's prepaid balance too. Naming one
  # explicitly (`--backend openrouter`, `harness:`) still works and is the
  # opt-in; `RAXOL_ALLOW_PAID_API=1` restores the old walk-everything order for
  # a deployment that wants it. Without this, a stored OpenRouter key outranked
  # an installed, already-paid-for Claude subscription on every single turn.
  defp auto_detect(opts) do
    Enum.find_value(auto_detect_providers(), fn spec ->
      ok_or_nil(detect_available(spec, opts))
    end) ||
      auto_detect_generic(opts) ||
      :no_provider
  end

  defp auto_detect_providers do
    if paid_api_allowed?(),
      do: @detectable_providers,
      else: Enum.reject(@detectable_providers, &(&1.billing == :api_credits))
  end

  defp auto_detect_generic(opts) do
    if paid_api_allowed?(), do: detect_generic(opts), else: nil
  end

  # Whether the vendor CLI behind a native harness is installed and signed in.
  # Auto-detection would otherwise depend on what happens to be on the host's
  # PATH, which no test can control: `:native_probe` is the seam that makes
  # resolution deterministic. It takes a boolean (the whole answer) or a
  # 1-arity fun receiving the backend module; unset means ask the CLI.
  defp native_available?(mod) do
    case Application.get_env(:raxol_agent, :native_probe) do
      probe when is_function(probe, 1) -> probe.(mod)
      answer when is_boolean(answer) -> answer
      _unset -> Code.ensure_loaded?(mod) and mod.available?()
    end
  end

  @doc """
  Whether auto-detection may select a provider billed in API credits.

  False unless `RAXOL_ALLOW_PAID_API` is set to a truthy value. An explicitly
  named harness bypasses this entirely -- it is the user asking for that
  provider by name, which is itself the opt-in.
  """
  @spec paid_api_allowed?() :: boolean()
  def paid_api_allowed? do
    case System.get_env("RAXOL_ALLOW_PAID_API") do
      nil -> false
      value -> String.trim(value) in ["1", "true", "TRUE", "yes"]
    end
  end

  defp ok_or_nil({:ok, _config, _source} = ok), do: ok
  defp ok_or_nil(_), do: nil

  # A provider is auto-available when it resolves a key, or — for a keyless
  # provider — only when the user has stored a reference for it (so a bare
  # localhost server is never silently selected as the default).
  # A native harness is available when its CLI is on PATH -- that CLI holds the
  # subscription, so there is no key here to resolve and nothing to store.
  # Unlike the keyless local servers below it needs no `configured?/1` opt-in:
  # an installed vendor CLI is a deliberate act, not a stray localhost port that
  # could be anything. Note the probe is presence, not sign-in: a CLI installed
  # but never logged into resolves here and then fails at run time with its own
  # auth message, which is a clearer signal than silently falling through.
  defp detect_available(%{native_module: mod} = spec, opts) do
    if native_available?(mod) do
      {:ok, build_config(spec.harness, nil, resolve_model(spec, opts), nil), :subscription}
    else
      :none
    end
  end

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

  # `:skip_op` is set only by `provider_diag/2`. The resolution path proper never
  # skips: a user actually starting a turn wants their stored key read, and is
  # willing to wait for an unlock prompt to do it. A diagnostic is not.
  defp resolve_key(spec, opts) do
    first_ok([
      fn -> explicit_key(opts) end,
      fn -> if Keyword.get(opts, :skip_op, false), do: :none, else: op_key(spec) end,
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
