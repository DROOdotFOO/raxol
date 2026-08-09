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
  """

  require Logger

  alias Raxol.Symphony.{Config, PathSafety}

  @type ensure_result :: %{
          path: Path.t(),
          key: binary(),
          created_now: boolean()
        }

  @type ensure_error ::
          :workspace_outside_root
          | :invalid_workspace_root
          | {:mkdir_failed, term()}
          | {:after_create_hook_failed, term()}

  @hook_log_truncate_bytes 4096

  @doc """
  Ensures the per-issue workspace directory exists.

  Returns `{:ok, %{path, key, created_now}}` or `{:error, reason}`.
  """
  @spec ensure(Config.t(), binary()) :: {:ok, ensure_result()} | {:error, ensure_error()}
  def ensure(%Config{} = config, identifier) when is_binary(identifier) do
    with {:ok, path} <- PathSafety.workspace_path(config.workspace.root, identifier),
         {:ok, created_now} <- mkdir_p(path),
         :ok <- maybe_run_after_create(config, path, created_now) do
      {:ok, %{path: path, key: PathSafety.sanitize_key(identifier), created_now: created_now}}
    end
  end

  @doc """
  Runs `hooks.before_run` for the workspace. Returns `:ok` or `{:error, reason}`.
  """
  @spec run_before_run_hook(Config.t(), Path.t()) :: :ok | {:error, term()}
  def run_before_run_hook(%Config{} = config, path) do
    case run_hook(config, :before_run, path) do
      :ok -> :ok
      :no_hook -> :ok
      {:error, reason} -> {:error, {:before_run_hook_failed, reason}}
    end
  end

  @doc """
  Runs `hooks.after_run` for the workspace. Failures are logged but ignored.
  """
  @spec run_after_run_hook(Config.t(), Path.t()) :: :ok
  def run_after_run_hook(%Config{} = config, path) do
    case run_hook(config, :after_run, path) do
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
  """
  @spec remove(Config.t(), Path.t()) :: :ok
  def remove(%Config{} = config, path) when is_binary(path) do
    case PathSafety.validate_inside_root(path, config.workspace.root) do
      {:ok, abs_path} ->
        run_before_remove(config, abs_path)
        File.rm_rf(abs_path)
        :ok

      {:error, reason} ->
        Logger.warning("symphony.workspace.remove_skipped path=#{path} reason=#{inspect(reason)}")

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
  @spec run_hook(Config.t(), :after_create | :before_run | :after_run | :before_remove, Path.t()) ::
          :ok | :no_hook | {:error, term()}
  def run_hook(%Config{hooks: hooks}, hook_name, path)
      when hook_name in [:after_create, :before_run, :after_run, :before_remove] do
    case Map.get(hooks, hook_name) do
      script when is_nil(script) or script == "" ->
        :no_hook

      script ->
        execute_named_hook(hook_name, script, path, hooks.timeout_ms)
    end
  end

  defp execute_named_hook(hook_name, script, path, timeout_ms) do
    Logger.info("symphony.workspace.hook_started hook=#{hook_name} path=#{path}")

    case execute_script(script, path, timeout_ms) do
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

  defp maybe_run_after_create(_config, _path, false), do: :ok

  defp maybe_run_after_create(config, path, true) do
    case run_hook(config, :after_create, path) do
      :ok ->
        :ok

      :no_hook ->
        :ok

      {:error, reason} ->
        # Best-effort: remove the partially-prepared directory so the next run
        # can retry from scratch (per SPEC s9.3 implementation guidance).
        File.rm_rf(path)
        {:error, {:after_create_hook_failed, reason}}
    end
  end

  defp run_before_remove(config, path) do
    case run_hook(config, :before_remove, path) do
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
