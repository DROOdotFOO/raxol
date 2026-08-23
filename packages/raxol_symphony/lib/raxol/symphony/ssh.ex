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

  The caller supplies the path the remote command should `cd` into.
  `Raxol.Symphony.Workspace` derives that path from the host spec's
  `workspace_root` and creates it on the host (issue #744).
  """

  alias Raxol.Symphony.Worker.HostSpec

  @allowed_binaries ~w(ssh)

  # Fail fast on an unreachable host instead of wedging a worker slot on a
  # stalled TCP connect.
  @connect_timeout_seconds 15

  # Detect a half-open connection (dropped network / dead remote) so a stuck
  # worker frees its host slot instead of hanging forever: probe every 30s,
  # give up after 3 unanswered probes (~90s), then the local `ssh` exits and
  # the Port closes.
  @server_alive_interval_seconds 30
  @server_alive_count_max 3

  # How often the disconnect watcher re-checks that its sshd session is still
  # alive. Only bounds how long an orphan survives after a disconnect; it costs
  # a live command nothing (see `reap_on_disconnect/2`).
  @reap_poll_seconds 5

  # A tilde prefix safe to leave unquoted: `~` alone, or `~user` where the
  # username starts with a letter or `_`. Anything outside this is quoted whole
  # rather than handed to the remote shell bare.
  #
  # The leading-character restriction is load-bearing, not tidiness. Bash gives
  # several tilde prefixes a meaning that has nothing to do with home
  # directories: `~-` expands to `$OLDPWD`, `~+` to `$PWD`, and `~N` / `~-N` to
  # directory-stack entries. `HostSpec`'s `@path_re` accepts `~-/ws` and `~0/ws`
  # as a `workspace_root`, so a pattern that allowed digits and `-` in the first
  # position left the workspace root resolving to wherever the login shell
  # happened to have been -- a different directory per connection, and outside
  # any root containment was measured against. Those now fall through to
  # `shell_quote/1` and stay inert, which is this function's stated contract for
  # a path it does not understand.
  @tilde_prefix ~r/\A~([A-Za-z_][A-Za-z0-9._-]*)?\z/

  @doc """
  How long `ssh` will spend trying to establish the connection, in milliseconds.

  Public because a caller that bounds its own wait on a remote command has to
  cover this FIRST: the remote deadline is a `sleep` that does not start until
  the connection is up and `bash` is running, so a local timer sized to the
  deadline alone can expire while `ssh` is still dialling.
  """
  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms, do: @connect_timeout_seconds * 1000

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

  @doc """
  The SSH option args for a spec: non-interactive base (BatchMode, connect
  timeout, server-alive keepalive), the spec's host-key policy
  (`StrictHostKeyChecking` + optional `UserKnownHostsFile`), then port and
  identity. Derived from the `HostSpec` so a deployment can force
  `StrictHostKeyChecking=yes` against a pre-seeded `known_hosts`.
  """
  @spec option_args(HostSpec.t()) :: [binary()]
  def option_args(%HostSpec{port: port, identity_file: identity} = spec) do
    base_options() ++ host_key_args(spec) ++ port_args(port) ++ identity_args(identity)
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

  `workspace` is a path on the HOST, derived by
  `Raxol.Symphony.Workspace` from the spec's `workspace_root`.

  The `&&` carries SPEC s9.5 Invariant 1 across the network: a `cd` that fails
  short-circuits, so a command whose workspace is missing does not run in the
  login shell's home directory instead. That is the remote counterpart of the
  local launch's `{:cd, workspace}`.

  `command` is wrapped in a `{ …; }` group, and the group is what makes that
  true. `&&` binds to the next COMMAND, not to the rest of the line, so
  `cd WS && A; B` runs `B` whatever `cd` did. Every real caller here passes
  `reap_on_disconnect/2` output, which begins `set -m;` -- so ungrouped, a failed
  `cd` skipped only the `set -m` and ran the workload in the login shell's home,
  then reported exit 0 because `wait` returned the backgrounded group's status.
  Grouped, a failed `cd` runs nothing and the command exits with `cd`'s status.
  """
  @spec remote_bash(binary(), binary()) :: binary()
  def remote_bash(workspace, command) when is_binary(workspace) and is_binary(command) do
    # The newline before `}` terminates the last command in the group, which a
    # trailing `;` could not do for a multi-line script ending in a comment.
    remote_bash("cd #{quote_path(workspace)} && { #{command}\n}")
  end

  @doc """
  A remote `bash -lc` login-shell command with no `cd`, for the commands that
  run BEFORE the workspace exists (creating it) or AFTER it is gone (removing
  it). Prefer `remote_bash/2` for anything that runs inside a workspace.
  """
  @spec remote_bash(binary()) :: binary()
  def remote_bash(command) when is_binary(command) do
    "bash -lc #{shell_quote(command)}"
  end

  @doc """
  POSIX single-quote a value for interpolation into a remote command.

  Public because the workspace layer builds its own `mkdir -p` / `rm -rf`
  scripts and must quote host paths the same way this module does.
  """
  @spec shell_quote(binary()) :: binary()
  def shell_quote(str) when is_binary(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  @doc """
  Quote a remote PATH, leaving a leading `~` or `~user` unquoted so the remote
  shell still expands it.

  `shell_quote/1` alone is wrong for a home-relative path: single quotes are
  exactly what suppresses tilde expansion, so `mkdir -p '~/ws'` creates a
  directory literally NAMED `~` in whatever directory the login shell started
  in, rather than one under `$HOME`. `HostSpec` accepts `~` roots, so this is
  reachable from ordinary config.

  Only a tilde prefix drawn from `[A-Za-z0-9._-]` is left bare, which is what
  `HostSpec`'s path pattern already permits. Anything else falls back to
  quoting the whole path, so a path this function does not understand is
  inert rather than expanded.
  """
  @spec quote_path(binary()) :: binary()
  def quote_path("~" <> _ = path) when is_binary(path) do
    {prefix, rest} =
      case String.split(path, "/", parts: 2) do
        [only] -> {only, nil}
        [head, tail] -> {head, tail}
      end

    cond do
      not Regex.match?(@tilde_prefix, prefix) -> shell_quote(path)
      rest in [nil, ""] -> prefix
      true -> prefix <> "/" <> shell_quote(rest)
    end
  end

  def quote_path(path) when is_binary(path), do: shell_quote(path)

  @doc """
  Wrap `command` so a dropped SSH connection can never orphan it.

  Closing the local `ssh` Port (`Port.close`) tears down the ssh client but,
  for a non-pty exec channel, sshd does NOT signal the remote command — it
  reparents and lingers (the classic orphan). We can't force a pty here: the
  remote `codex app-server` speaks newline-delimited JSON-RPC over stdio and a
  pty's echo + CR/LF translation would corrupt that framing.

  So the command runs with its stdio untouched (`<&0` keeps stdin wired to the
  ssh channel, stdout/stderr inherited) and a co-resident watcher polls the
  shell's parent (the sshd session process): when it dies, the watcher signals
  the command. A normal exit falls straight through with the command's real
  status (`wait`). Framing-safe: the watcher never reads the data channel.

  The watcher polls in its OWN background subshell rather than inline, so the
  poll interval is never added to the command's own runtime. Inline, `wait`
  could not be reached until the current `sleep` elapsed, which charged every
  invocation up to a full interval. That is invisible for a long-lived
  `codex app-server` and ruinous for a workspace hook that finishes in
  milliseconds (issue #744).

  The watcher's own stdio goes to `/dev/null`, which is load-bearing rather
  than tidiness. Inheriting the command's stdout would leave the watcher (and
  the `sleep` it spawns) holding the write end of that pipe: a reader waits for
  EOF, not for the command to exit, so a caller like `System.cmd/3` would block
  for a further poll interval after the command had already finished.

  `command` is wrapped in a `{ …; }` group before the redirect and `&` are
  applied. Without the group those bind only to the command's LAST LINE, so a
  multi-line script (which is what a workspace hook normally is) backgrounds an
  empty trailing command and `wait` reports ITS status: a hook failing on its
  final line was reported as success.

  ## Options

    * `:deadline_seconds` -- kill the command after this many seconds. This is
      the only thing that actually bounds the remote side. A caller that gives
      up locally does NOT take the remote command down with it: killing the BEAM
      process closes the port, and closing a port does not signal the OS process
      it spawned.
  """
  @spec reap_on_disconnect(binary(), keyword()) :: binary()
  def reap_on_disconnect(command, opts \\ []) when is_binary(command) do
    deadline = Keyword.get(opts, :deadline_seconds)

    # Single-quote-free so it survives `remote_bash/2`'s single-quoting intact.
    "set -m; { " <>
      command <>
      "\n} <&0 & __rx_pid=$!; set +m; __rx_ppid=$PPID; " <>
      "{ #{reap_own_sleep("__rx_ws")}" <>
      "while kill -0 $__rx_pid 2>/dev/null; do " <>
      "ps -p $__rx_ppid >/dev/null 2>&1 || { #{kill_tree()} break; }; " <>
      "#{interruptible_sleep(@reap_poll_seconds, "__rx_ws")}" <>
      "done; } >/dev/null 2>&1 & __rx_watch=$!; " <>
      deadline_clause(deadline) <>
      "wait $__rx_pid; __rx_status=$?; " <>
      "kill $__rx_watch #{deadline_pid_ref(deadline)}2>/dev/null; " <>
      "exit $__rx_status"
  end

  # `kill $__rx_watch` reaches the watcher SUBSHELL, and a subshell blocked in
  # `sleep` has that `sleep` as a child in the shell's own process group -- so
  # killing the subshell orphaned the `sleep`, which then ran out its full
  # interval reparented to init. Both helpers did it, on every invocation: after
  # a one-second hook with a sixty-second deadline, two `sleep` processes
  # survived on the host with ppid 1. Reproduced on bash 3.2 and 5.3.
  #
  # A group kill is not available here the way it is for the workload: `set +m`
  # has already run by this point, so the helpers share the shell's process
  # group and `kill -- -$__rx_watch` would signal the shell itself.
  #
  # So each helper reaps its own. `sleep` runs in the background and the helper
  # `wait`s on it, which is what makes the TERM arrive as an interrupt rather
  # than being deferred until the sleep finishes.
  #
  # The trap body is double-quoted with an escaped `$` so it expands when the
  # trap FIRES, not when it is defined -- at definition time the pid variable is
  # still unset, and the trap would then kill nothing. Still single-quote-free,
  # so it survives `remote_bash/1`'s quoting unchanged.
  defp reap_own_sleep(var),
    do: ~s|trap "kill \\$#{var} 2>/dev/null; exit" TERM; |

  defp interruptible_sleep(seconds, var),
    do: "sleep #{seconds} & #{var}=$!; wait $#{var}; "

  # Signal the command's whole process GROUP, not just the subshell.
  #
  # `set -m` above turns on job control, which puts the backgrounded group in
  # its own process group with pgid == its pid, so `kill -- -PID` reaches the
  # children too. Killing only the subshell leaves its children running: they
  # keep doing work past the deadline AND keep the inherited stdout pipe open,
  # so a reader waiting on EOF blocks for the command's full natural runtime
  # even though it was supposedly killed.
  #
  # Job control is switched back off (`set +m`) the moment the fork is done.
  # The process group is fixed at fork time so the group kill still lands, but
  # the shell stops announcing job transitions -- with `-m` left on, bash writes
  # `[1]  Done …` into the hook's own captured output.
  #
  # That covers the normal path, not every path. On bash 3.2 (still the system
  # shell on macOS hosts) a job KILLED by the deadline is reported anyway, as
  # `Terminated: 15`, regardless of `-m`. Harmless here because the only reader
  # of that output is the `hook_timed_out` log line, which is reporting a
  # timeout in any case -- but it is one line of shell chatter, not a guarantee
  # of a clean channel.
  #
  # The plain `kill` is the fallback for a shell where the group kill did not
  # apply, so the subshell still dies rather than nothing happening.
  defp kill_tree, do: "kill -- -$__rx_pid 2>/dev/null; kill $__rx_pid 2>/dev/null;"

  defp deadline_clause(nil), do: ""

  defp deadline_clause(seconds) when is_integer(seconds) and seconds > 0 do
    "{ #{reap_own_sleep("__rx_ds")}#{interruptible_sleep(seconds, "__rx_ds")}" <>
      "#{kill_tree()} } >/dev/null 2>&1 & __rx_dead=$!; "
  end

  defp deadline_pid_ref(nil), do: ""
  defp deadline_pid_ref(seconds) when is_integer(seconds) and seconds > 0, do: "$__rx_dead "

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

  # Never prompt (BatchMode); bound the TCP connect; keep the connection
  # probed so a dead remote is noticed and the local `ssh` exits.
  defp base_options do
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=#{@connect_timeout_seconds}",
      "-o",
      "ServerAliveInterval=#{@server_alive_interval_seconds}",
      "-o",
      "ServerAliveCountMax=#{@server_alive_count_max}"
    ]
  end

  defp host_key_args(%HostSpec{strict_host_key_checking: mode, known_hosts: known_hosts}) do
    ["-o", "StrictHostKeyChecking=#{ssh_host_key_mode(mode)}"] ++ known_hosts_args(known_hosts)
  end

  # HostSpec validated the mode; map to ssh's spelling (hyphenated accept-new).
  defp ssh_host_key_mode(:yes), do: "yes"
  defp ssh_host_key_mode(:no), do: "no"
  defp ssh_host_key_mode(_accept_new), do: "accept-new"

  defp known_hosts_args(nil), do: []
  defp known_hosts_args(path) when is_binary(path), do: ["-o", "UserKnownHostsFile=#{path}"]

  defp port_args(nil), do: []
  defp port_args(port) when is_integer(port), do: ["-p", Integer.to_string(port)]

  defp identity_args(nil), do: []
  defp identity_args(path) when is_binary(path), do: ["-i", path]
end
