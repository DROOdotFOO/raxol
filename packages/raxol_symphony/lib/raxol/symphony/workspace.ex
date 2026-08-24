defmodule Raxol.Symphony.Workspace do
  @moduledoc """
  Per-issue workspace lifecycle.

  Implements SPEC s9 (Workspace Management and Safety):

  - `ensure/2` returns `{:ok, %{path, key, created_now}}`. The `created_now`
    flag gates the `after_create` hook.
  - `run_hook/4` executes a workflow hook in the workspace directory via
    `bash -lc`, with `hooks.timeout_ms` enforcement.
  - `remove/2` runs `before_remove` (best-effort) and deletes the workspace.

  Workspaces are reused across runs (s9.1) -- we do not auto-delete on
  successful runs.

  Hook failure semantics (s9.4):
  - `after_create` failure or timeout -> fatal to workspace creation
  - `before_run` failure or timeout -> fatal to current run attempt
  - `after_run` failure or timeout -> logged, ignored
  - `before_remove` failure or timeout -> logged, ignored

  ## Local and remote workspaces (issue #744)

  Every entry point takes an optional `:host`. With `host: nil` (the default,
  and every local dispatch) the local filesystem path below runs unchanged.

  With a `%HostSpec{}` the whole lifecycle moves to that host: the directory is
  created and removed there over `Raxol.Symphony.Ssh`, hooks run there, and the
  path is rooted at the spec's `workspace_root`. A remote worker must not be
  handed the orchestrator's own path, because nothing guarantees that path
  exists on the host, and if it happens to exist it is a different directory
  belonging to something else.

  When a spec declares no `workspace_root` the configured `workspace.root` is
  used as-is, which assumes the host mirrors the orchestrator's layout, and says
  so in a warning rather than defaulting silently. Declare `workspace_root` per
  host when it does not.

  `:ssh` forwards options to `Raxol.Symphony.Ssh.exec/3` (`:exec_fn`,
  `:executable`), so the remote lifecycle is testable without a real SSH server.
  """

  require Logger

  alias Raxol.Symphony.{Config, PathSafety, PortReaper, Ssh}
  alias Raxol.Symphony.Worker.HostSpec

  # Distinctive enough that a login banner or profile chatter on the remote
  # shell cannot be mistaken for the probe's own answer.
  @created_marker "__rx_ws_created__"
  @exists_marker "__rx_ws_exists__"

  @type ensure_result :: %{
          path: Path.t(),
          key: binary(),
          created_now: boolean()
        }

  @type ensure_error ::
          :workspace_outside_root
          | :invalid_workspace_root
          | :invalid_workspace_key
          | {:mkdir_failed, term()}
          | {:after_create_hook_failed, term()}

  @hook_log_truncate_bytes 4096

  @doc """
  Ensures the per-issue workspace directory exists.

  Returns `{:ok, %{path, key, created_now}}` or `{:error, reason}`. With a
  `:host` the directory is created on that host and `path` names a directory
  there, not on the orchestrator.
  """
  @spec ensure(Config.t(), binary(), keyword()) ::
          {:ok, ensure_result()} | {:error, ensure_error()}
  def ensure(%Config{} = config, identifier, opts \\ []) when is_binary(identifier) do
    case host_opt(opts) do
      nil -> ensure_local(config, identifier)
      %HostSpec{} = host -> ensure_remote(config, identifier, host, ssh_opts(opts))
    end
  end

  defp ensure_local(%Config{} = config, identifier) do
    with {:ok, path} <- PathSafety.workspace_path(config.workspace.root, identifier),
         {:ok, created_now} <- mkdir_p(path),
         :ok <- maybe_run_after_create(config, path, created_now, []) do
      {:ok, %{path: path, key: PathSafety.sanitize_key(identifier), created_now: created_now}}
    end
  end

  defp ensure_remote(%Config{} = config, identifier, %HostSpec{} = host, ssh_opts) do
    hook_opts = [host: host, ssh: ssh_opts]

    with {:ok, path} <-
           PathSafety.remote_workspace_path(remote_root(config, host), identifier),
         {:ok, created_now} <- remote_mkdir_p(host, path, ssh_opts),
         :ok <- maybe_run_after_create(config, path, created_now, hook_opts) do
      {:ok, %{path: path, key: PathSafety.sanitize_key(identifier), created_now: created_now}}
    end
  end

  @doc """
  Runs `hooks.before_run` for the workspace. Returns `:ok` or `{:error, reason}`.
  """
  @spec run_before_run_hook(Config.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def run_before_run_hook(%Config{} = config, path, opts \\ []) do
    case run_hook(config, :before_run, path, opts) do
      :ok -> :ok
      :no_hook -> :ok
      {:error, reason} -> {:error, {:before_run_hook_failed, reason}}
    end
  end

  @doc """
  Runs `hooks.after_run` for the workspace. Failures are logged but ignored.
  """
  @spec run_after_run_hook(Config.t(), Path.t(), keyword()) :: :ok
  def run_after_run_hook(%Config{} = config, path, opts \\ []) do
    case run_hook(config, :after_run, path, opts) do
      :ok ->
        :ok

      :no_hook ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.workspace.after_run_failed path=#{path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Runs `fun` bracketed by the `before_run` and `after_run` hooks.

  Returns `{:ok, result}` with whatever `fun` returned, or `{:error, reason}`
  when `before_run` failed -- in which case `fun` never ran. The caller decides
  what a `before_run` failure means in its own terms (SPEC s9.4 makes it fatal
  to the run ATTEMPT, not to the workspace), which is why this reports rather
  than exits.

  The three seams that invoke a runner share this so the bracket cannot drift
  between workflow modes: a hook that fires under `:default` and not under
  `:graph_parallel` is worse than one that never fires, because only one of
  those is visible.

  ## When `after_run` fires

  On any outcome the worker task RETURNS FROM, including a runner that returned
  an error or raised. `after_run` is the counterpart to `before_run`, so a run
  that started a dev server or a container in `before_run` must get its teardown
  even when -- especially when -- the run went badly. Skipping it on failure
  leaks exactly the resources it exists to reclaim.

  It does NOT fire on `{:pause, _, _}`. A paused run is not over: the
  orchestrator parks the token, holds the workspace and the host slot, and
  re-dispatches later. Tearing down there would run the teardown mid-run and
  then run `before_run` a second time on resume.

  It also cannot fire when the worker task is KILLED rather than returning --
  `terminate_running/4` and the stall reconcile both `Process.exit(pid, :kill)`,
  which no `after` or `catch` can intercept. So a run torn down by the
  orchestrator leaves whatever `before_run` started, and the thing that reclaims
  it is `before_remove` on the eventual `remove/3`. Worth knowing when writing
  the pair: `after_run` is the normal teardown, not a guaranteed one.

  Its own failure is logged and ignored, per s9.4, so it cannot turn a
  successful run into a failed one.

  A blank `path` is refused before `before_run` runs AND before `fun` does, so
  neither a hook nor the runner it brackets can land in whatever directory the
  shell happened to start in. It reports as a `before_run` failure would, which
  s9.4 already makes fatal to the attempt and retryable.
  """
  # `opts` carries no default on purpose. A default before a required argument
  # is legal but reads as optional, and `around_run(config, path, opts)` would
  # then silently bind `opts` to `fun` and die on the guard instead of saying
  # what was left out. All four seams pass both.
  @spec around_run(Config.t(), Path.t(), keyword(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def around_run(%Config{} = config, path, opts, fun)
      when is_list(opts) and is_function(fun, 0) do
    with :ok <- runnable_workspace(path),
         :ok <- run_before_run_hook(config, path, opts) do
      bracket(config, path, opts, fun)
    end
  end

  # The RUNNER needs a real directory as much as the hooks do, so the refusal
  # belongs here rather than only in `execute_hook_script/4`.
  #
  # Guarding the hook alone left the fail-open default in place for the thing
  # the hook brackets: `GraphAdapter` defaults a missing workspace to `""` in
  # two places (`slot_workspace/2`, `runner_dispatch_node/1`), and with no hooks
  # configured `:no_hook` short-circuits before any check, so the runner was
  # dispatched into an empty path anyway. `bash`'s `cd ''` succeeds and changes
  # nothing, so SPEC s9.5 Invariant 1's `cd WS && { … }` guard passes and the
  # work lands in whatever directory the shell started in.
  #
  # Costs a run ATTEMPT, not a workspace: it lands where a `before_run` failure
  # lands, which s9.4 already makes fatal to the attempt and retryable.
  defp runnable_workspace(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, {:invalid_workspace, path}}, else: :ok
  end

  defp runnable_workspace(path), do: {:error, {:invalid_workspace, path}}

  defp bracket(config, path, opts, fun) do
    try do
      fun.()
    catch
      # An exit is how a runner reports failure to its task, so this is a
      # terminal outcome like any other. Re-raised verbatim afterwards: the
      # teardown is not license to swallow the reason the run died.
      kind, reason ->
        run_after_run_hook(config, path, opts)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        unless paused?(result), do: run_after_run_hook(config, path, opts)
        {:ok, result}
    end
  end

  # `is_atom(reason)` matches every other reader of this shape, and the match
  # has to be exact for the same reason the bracket is shared: a run the
  # orchestrator treats as OVER must get its teardown.
  #
  # `Runner.result/0` is `{:pause, atom(), term()}`, and each consumer guards on
  # it -- `Orchestrator.interpret_runner_result/3` (`exit({:runner_bad_return,
  # _})`), `apply_batch_issue_result/3` (continuation retry) and
  # `GraphAdapter.store_runner_result/2`. Unguarded here, a `{:pause, "string",
  # token}` was the one shape read as paused by this and as terminated by all
  # three: the run was retried and `after_run` never fired, so whatever
  # `before_run` started was never reclaimed.
  defp paused?({:pause, reason, _token}) when is_atom(reason), do: true
  defp paused?(_result), do: false

  @doc """
  Removes a workspace, running `before_remove` first (best-effort).

  With a `:host` the containment check is measured against that host's remote
  root and the deletion happens there.
  """
  @spec remove(Config.t(), Path.t(), keyword()) :: :ok
  def remove(%Config{} = config, path, opts \\ []) when is_binary(path) do
    case host_opt(opts) do
      nil -> remove_local(config, path)
      %HostSpec{} = host -> remove_remote(config, path, host, ssh_opts(opts))
    end
  end

  defp remove_local(%Config{} = config, path) do
    case PathSafety.validate_inside_root(path, config.workspace.root) do
      {:ok, abs_path} ->
        run_before_remove(config, abs_path, [])
        File.rm_rf(abs_path)
        :ok

      {:error, reason} ->
        Logger.warning("symphony.workspace.remove_skipped path=#{path} reason=#{inspect(reason)}")

        :ok
    end
  end

  defp remove_remote(%Config{} = config, path, %HostSpec{} = host, ssh_opts) do
    case PathSafety.validate_inside_remote_root(path, remote_root(config, host)) do
      {:ok, abs_path} ->
        run_before_remove(config, abs_path, host: host, ssh: ssh_opts)
        remote_rm_rf(host, abs_path, ssh_opts)
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.workspace.remove_skipped host=#{HostSpec.id(host)} path=#{path} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Executes a hook script via `bash -lc <script>` with the workspace as cwd.

  Returns `:ok`, `:no_hook` (when the script is nil/empty), or
  `{:error, reason}`.

  `reason` is one of:
  - `{:exit, status}` -- non-zero exit
  - `:timeout` -- exceeded `hooks.timeout_ms`
  - `:bash_not_found` -- no bash on PATH
  """
  @spec run_hook(
          Config.t(),
          :after_create | :before_run | :after_run | :before_remove,
          Path.t(),
          keyword()
        ) :: :ok | :no_hook | {:error, term()}
  def run_hook(%Config{hooks: hooks}, hook_name, path, opts \\ [])
      when hook_name in [:after_create, :before_run, :after_run, :before_remove] do
    case Map.get(hooks, hook_name) do
      script when is_nil(script) or script == "" ->
        :no_hook

      script ->
        execute_named_hook(hook_name, script, path, hooks.timeout_ms, opts)
    end
  end

  defp execute_named_hook(hook_name, script, path, timeout_ms, opts) do
    Logger.info("symphony.workspace.hook_started hook=#{hook_name} path=#{path}#{host_log(opts)}")

    case execute_hook_script(script, path, timeout_ms, opts) do
      {:ok, output} ->
        Logger.debug(
          "symphony.workspace.hook_completed hook=#{hook_name} path=#{path} " <>
            "output=#{truncate_for_log(output)}"
        )

        :ok

      {:error, {:exit, status, output}} ->
        Logger.warning(
          "symphony.workspace.hook_failed hook=#{hook_name} path=#{path} " <>
            "exit=#{status} output=#{truncate_for_log(output)}"
        )

        {:error, {:exit, status}}

      {:error, :timeout} ->
        Logger.warning(
          "symphony.workspace.hook_timeout hook=#{hook_name} path=#{path} timeout_ms=#{timeout_ms}"
        )

        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Internals --------------------------------------------------------------

  defp mkdir_p(path) do
    case File.dir?(path) do
      true ->
        {:ok, false}

      false ->
        case File.mkdir_p(path) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end

  defp maybe_run_after_create(_config, _path, false, _opts), do: :ok

  defp maybe_run_after_create(config, path, true, opts) do
    case run_hook(config, :after_create, path, opts) do
      :ok ->
        :ok

      :no_hook ->
        :ok

      {:error, reason} ->
        # Best-effort: remove the partially-prepared directory so the next run
        # can retry from scratch (per SPEC s9.3 implementation guidance). This
        # has to unwind on whichever machine just created it.
        discard_partial(path, opts)
        {:error, {:after_create_hook_failed, reason}}
    end
  end

  defp discard_partial(path, opts) do
    case host_opt(opts) do
      nil -> File.rm_rf(path)
      %HostSpec{} = host -> remote_rm_rf(host, path, ssh_opts(opts))
    end
  end

  defp run_before_remove(config, path, opts) do
    case run_hook(config, :before_remove, path, opts) do
      :ok ->
        :ok

      :no_hook ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.workspace.before_remove_failed path=#{path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # -- Remote lifecycle (issue #744) ------------------------------------------

  defp host_opt(opts), do: Keyword.get(opts, :host)

  defp ssh_opts(opts), do: Keyword.get(opts, :ssh, [])

  defp host_log(opts) do
    case host_opt(opts) do
      nil -> ""
      %HostSpec{} = host -> " host=#{HostSpec.id(host)}"
    end
  end

  # A spec that declares no root falls back to the configured local root, which
  # assumes the host mirrors the orchestrator's layout. That assumption is the
  # failure this whole slice exists to remove, so taking it says so out loud
  # rather than defaulting in silence.
  defp remote_root(%Config{}, %HostSpec{workspace_root: root})
       when is_binary(root) and root != "",
       do: root

  defp remote_root(%Config{} = config, %HostSpec{} = host) do
    warn_defaulted_root_once(config, host)
    config.workspace.root
  end

  # Once per host, not once per call. `ensure/3` and `remove/3` each resolve the
  # root, so at poll cadence with N issues this warned N times a tick, forever,
  # for a configuration the fallback deliberately supports. The one log line that
  # has to be READ on this path is `remote_remove_failed`, and a warning
  # repeating every tick is what buries it.
  defp warn_defaulted_root_once(%Config{} = config, %HostSpec{} = host) do
    key = {__MODULE__, :remote_root_defaulted, HostSpec.id(host)}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "symphony.workspace.remote_root_defaulted host=#{HostSpec.id(host)} " <>
          "root=#{config.workspace.root} -- the spec declares no workspace_root, so this " <>
          "host is assumed to mirror the orchestrator's layout, and containment for both " <>
          "creation and REMOVAL is measured against a path that names a directory here as " <>
          "well. Declare workspace_root on the spec when the host does not mirror it. " <>
          "(logged once per host)"
      )
    end

    :ok
  end

  # One round trip answers both "does it exist" and "create it", so the
  # `created_now` flag that gates `after_create` cannot be decided against a
  # stale observation from a separate probe.
  defp remote_mkdir_p(%HostSpec{} = host, path, ssh_opts) do
    quoted = Ssh.quote_path(path)

    script =
      "if [ -d #{quoted} ]; then printf %s #{@exists_marker}; " <>
        "else mkdir -p #{quoted} && printf %s #{@created_marker}; fi"

    # `{:error, :ssh_not_allowed}` is itself a 2-tuple, so it has to be matched
    # before the `{output, status}` clause that would otherwise swallow it and
    # report an unresolvable `ssh` binary as exit status `:ssh_not_allowed`.
    case remote_fs_exec(host, script, ssh_opts) do
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
      {output, 0} -> interpret_mkdir_output(output)
      {output, status} -> {:error, {:mkdir_failed, {:exit, status, output}}}
    end
  end

  # How long the orchestrator will wait on one filesystem round trip to a host.
  #
  # This bound is the whole point. `ensure/3` and `remove/3` are called from
  # inside the Orchestrator GenServer -- `dispatch_issue_on_host/4`,
  # `ensure_batch_workspaces/2` (once per issue, serially), `gc_abandoned_paused/4`
  # and `terminate_running/4` -- so every second spent here is a second in which
  # nothing else polls, dispatches, reconciles, or answers `snapshot/1`, across
  # all six surfaces.
  #
  # `ssh` bounds only part of that on its own: `ConnectTimeout=15` covers a host
  # that never accepts, but a session that ESTABLISHES and then goes silent is
  # held by `ServerAliveInterval=30` x `ServerAliveCountMax=3`, roughly 105
  # seconds -- multiplied by the number of issues in a batch. The hook path was
  # already bounded (`execute_script_remote/5`); these two were not.
  #
  # Generous relative to the work: `mkdir -p` and `rm -rf` on a workspace are
  # sub-second on a healthy host, so anything approaching this is a sick one.
  @remote_fs_timeout_ms 30_000

  # Note this bounds the WAIT, not the remote command: closing the port does not
  # signal the `ssh` client's own OS process, exactly as `execute_script_remote/5`
  # documents. A `mkdir`/`rm` that outlives this finishes on the host unobserved,
  # which is why the timeout is reported rather than assumed to have done nothing.
  #
  # `:fs_timeout_ms` overrides the bound, through the same `:ssh` option list
  # that injects `:exec_fn`. A deployment whose workspaces are large enough for
  # `rm -rf` to take longer can raise it, and a test can lower it far enough to
  # assert the bound exists without spending the default on it.
  defp remote_fs_exec(%HostSpec{} = host, script, ssh_opts) do
    command = Ssh.remote_bash(script)
    timeout = Keyword.get(ssh_opts, :fs_timeout_ms, @remote_fs_timeout_ms)

    case run_with_timeout(fn -> Ssh.exec(host, command, ssh_opts) end, timeout) do
      {:ok, result} -> result
      :timeout -> {:error, {:timeout, timeout}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interpret_mkdir_output(output) when is_binary(output) do
    cond do
      String.contains?(output, @created_marker) -> {:ok, true}
      String.contains?(output, @exists_marker) -> {:ok, false}
      true -> {:error, {:mkdir_failed, {:unexpected_output, output}}}
    end
  end

  defp interpret_mkdir_output(output),
    do: {:error, {:mkdir_failed, {:unexpected_output, output}}}

  # The removal VERIFIES rather than trusting `rm -rf`'s status. `rm -rf` exits 0
  # for a path that is already gone, and a `before_remove` hook that outlives its
  # deadline can recreate entries under the directory while this runs -- so the
  # only answer worth acting on is whether the path is absent afterwards.
  #
  # Still returns `:ok`: neither caller can retry or unwind, and the orchestrator
  # has already given the host slot back. What a failure is owed is a LOUD log,
  # because its consequence is silent -- the next `ensure/3` on this host finds
  # the directory present, reports `created_now: false`, and skips `after_create`.
  # A run then proceeds in a workspace nothing prepared.
  defp remote_rm_rf(%HostSpec{} = host, path, ssh_opts) do
    quoted = Ssh.quote_path(path)

    case remote_fs_exec(host, "rm -rf #{quoted} && [ ! -e #{quoted} ]", ssh_opts) do
      {_output, 0} ->
        :ok

      {:error, reason} ->
        log_remove_failure(host, path, inspect(reason))

      {output, status} ->
        log_remove_failure(host, path, "exit=#{status} output=#{truncate_for_log(output)}")
    end
  end

  defp log_remove_failure(%HostSpec{} = host, path, detail) do
    Logger.error(
      "symphony.workspace.remote_remove_failed host=#{HostSpec.id(host)} path=#{path} " <>
        "#{detail} -- the directory may survive on the host, and a later run that " <>
        "finds it will REUSE it and skip after_create"
    )

    :ok
  end

  # A hook needs a directory to run IN, and a blank path is not one.
  #
  # `bash`'s `cd ''` SUCCEEDS and changes nothing, so the `cd WS && { … }` guard
  # that carries SPEC s9.5 Invariant 1 across the network passes for an empty
  # workspace and the hook runs in the login shell's home -- exactly the escape
  # the group was built to prevent. Locally it is the same shape: `cd: ""` names
  # no directory either.
  #
  # `GraphAdapter` defaults a missing workspace to `""` in two places
  # (`slot_workspace/2` and `runner_dispatch_node/1`), which is unreachable on
  # today's call paths and is a fail-OPEN default one off-by-one away from being
  # reachable. Refusing here is fail-closed and costs a run attempt, not a
  # workspace: it lands as a `before_run` failure, which SPEC s9.4 already makes
  # fatal to the attempt.
  #
  # Checked here rather than in `run_hook/4` so a workspace with no hooks
  # configured is unaffected -- `:no_hook` never reaches this.
  defp execute_hook_script(_script, path, _timeout_ms, _opts)
       when not is_binary(path),
       do: {:error, {:invalid_workspace, path}}

  defp execute_hook_script(script, path, timeout_ms, opts) do
    if String.trim(path) == "" do
      {:error, {:invalid_workspace, path}}
    else
      do_execute_hook_script(script, path, timeout_ms, opts)
    end
  end

  defp do_execute_hook_script(script, path, timeout_ms, opts) do
    case host_opt(opts) do
      nil ->
        execute_script(script, path, timeout_ms)

      %HostSpec{} = host ->
        execute_script_remote(script, path, timeout_ms, host, ssh_opts(opts))
    end
  end

  # How long the local wait outlasts the remote deadline: one ssh round trip
  # plus slack, so the remote kill is what normally ends the wait.
  @remote_kill_grace_ms 5_000

  # `wait` reports 128+signo, so a hook the remote deadline killed comes back as
  # an exit STATUS rather than a local timeout. It is still a timeout, and
  # reporting `{:exit, 143}` would send an operator looking for a hook that
  # returned 143 deliberately.
  #
  # 143 ONLY (SIGTERM). `Ssh.reap_on_disconnect/2`'s deadline sends a plain
  # `kill`, which is SIGTERM, so 143 is the signature of our own deadline. 137
  # is SIGKILL, which this never sends -- on a host that is almost always the
  # OOM killer, occasionally an operator. Folding it in here reported a host
  # that ran out of memory as a hook that ran too long, which is a different
  # thing to go fix.
  @killed_by_deadline 143

  # `hooks.timeout_ms` is enforced on BOTH sides, because neither alone is
  # enough.
  #
  # The REMOTE deadline is the half that actually stops work. Giving up locally
  # does not: killing the BEAM process closes the port, and closing a port does
  # not signal the OS process it spawned, so the `ssh` client and the hook behind
  # it run on.
  #
  # So the local wait deliberately OUTLASTS the remote deadline. Waiting only
  # `timeout_ms` meant the local half always expired first (the remote deadline
  # rounds up to whole seconds), returning control while the hook was still alive
  # on the host -- and `remove_remote/4` then deleted the workspace out from under
  # a `before_remove` that had not died yet. Waiting past it makes the normal
  # timeout path the remote kill, with the local timer left as a backstop for an
  # `ssh` that never answers at all.
  defp execute_script_remote(script, path, timeout_ms, %HostSpec{} = host, ssh_opts) do
    deadline = deadline_seconds(timeout_ms)
    command = Ssh.remote_bash(path, Ssh.reap_on_disconnect(script, deadline_seconds: deadline))

    fn -> Ssh.exec(host, command, ssh_opts) end
    |> run_with_timeout(local_wait_ms(deadline, timeout_ms))
    |> classify_remote_result(deadline)
  end

  # As in `remote_mkdir_p/3`: the `{:error, _}` shape is a 2-tuple and has to be
  # matched ahead of the `{output, status}` one that would otherwise swallow it.
  defp classify_remote_result({:ok, {:error, reason}}, _deadline), do: {:error, reason}
  defp classify_remote_result({:ok, {output, 0}}, _deadline), do: {:ok, output}

  # A deadline kill collapses to `:timeout`, which carries no output -- and a
  # timeout is exactly when a hook's own output is most worth having, since it
  # says how far the hook got. `execute_named_hook/5` only logs output on the
  # paths that carry it, so the timeout path has to log its own or lose it.
  defp classify_remote_result({:ok, {output, @killed_by_deadline}}, deadline)
       when deadline != nil do
    Logger.warning(
      "symphony.workspace.hook_timed_out deadline_s=#{deadline} " <>
        "output=#{truncate_for_log(output)}"
    )

    {:error, :timeout}
  end

  defp classify_remote_result({:ok, {output, status}}, _deadline),
    do: {:error, {:exit, status, output}}

  defp classify_remote_result({:error, reason}, _deadline), do: {:error, reason}
  defp classify_remote_result(:timeout, _deadline), do: {:error, :timeout}

  # The remote deadline is whole seconds (`sleep`), rounded UP so it can never
  # land before `timeout_ms` and turn an in-budget hook into a kill.
  defp deadline_seconds(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    max(1, ceil(timeout_ms / 1000))
  end

  defp deadline_seconds(_non_positive), do: nil

  # Both forms budget for the CONNECTION as well as the work.
  #
  # The remote deadline is a `sleep` that does not start until `ssh` is up and
  # `bash -lc` is running, so a local timer sized to the deadline alone expires
  # while `ssh` is still dialling. With `ConnectTimeout=15` and a `hooks
  # .timeout_ms` of 10s or less the local half always won that race, and
  # `classify_remote_result/2` then reported a host that never accepted the
  # connection as a hook that ran too long -- fatal to the attempt on
  # `before_run`, with a diagnosis pointing at the hook instead of the host.
  #
  # With no remote deadline the local timer is the only bound there is, so it
  # keeps `timeout_ms` -- plus the same connection budget, for the same reason.
  defp local_wait_ms(nil, timeout_ms), do: max(timeout_ms, 0) + Ssh.connect_timeout_ms()

  defp local_wait_ms(deadline, _timeout_ms),
    do: deadline * 1000 + @remote_kill_grace_ms + Ssh.connect_timeout_ms()

  # Unlinked on purpose: an `ssh` invocation that crashes must not take the
  # calling orchestrator down with it.
  defp run_with_timeout(fun, timeout_ms) do
    {pid, ref} = spawn_monitor(fn -> exit({:hook_result, fun.()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:hook_result, result}} ->
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:hook_process_exited, reason}}
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :timeout
    end
  end

  defp execute_script(script, cwd, timeout_ms) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash_path ->
        # `:in` closes the child's stdin. Without it the port hands the script a
        # pipe that never delivers and never closes, so a setup/verify step
        # that reads stdin blocks until the timeout rather than seeing EOF.
        # Nothing here writes to the port, so there is no input to lose.
        port =
          Port.open(
            {:spawn_executable, bash_path},
            [
              :exit_status,
              :binary,
              :stderr_to_stdout,
              :hide,
              :in,
              {:cd, cwd},
              {:args, ["-lc", script]}
            ]
          )

        collect_output(port, [], timeout_ms)
    end
  end

  defp collect_output(port, acc, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc], timeout_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, IO.iodata_to_binary(Enum.reverse(acc))}}
    after
      timeout_ms ->
        # Giving up on a hook does not stop it. `Port.close/1` signals nothing,
        # so the hook runs on -- and `before_remove` is the sharp case, since
        # `remove/3` then `rm_rf`s the workspace out from under a hook still
        # writing to it. `after_create`'s failure path has the same shape. Past
        # that, a hook that leaks a process per timeout leaks one per retry, and
        # the orchestrator retries.
        #
        # Killed BEFORE the close, not after. Nothing here is waiting on the
        # child's output, so there is no reason to hand it an EOF and then wait
        # out a grace; killing first is the narrowest window available.
        #
        # Narrowest, not zero. An open port does NOT prove the pid is still
        # ours: ERTS withholds the exit status until the inherited stdout
        # reaches EOF, so a hook that backgrounds a child and exits leaves the
        # port open indefinitely while `Port.info/2` goes on naming a pid that
        # has already been reaped. What keeps the reap correct there is
        # `PortReaper.capture/1` resolving the target against the process GROUP
        # rather than that pid -- a group id cannot be recycled while the group
        # still has a member, which is precisely when there is work to do.
        #
        # SIGKILL outright, where the remote deadline sends SIGTERM. There the
        # status is read back (`@killed_by_deadline`); here nothing reads it, we
        # have already stopped waiting, and the workspace may be deleted next.
        target = PortReaper.capture(port)
        reaped = PortReaper.kill(target)
        PortReaper.close(port)
        flush_port_messages(port)
        warn_if_unreaped(reaped, target)
        {:error, :timeout}
    end
  end

  # `remove/3` may `rm_rf` this workspace next, so a kill we could not carry out
  # is not a detail to swallow: the hook is still in there writing to it.
  defp warn_if_unreaped(:ok, _target), do: :ok

  defp warn_if_unreaped({:error, reason}, target) do
    Logger.warning(
      "symphony.workspace.hook_unreaped target=#{inspect(target)} reason=#{inspect(reason)} " <>
        "detail=hook_may_still_be_running"
    )
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp truncate_for_log(output) when is_binary(output) do
    if byte_size(output) <= @hook_log_truncate_bytes do
      output
    else
      <<head::binary-size(@hook_log_truncate_bytes), _::binary>> = output
      head <> "...[truncated]"
    end
  end
end
