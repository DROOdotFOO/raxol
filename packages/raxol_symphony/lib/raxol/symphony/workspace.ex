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
  used as-is, which assumes the host mirrors the orchestrator's layout. Declare
  `workspace_root` per host when it does not.

  `:ssh` forwards options to `Raxol.Symphony.Ssh.exec/3` (`:exec_fn`,
  `:executable`), so the remote lifecycle is testable without a real SSH server.
  """

  require Logger

  alias Raxol.Symphony.{Config, PathSafety, Ssh}
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

  # A spec that declares no root falls back to the configured local root,
  # which assumes the host mirrors the orchestrator's layout.
  defp remote_root(%Config{}, %HostSpec{workspace_root: root})
       when is_binary(root) and root != "",
       do: root

  defp remote_root(%Config{} = config, %HostSpec{}), do: config.workspace.root

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
    case Ssh.exec(host, Ssh.remote_bash(script), ssh_opts) do
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
      {output, 0} -> interpret_mkdir_output(output)
      {output, status} -> {:error, {:mkdir_failed, {:exit, status, output}}}
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

  defp remote_rm_rf(%HostSpec{} = host, path, ssh_opts) do
    command = Ssh.remote_bash("rm -rf #{Ssh.quote_path(path)}")

    case Ssh.exec(host, command, ssh_opts) do
      {:error, reason} ->
        Logger.warning(
          "symphony.workspace.remote_remove_failed host=#{HostSpec.id(host)} path=#{path} " <>
            "reason=#{inspect(reason)}"
        )

        :ok

      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning(
          "symphony.workspace.remote_remove_failed host=#{HostSpec.id(host)} path=#{path} " <>
            "exit=#{status} output=#{truncate_for_log(output)}"
        )

        :ok
    end
  end

  defp execute_hook_script(script, path, timeout_ms, opts) do
    case host_opt(opts) do
      nil ->
        execute_script(script, path, timeout_ms)

      %HostSpec{} = host ->
        execute_script_remote(script, path, timeout_ms, host, ssh_opts(opts))
    end
  end

  # `hooks.timeout_ms` is enforced on BOTH sides, because neither alone is
  # enough.
  #
  # Locally, `run_with_timeout/2` returns control to the orchestrator on time.
  # It does NOT stop the work: killing the BEAM process closes the port, and
  # closing a port does not signal the OS process it spawned, so the `ssh`
  # client (and the hook behind it) runs on. Relying on that alone left a
  # timed-out `before_remove` hook still executing on the host while
  # `remote_rm_rf/3` deleted the workspace underneath it.
  #
  # So the remote side carries the same deadline and kills the hook itself.
  # That is the half that actually bounds the work; the local half only bounds
  # how long we wait for it.
  defp execute_script_remote(script, path, timeout_ms, %HostSpec{} = host, ssh_opts) do
    reaped = Ssh.reap_on_disconnect(script, deadline_seconds: deadline_seconds(timeout_ms))
    command = Ssh.remote_bash(path, reaped)

    case run_with_timeout(fn -> Ssh.exec(host, command, ssh_opts) end, timeout_ms) do
      # As in `remote_mkdir_p/3`: the `{:error, _}` shape is a 2-tuple and has
      # to be matched ahead of `{output, status}`.
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:exit, status, output}}
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, :timeout}
    end
  end

  # The remote deadline is whole seconds (`sleep`), rounded UP so it can never
  # land before the local timeout and turn an in-budget hook into a kill.
  # A sub-second timeout still gets a full second remotely: the local half
  # gives up first, which is the intended ordering.
  defp deadline_seconds(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    max(1, ceil(timeout_ms / 1000))
  end

  defp deadline_seconds(_non_positive), do: nil

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
        # Port.close kills the OS process via SIGKILL when :exit_status was
        # requested. Drain the message queue to avoid leaks.
        Port.close(port)
        flush_port_messages(port)
        {:error, :timeout}
    end
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
