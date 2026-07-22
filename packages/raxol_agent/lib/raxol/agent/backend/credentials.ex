defmodule Raxol.Agent.Backend.Credentials do
  @moduledoc """
  1Password-first credential *reference* store for agent LLM providers.

  This stores only references, never raw keys: a small JSON map at
  `~/.raxol/providers.json` (override with `$RAXOL_PROVIDERS`) that ties a
  provider harness to a `op://...` 1Password reference plus an optional model
  and base URL. Resolving a reference shells out to the `op` CLI
  (`op read op://...`), so the secret is fetched fresh at launch and no
  plaintext key ever touches disk.

  A raw key can still be supplied per session (an env var, or `/login` in the
  coding TUI), but such a key is held in memory only and is never written here.

  ## File shape

      {
        "anthropic": {"op_ref": "op://Employee/Anthropic/api_key", "model": "claude-sonnet-5"},
        "openai":    {"op_ref": "op://Employee/OpenAI/api_key"}
      }

  Only the three known string fields (`op_ref`, `model`, `base_url`) round-trip;
  the top-level keys are provider harness names, kept as strings on disk and
  mapped back to known atoms by `Raxol.Agent.Backend.Resolver` (never
  `String.to_atom/1` on file input).
  """

  @env_path "RAXOL_PROVIDERS"
  @filename "providers.json"

  @type ref_entry :: %{
          optional(:op_ref) => String.t(),
          optional(:model) => String.t(),
          optional(:base_url) => String.t()
        }

  @doc "The reference-store path (`$RAXOL_PROVIDERS` or `~/.raxol/providers.json`)."
  @spec path() :: String.t()
  def path do
    case System.get_env(@env_path) do
      p when is_binary(p) and p != "" -> p
      _ -> Path.join(home_base(), Path.join(".raxol", @filename))
    end
  end

  defp home_base, do: System.user_home() || System.tmp_dir!()

  @doc """
  Load the reference map keyed by provider-harness string.

  A missing or unreadable file is an empty map, not an error: the resolver
  simply falls through to env vars. A malformed file logs nothing and yields
  `%{}` so a corrupt store never crashes agent boot.
  """
  @spec load() :: %{optional(String.t()) => ref_entry()}
  def load do
    with {:ok, raw} <- File.read(path()),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      Enum.reduce(decoded, %{}, &put_sanitized/2)
    else
      _ -> %{}
    end
  end

  defp put_sanitized({provider, entry}, acc) do
    case sanitize_entry(entry) do
      sanitized when map_size(sanitized) == 0 -> acc
      sanitized -> Map.put(acc, to_string(provider), sanitized)
    end
  end

  # Keep only the three known string fields; drop everything else so a
  # hand-edited file can never smuggle unexpected shapes downstream.
  defp sanitize_entry(entry) when is_map(entry) do
    ~w(op_ref model base_url)
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(entry, field) do
        value when is_binary(value) and value != "" ->
          Map.put(acc, String.to_existing_atom(field), value)

        _ ->
          acc
      end
    end)
  end

  defp sanitize_entry(_entry), do: %{}

  @doc """
  Look up the stored reference entry for a provider harness.

  Returns `{:ok, entry}` when present, `:none` otherwise.
  """
  @spec fetch(atom() | String.t()) :: {:ok, ref_entry()} | :none
  def fetch(harness) do
    case Map.fetch(load(), to_string(harness)) do
      {:ok, entry} -> {:ok, entry}
      :error -> :none
    end
  end

  @doc """
  Store (or replace) a provider's reference entry and persist to disk.

  `attrs` accepts `:op_ref`, `:model`, and `:base_url`; a raw key is refused
  here on purpose (this store never holds secrets). The file is written with
  owner-only (`0600`) permissions.
  """
  @spec put(atom() | String.t(), keyword() | map()) :: :ok | {:error, term()}
  def put(harness, attrs) do
    entry = sanitize_entry(stringify_keys(attrs))

    if map_size(entry) == 0 do
      {:error, :empty_entry}
    else
      updated = Map.put(load(), to_string(harness), entry)
      write(updated)
    end
  end

  @doc "Remove a provider's stored reference entry."
  @spec delete(atom() | String.t()) :: :ok | {:error, term()}
  def delete(harness) do
    load() |> Map.delete(to_string(harness)) |> write()
  end

  defp write(map) do
    file = path()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         encoded = Jason.encode!(map, pretty: true),
         :ok <- File.write(file, encoded) do
      # Owner read/write only: the file holds references, but they still name
      # a person's vault items and should not be world-readable.
      _ = File.chmod(file, 0o600)
      :ok
    end
  end

  defp stringify_keys(attrs) when is_list(attrs) or is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "True when the `op` (1Password) CLI is available on PATH."
  @spec op_available?() :: boolean()
  def op_available?, do: not is_nil(System.find_executable("op"))

  @doc """
  Resolve a `op://...` reference to its secret via the 1Password CLI.

  Returns `{:ok, secret}` (trimmed), or `{:error, reason}` when `op` is
  missing, not signed in, or the reference does not resolve. The secret is
  returned to the caller and never logged or persisted here.
  """
  @spec read_ref(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_ref("op://" <> _ = ref) do
    if op_available?() do
      "op" |> System.cmd(["read", ref], stderr_to_stdout: true) |> interpret_op_output()
    else
      {:error, :op_unavailable}
    end
  end

  def read_ref(_other), do: {:error, :not_an_op_ref}

  defp interpret_op_output({out, 0}) do
    case String.trim(out) do
      "" -> {:error, :empty_secret}
      secret -> {:ok, secret}
    end
  end

  defp interpret_op_output({out, code}), do: {:error, {:op_failed, code, String.trim(out)}}
end
