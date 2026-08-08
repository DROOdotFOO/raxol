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

  # `System.cmd` has no timeout, and a locked 1Password vault blocks `op`
  # on its desktop-app authorization prompt indefinitely — freezing
  # whatever process asked (the TUI's update loop during /login, every
  # op-shelling test). This Port-based runner bounds the wait and KILLS
  # the OS process on timeout; `Port.close/1` alone would leave the hung
  # `op` (and its auth prompt) alive. Generous default so an interactive
  # signin approval still fits; `RAXOL_OP_TIMEOUT_MS` overrides.
  @op_timeout_ms 15_000

  defp op_timeout_ms do
    case Integer.parse(System.get_env("RAXOL_OP_TIMEOUT_MS") || "") do
      {ms, ""} when ms > 0 -> ms
      _ -> @op_timeout_ms
    end
  end

  defp run_op(args) do
    case System.find_executable("op") do
      nil ->
        {:error, :op_unavailable}

      op ->
        port =
          Port.open(
            {:spawn_executable, op},
            [:binary, :exit_status, :stderr_to_stdout, args: args]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        deadline = System.monotonic_time(:millisecond) + op_timeout_ms()
        collect_op(port, os_pid, deadline, [])
    end
  end

  defp collect_op(port, os_pid, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_op(port, os_pid)
      {:error, :op_timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          collect_op(port, os_pid, deadline, [acc | chunk])

        {^port, {:exit_status, code}} ->
          {IO.iodata_to_binary(acc), code}
      after
        remaining ->
          kill_op(port, os_pid)
          {:error, :op_timeout}
      end
    end
  end

  defp kill_op(port, os_pid) do
    kill_os_process(os_pid)

    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    # Anything the port delivered between the deadline firing and the
    # close stays in the CALLER's mailbox (the TUI's dispatcher during
    # /login) — including a {:data, secret} the child flushed as it
    # died, which a catch-all handle_info would inspect into the log.
    drain_port_messages(port)
  end

  # `kill` is non-interactive and never hangs; -9 because a blocked `op`
  # is holding an auth prompt, not state worth a graceful stop. On a
  # platform without a `kill` binary (Windows) the child is left to die
  # with its closed stdio — better orphaned than raising :enoent on the
  # exact locked-vault path this runner exists to survive.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        System.cmd(kill, ["-9", to_string(os_pid)], stderr_to_stdout: true)
        :ok
    end
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
      {:EXIT, ^port, _reason} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  @doc """
  The 1Password CLI availability + auth state.

    * `:absent`         — the `op` binary is not on PATH.
    * `:not_signed_in`  — `op` is installed but no account session is active.
    * `:ok`             — `op` is installed and signed in.

  Used by the resolver's diagnostics so a stored `op://` reference that fails
  to resolve can say *why* (needs `op signin`) instead of silently falling
  through to env vars.
  """
  @spec op_status() :: :absent | :not_signed_in | :ok
  def op_status do
    cond do
      not op_available?() -> :absent
      match?({_out, 0}, run_op(["whoami"])) -> :ok
      # A timeout (locked vault) reads as not signed in: unusable either way.
      true -> :not_signed_in
    end
  end

  @doc """
  Create a 1Password item holding `key` and return its `op://...` reference.

  The secret is written to a `0600` temp template and passed to
  `op item create` via `--template` (never on argv, so it can't leak to the
  process list), then the temp file is removed. The vault defaults to
  `$RAXOL_OP_VAULT` or `Private`. Returns `{:ok, ref}` or `{:error, reason}`.
  """
  @spec create_item(atom() | String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_item(harness, key, opts \\ [])

  def create_item(harness, key, opts) when is_binary(key) and key != "" do
    if op_available?() do
      do_create_item(harness, key, opts)
    else
      {:error, :op_unavailable}
    end
  end

  def create_item(_harness, _key, _opts), do: {:error, :empty_key}

  defp do_create_item(harness, key, opts) do
    vault =
      Keyword.get(opts, :vault) || System.get_env("RAXOL_OP_VAULT") || "Private"

    template = op_template(harness, key)

    path =
      Path.join(
        System.tmp_dir!(),
        "raxol-op-#{System.unique_integer([:positive])}.json"
      )

    # Exclusive create, then tighten to 0600 while still EMPTY, then
    # write the secret — the default-permission window never contains
    # key material, and a pre-planted file/symlink at the (guessable)
    # name fails the exclusive open instead of receiving the key.
    with {:ok, io} <- File.open(path, [:write, :exclusive]),
         _ <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(io, template),
         :ok <- File.close(io) do
      try do
        run_op_create(path, vault)
      after
        File.rm(path)
      end
    end
  end

  defp run_op_create(template_path, vault) do
    args = [
      "item",
      "create",
      "--template",
      template_path,
      "--vault",
      vault,
      "--format",
      "json"
    ]

    case run_op(args) do
      {:error, reason} -> {:error, reason}
      {out, 0} -> created_ref(out, vault)
      {out, code} -> {:error, {:op_create_failed, code, String.trim(out)}}
    end
  end

  defp op_template(harness, key) do
    Jason.encode!(%{
      "title" => "Raxol #{harness} API key",
      "category" => "API_CREDENTIAL",
      "fields" => [
        %{
          "id" => "credential",
          "type" => "CONCEALED",
          "label" => "credential",
          "value" => key
        }
      ]
    })
  end

  defp created_ref(out, vault) do
    case Jason.decode(out) do
      {:ok, %{"id" => id, "vault" => %{"name" => vname}}} ->
        {:ok, "op://#{vname}/#{id}/credential"}

      {:ok, %{"id" => id}} ->
        {:ok, "op://#{vault}/#{id}/credential"}

      _ ->
        {:error, :op_create_unparsable}
    end
  end

  @doc """
  Resolve a `op://...` reference to its secret via the 1Password CLI.

  Returns `{:ok, secret}` (trimmed), or `{:error, reason}` when `op` is
  missing, not signed in, or the reference does not resolve. The secret is
  returned to the caller and never logged or persisted here.
  """
  @spec read_ref(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_ref("op://" <> _ = ref) do
    ["read", ref] |> run_op() |> interpret_op_output()
  end

  def read_ref(_other), do: {:error, :not_an_op_ref}

  defp interpret_op_output({out, 0}) do
    case String.trim(out) do
      "" -> {:error, :empty_secret}
      secret -> {:ok, secret}
    end
  end

  # The timeout/unavailable tuples carry no output: the secret (exit 0
  # output) must never ride along an error term that callers may log.
  defp interpret_op_output({:error, reason}), do: {:error, reason}

  defp interpret_op_output({out, code}),
    do: {:error, {:op_failed, code, String.trim(out)}}
end
