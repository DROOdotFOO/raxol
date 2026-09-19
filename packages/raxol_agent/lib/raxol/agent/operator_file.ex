defmodule Raxol.Agent.OperatorFile do
  @moduledoc """
  Locate and read an OPERATOR-owned control file: `$OVERRIDE` when set, else
  `~/.raxol/<name>`, and only when the file on disk demonstrably belongs to
  the account this VM runs as.

  ## What is a control file here

  Four files in this package answer "may the agent do this":

    * `providers.json` -- which 1Password item holds a provider key;
    * `mcp.json` -- which MCP servers load with `:user` provenance, the
      provenance that is exempt from the workspace header gate;
    * `mcp_headers.json` -- which `${env:}` / `op://` references a
      workspace-declared server may resolve;
    * `mcp_hosts.json` -- which hosts a workspace-declared server may be
      connected to at all.

  A file that grants permission has to be a file the operator actually wrote.

  ## No home directory means no control file

  These paths used to fall back to `System.tmp_dir!/0` when there was no home
  directory -- a container running a bare UID, a systemd unit without
  `User=`, a daemon that dropped HOME. That put the control at
  `/tmp/.raxol/<name>`: a path any local user can create FIRST, and whose
  contents then belong to whoever won the race. A grant sourced from an
  attacker is worse than no grant, so a homeless process has no default path
  at all -- `path/2` returns nil and every reader treats that as a refusal.
  An operator who really runs without a home sets the explicit override,
  which is a deliberate act naming a directory they chose.

  ## Ownership is checked, not assumed

  A real home is not proof either; `$HOME` can name a shared or inherited
  directory. So the file is read only when `File.stat/1` says it is a regular
  file owned by our uid with no group- or other-write bit. The refusal is
  logged with the path and the reason, because an operator whose file is mode
  0664 did nothing wrong and needs to be told which file to chmod rather than
  left wondering why their allowlist stopped applying.

  On Windows neither test carries meaning (no useful uid, no POSIX mode
  bits), so only the path rule applies there.
  """

  require Logger

  import Bitwise, only: [band: 2]

  @base ".raxol"
  @group_other_write 0o022

  @type refusal ::
          :no_home
          | {:not_owned, non_neg_integer()}
          | {:group_or_other_writable, non_neg_integer()}
          | {:not_a_regular_file, atom()}
          | {:stat_failed, File.posix()}
          | {:read_failed, File.posix()}

  @doc """
  The home directory, or nil when the process has none.

  HOME is the POSIX definition and is read LIVE, so a process that drops it
  is honoured. `System.user_home/0` caches the VM's boot-time answer, which
  would keep handing out a home the current environment no longer has; it is
  still the right call on Windows, where home is not HOME.
  """
  @spec home() :: String.t() | nil
  def home do
    case :os.type() do
      {:win32, _} ->
        System.user_home()

      _ ->
        case System.get_env("HOME") do
          dir when is_binary(dir) and dir != "" -> dir
          _ -> nil
        end
    end
  end

  @doc """
  The path of a control file: `$env_var`, else `~/.raxol/<filename>`.

  nil means there is no path to read: no override and no home directory. That
  is a refusal, never a fallback.
  """
  @spec path(String.t(), String.t()) :: String.t() | nil
  def path(env_var, filename) do
    case System.get_env(env_var) do
      p when is_binary(p) and p != "" ->
        p

      _ ->
        case home() do
          nil -> nil
          dir -> Path.join([dir, @base, filename])
        end
    end
  end

  @doc """
  Read a control file.

  `{:ok, binary}` when it exists and is trustworthy, `:none` when there is no
  such file (an absent control is a normal state: it grants nothing), and
  `{:error, reason}` when the path could not be resolved or the file cannot
  be trusted. `label` names the control in the refusal log; `env_var` is
  named there too, so the operator is told the way out.
  """
  @spec read(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | :none | {:error, refusal()}
  def read(env_var, filename, label) do
    case path(env_var, filename) do
      nil ->
        Logger.warning(fn ->
          "#{label}: refused — no home directory (HOME is unset) and $#{env_var} is not set. " <>
            "Falling back to a temp path would let any local user supply this control; " <>
            "set $#{env_var} to a path you own to use one."
        end)

        {:error, :no_home}

      path ->
        read_path(path, label)
    end
  end

  @doc """
  Read an already-resolved control path under the same ownership rules.

  Same returns as `read/3`.
  """
  @spec read_path(String.t(), String.t()) :: {:ok, binary()} | :none | {:error, refusal()}
  def read_path(path, label) do
    case trusted?(path) do
      :ok ->
        read_file(path, label)

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        Logger.warning(fn -> "#{label}: refusing #{path}: #{explain(reason)}" end)
        {:error, reason}
    end
  end

  @doc """
  Whether a control file may be trusted: a regular file, owned by us, with no
  group- or other-write bit. `{:error, :enoent}` distinguishes "no such file"
  from a refusal.
  """
  @spec trusted?(String.t()) :: :ok | {:error, refusal() | :enoent}
  def trusted?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> vet(stat)
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  # Windows reports neither a meaningful uid nor POSIX mode bits through
  # File.Stat, so both tests would be theatre there; the path rule still holds.
  defp vet(%File.Stat{uid: file_uid, mode: mode}) do
    permissions = band(mode, 0o777)
    owner = uid()

    cond do
      match?({:win32, _}, :os.type()) ->
        :ok

      owner != :unknown and file_uid != owner ->
        {:error, {:not_owned, file_uid}}

      band(permissions, @group_other_write) != 0 ->
        {:error, {:group_or_other_writable, permissions}}

      true ->
        :ok
    end
  end

  @doc """
  The uid a control file must belong to: the uid this VM runs as, discovered
  once and remembered.

  The BEAM exposes no `getuid`, so ask the system. `:unknown` (Windows, or an
  image with no `id`) drops the ownership half of the check; the mode half
  still applies, so the refusal does not become a hard dependency on a
  particular userland.
  """
  @spec uid() :: non_neg_integer() | :unknown
  def uid do
    case :persistent_term.get({__MODULE__, :uid}, :unset) do
      :unset ->
        discovered = discover_uid()
        :persistent_term.put({__MODULE__, :uid}, discovered)
        discovered

      discovered ->
        discovered
    end
  end

  defp discover_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {uid, ""} -> uid
          _ -> :unknown
        end

      _nonzero ->
        :unknown
    end
  rescue
    # No `id` on PATH at all: System.cmd/3 raises rather than returning.
    _ -> :unknown
  end

  defp read_file(path, label) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok, binary}

      # Lost between the stat and the read; treat as absent rather than as a
      # grant.
      {:error, :enoent} ->
        :none

      {:error, reason} ->
        Logger.warning(fn -> "#{label}: cannot read #{path}: #{:file.format_error(reason)}" end)
        {:error, {:read_failed, reason}}
    end
  end

  defp explain({:not_owned, file_uid}),
    do:
      "owned by uid #{file_uid}, not #{uid()}. A file this account does not own is not this " <>
        "account's control; chown it or point the override elsewhere."

  defp explain({:group_or_other_writable, permissions}),
    do:
      "mode #{octal(permissions)} — another account may rewrite it, so it grants whatever they " <>
        "write. chmod 600 it."

  defp explain({:not_a_regular_file, type}),
    do: "is a #{type}, not a regular file."

  defp explain({:stat_failed, reason}),
    do: "cannot be inspected: #{:file.format_error(reason)}."

  defp octal(permissions),
    do: "0" <> String.pad_leading(Integer.to_string(permissions, 8), 3, "0")
end
