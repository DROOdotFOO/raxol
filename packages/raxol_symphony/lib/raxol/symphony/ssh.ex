defmodule Raxol.Symphony.Ssh do
  @moduledoc """
  The single seam that runs a command on a remote worker host over SSH
  (issue #743). Pure argv construction plus an allowlisted, injectable
  executor — nothing here spawns a process except `exec/3`, and that is
  injectable for tests.

  A remote worker command is `ssh <opts> <user@host> "bash -lc 'cd WS && …'"`.
  Two deliberate decisions:

    * **The remote LOGIN shell provides credentials.** The orchestrator
      forwards **no** environment over SSH — the remote `bash -lc` sources
      the host's login profile, so worker credentials (API keys, etc.) are
      provisioned host-side and never travel on a command line. Env
      injection stays a local-worker concern (`Runners.Codex.Session`).
    * **`ssh` is allowlisted.** `executable/0` refuses anything whose
      basename is not `ssh` (mirrors the gateway transcribe allowlist).

  The remote workspace path handling (creating `WS` on the host) is issue
  #744; here the caller supplies whatever path the remote command should
  `cd` into.
  """

  alias Raxol.Symphony.Worker.HostSpec

  @allowed_binaries ~w(ssh)

  # Non-interactive defaults: never prompt (BatchMode), and trust a new host
  # key on first contact rather than hanging on the yes/no prompt.
  @base_options ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]

  @doc """
  Resolve the `ssh` executable, refusing anything not named `ssh`.
  """
  @spec executable() :: {:ok, binary()} | {:error, :ssh_not_allowed}
  def executable do
    with path when is_binary(path) <- System.find_executable("ssh"),
         true <- Path.basename(path) in @allowed_binaries do
      {:ok, path}
    else
      _ -> {:error, :ssh_not_allowed}
    end
  end

  @doc "The `user@host` (or bare `host`) SSH destination for a spec."
  @spec target(HostSpec.t()) :: binary()
  def target(%HostSpec{host: host, user: nil}), do: host
  def target(%HostSpec{host: host, user: user}), do: "#{user}@#{host}"

  @doc "The SSH option args for a spec (non-interactive base + port + identity)."
  @spec option_args(HostSpec.t()) :: [binary()]
  def option_args(%HostSpec{port: port, identity_file: identity}) do
    @base_options ++ port_args(port) ++ identity_args(identity)
  end

  @doc """
  The full `ssh` argv to run `remote_command` on the host:
  `[options…, target, remote_command]`. `remote_command` is a single element
  so SSH forwards it verbatim to the remote shell (no re-tokenization).
  """
  @spec command_args(HostSpec.t(), binary()) :: [binary()]
  def command_args(%HostSpec{} = spec, remote_command) when is_binary(remote_command) do
    option_args(spec) ++ [target(spec), remote_command]
  end

  @doc """
  A remote `bash -lc` login-shell command that cds into `workspace` then runs
  `command`. Quoted so it survives SSH's transport and the remote shell's
  re-parse. The remote login shell sources host-provisioned credentials; no
  env is forwarded from the orchestrator.
  """
  @spec remote_bash(binary(), binary()) :: binary()
  def remote_bash(workspace, command) when is_binary(workspace) and is_binary(command) do
    inner = "cd #{shell_quote(workspace)} && #{command}"
    "bash -lc #{shell_quote(inner)}"
  end

  @doc """
  Run `remote_command` on the host once and return `{output, exit_status}`.

  The executor is injectable (`:exec_fn`, default `System.cmd/3` with
  `stderr_to_stdout: true`) and the executable is resolvable (`:executable`,
  default `executable/0`) so tests need no real `ssh`. Returns
  `{:error, :ssh_not_allowed}` when the `ssh` binary can't be resolved.
  """
  @spec exec(HostSpec.t(), binary(), keyword()) ::
          {binary(), non_neg_integer()} | {:error, :ssh_not_allowed}
  def exec(%HostSpec{} = spec, remote_command, opts \\ []) do
    exec_fn = Keyword.get(opts, :exec_fn, &System.cmd/3)

    case resolve_executable(opts) do
      {:ok, ssh} ->
        exec_fn.(ssh, command_args(spec, remote_command), stderr_to_stdout: true)

      {:error, _} = err ->
        err
    end
  end

  # -- Internals --------------------------------------------------------------

  defp resolve_executable(opts) do
    case Keyword.get(opts, :executable) do
      nil -> executable()
      path when is_binary(path) -> {:ok, path}
    end
  end

  defp port_args(nil), do: []
  defp port_args(port) when is_integer(port), do: ["-p", Integer.to_string(port)]

  defp identity_args(nil), do: []
  defp identity_args(path) when is_binary(path), do: ["-i", path]

  # POSIX single-quote escaping: wrap in single quotes, and end/re-open the
  # quote around any embedded single quote (`'` -> `'\''`).
  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
