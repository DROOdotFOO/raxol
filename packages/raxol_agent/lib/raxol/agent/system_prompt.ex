defmodule Raxol.Agent.SystemPrompt do
  @moduledoc """
  Resolver for agent system prompts — the seam between *which prompt*
  (a source spec) and *the bytes the backend sends*.

  ## Sources

    * `:none` — no system prompt (resolves to `{:ok, :none}`)
    * `{:text, binary}` — inline text, passed through verbatim
    * `{:file, path}` — a prompt file, read verbatim (no assembly)
    * `:bonded` — the bonded-harness package's Layer-0 core prompt
      (`docs/proposals/bonded-harness/core.prompt.md`), assembled per the
      package's own instructions (below)

  The enum is deliberately extensible: a future `:bonded_subagent` arm will
  load the package's `subagent.prompt.md` (worker-tier, rules-only — the
  package's "persona never inherited" law). It is not implemented yet
  because nothing spawns subagents through this seam.

  ## The bonded prompt (`:bonded`)

  Assembly follows exactly what the package's `slots.md` prescribes for
  using the core prompt as a live harness prompt: strip the leading HTML
  comment header, substitute the `{{NAME}}` / `{{OPERATOR_ROLE}}` /
  `{{DOMAIN}}` / `{{SIGNATURE}}` slots. The default fill is the package's
  tested reference instantiation (AX-7); override per-slot via the
  `:slots` option. Any slot token left unfilled after substitution is an
  error, never silently shipped.

  DISCLOSED LIMIT: the package's per-session conditional assembly
  (`conditional.md` — Layer 1 memory contract, Layer 2 env/tool sections,
  Layer 3 reminders) is NOT assembled here. This is the Layer-0 core prompt
  alone — the standalone fill `slots.md` documents as tested on a live
  harness ("Using it as a live harness prompt").

  ## Locating the bonded package file

  In order, first hit wins:

  1. `RAXOL_BONDED_PROMPT` env var — authoritative when set: a missing file
     is an error, never a silent fallback to scanning
  2. `config :raxol_agent, :bonded_prompt_path` — same authority rule
  3. `docs/proposals/bonded-harness/core.prompt.md` under the cwd
  4. the same path under `../..` (running from a `packages/*` dir)

  ## Caching and identity

  File-backed resolutions (`:bonded`, `{:file, _}`) are cached at first
  resolve — no file read per turn. Every non-`:none` resolution carries its
  identity (`name`, `bytes`, `sha256`); `identity_line/1` renders it for a
  POST card / `--debug` output so the operator can verify WHICH prompt is
  live.
  """

  @bonded_relative_path "docs/proposals/bonded-harness/core.prompt.md"
  @cache_key {__MODULE__, :cache}

  @reference_slots %{
    "NAME" => "AX-7",
    "OPERATOR_ROLE" => "Operator",
    "DOMAIN" => "build",
    "SIGNATURE" => "I have accounted for that"
  }

  @typedoc "Where a system prompt comes from."
  @type source :: :none | :bonded | {:file, Path.t()} | {:text, binary()}

  @typedoc "A resolved prompt with its verifiable identity."
  @type resolved :: %{
          text: binary(),
          name: String.t(),
          bytes: non_neg_integer(),
          sha256: String.t(),
          source: source()
        }

  @doc """
  Resolve a source spec to prompt text plus identity.

  Returns `{:ok, :none}` for `:none`, `{:ok, resolved}` otherwise, or
  `{:error, reason}` — never a silently-empty prompt.

  Options:

    * `:slots` — map of slot overrides for `:bonded` (keys `"NAME"`,
      `"OPERATOR_ROLE"`, `"DOMAIN"`, `"SIGNATURE"`; atoms are upcased),
      merged over the AX-7 reference fill
    * `:cache` — set `false` to bypass the file cache (default `true`)
  """
  @spec resolve(source(), keyword()) ::
          {:ok, :none} | {:ok, resolved()} | {:error, term()}
  def resolve(source, opts \\ [])

  def resolve(:none, _opts), do: {:ok, :none}

  def resolve({:text, text}, _opts) when is_binary(text) do
    {:ok, build_resolved(text, "inline", {:text, text})}
  end

  def resolve({:file, path}, opts) when is_binary(path) do
    expanded = Path.expand(path)

    cached({:file, expanded}, opts, fn ->
      case File.read(expanded) do
        {:ok, text} ->
          {:ok, build_resolved(text, "file:" <> Path.basename(expanded), {:file, path})}

        {:error, posix} ->
          {:error, {posix, expanded}}
      end
    end)
  end

  def resolve(:bonded, opts) do
    slots = normalize_slots(Keyword.get(opts, :slots, %{}))

    # The cache key uses the CONFIGURED location (cheap env/app-env read),
    # not the located file: locating stats the filesystem, and the whole
    # point of the cache is that a resolved prompt costs zero I/O per turn.
    key = {:bonded, configured_bonded_path() || :scan, slots}

    cached(key, opts, fn ->
      with {:ok, path} <- bonded_path() do
        assemble_bonded(path, slots)
      end
    end)
  end

  def resolve(other, _opts), do: {:error, {:unknown_source, other}}

  @doc """
  Locate the bonded package's core prompt file. `{:ok, path}` or an error:
  `{:configured_missing, path}` when an explicit env/config location points
  at nothing (authoritative — no fallback), `{:bonded_not_found, candidates}`
  when nothing is configured and no candidate exists.
  """
  @spec bonded_path() :: {:ok, Path.t()} | {:error, term()}
  def bonded_path do
    case configured_bonded_path() do
      path when is_binary(path) ->
        expanded = Path.expand(path)

        if File.regular?(expanded) do
          {:ok, expanded}
        else
          {:error, {:configured_missing, expanded}}
        end

      nil ->
        candidates = [
          Path.expand(@bonded_relative_path),
          Path.expand(Path.join("../..", @bonded_relative_path))
        ]

        case Enum.find(candidates, &File.regular?/1) do
          nil -> {:error, {:bonded_not_found, candidates}}
          path -> {:ok, path}
        end
    end
  end

  @doc "Whether the bonded package's core prompt is locatable right now."
  @spec bonded_available?() :: boolean()
  def bonded_available? do
    match?({:ok, _}, bonded_path())
  end

  @doc """
  One line naming the live prompt for a POST card / `--debug` output:
  `"none"`, or `"<name> · <bytes> bytes · sha256:<12 hex>"`.
  """
  @spec identity_line(:none | resolved()) :: String.t()
  def identity_line(:none), do: "none"

  def identity_line(%{name: name, bytes: bytes, sha256: sha256}) do
    "#{name} · #{bytes} bytes · sha256:#{String.slice(sha256, 0, 12)}"
  end

  @doc "Drop all cached resolutions (test isolation)."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.put(@cache_key, %{})
    :ok
  end

  # -- bonded assembly (slots.md: strip the comment header, fill the slots) ---

  defp assemble_bonded(path, slots) do
    with {:ok, raw} <- read_file(path) do
      text =
        raw
        |> strip_comment_header()
        |> fill_slots(slots)

      case unfilled_slots(text) do
        [] ->
          name = "bonded:#{Path.basename(path)}@#{Map.fetch!(slots, "NAME")}"
          {:ok, build_resolved(text, name, :bonded)}

        missing ->
          {:error, {:unfilled_slots, missing}}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, posix} -> {:error, {posix, path}}
    end
  end

  defp strip_comment_header("<!--" <> _ = text) do
    case String.split(text, "-->", parts: 2) do
      [_header, rest] -> String.trim_leading(rest)
      _unterminated -> text
    end
  end

  defp strip_comment_header(text), do: text

  defp fill_slots(text, slots) do
    Enum.reduce(slots, text, fn {name, value}, acc ->
      String.replace(acc, "{{#{name}}}", value)
    end)
  end

  defp unfilled_slots(text) do
    ~r/\{\{([A-Z_]+)\}\}/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp normalize_slots(slots) when is_map(slots) do
    overrides =
      Map.new(slots, fn {key, value} ->
        {key |> to_string() |> String.upcase(), to_string(value)}
      end)

    Map.merge(@reference_slots, overrides)
  end

  # -- identity ----------------------------------------------------------------

  defp build_resolved(text, name, source) do
    %{
      text: text,
      name: name,
      bytes: byte_size(text),
      sha256: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower),
      source: source
    }
  end

  # -- cache -------------------------------------------------------------------

  defp cached(key, opts, fun) do
    if Keyword.get(opts, :cache, true) do
      cache = :persistent_term.get(@cache_key, %{})

      case Map.fetch(cache, key) do
        {:ok, result} ->
          result

        :error ->
          result = fun.()
          maybe_store(key, result)
          result
      end
    else
      fun.()
    end
  end

  # Only successful resolutions are cached: a transient read failure must not
  # pin the error for the life of the VM.
  defp maybe_store(key, {:ok, _} = result) do
    cache = :persistent_term.get(@cache_key, %{})
    :persistent_term.put(@cache_key, Map.put(cache, key, result))
  end

  defp maybe_store(_key, _error), do: :ok

  defp configured_bonded_path do
    System.get_env("RAXOL_BONDED_PROMPT") ||
      Application.get_env(:raxol_agent, :bonded_prompt_path)
  end
end
