defmodule Raxol.Core.Runtime.Lifecycle.Shutdown do
  @moduledoc """
  Shutdown, cleanup, and registry management helpers for Lifecycle.
  Extracted from Lifecycle to reduce file size.
  """

  alias Raxol.Core.CompilerState
  alias Raxol.Core.Runtime.Log

  @doc """
  Stops a supervised process by PID; no-ops on nil or dead processes.

  Returns `:ok`, or `{:error, reason}` when the process did not stop
  cleanly: `GenServer.stop/3` exits (it does not raise) when the process
  crashes in its `terminate/2` or overruns the timeout. A process that
  overruns the timeout is killed before this returns; `GenServer.stop/3`
  leaves it running.

  Never exits the caller, so the Lifecycle's ordered teardown goes on to
  stop the remaining children. Reporting a failure is the caller's (see
  `report_stop_failures/1`): on a TTY the teardown runs inside `quietly/3`.
  """
  @spec stop_process(pid() | nil, String.t()) :: :ok | {:error, term()}
  def stop_process(nil, _label), do: :ok

  def stop_process(pid, label) when is_pid(pid) do
    if Process.alive?(pid) do
      Log.info_with_context(
        "[Lifecycle] Stopping #{label} PID: #{inspect(pid)}"
      )

      GenServer.stop(pid, :shutdown, Raxol.Core.Defaults.shutdown_timeout_ms())
    end

    :ok
  catch
    # Gone before the stop reached it, on its own and cleanly.
    :exit, {reason, {GenServer, :stop, _}} when reason in [:noproc, :normal] ->
      Log.debug("[Shutdown] #{label} #{inspect(pid)} had already exited")
      :ok

    :exit, {:timeout, _} = reason ->
      kill(pid)
      {:error, reason}

    :exit, reason ->
      {:error, reason}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @doc """
  Logs each `{label, pid, reason}` that `stop_process/2` failed on.
  """
  @spec report_stop_failures([{String.t(), pid(), term()}]) :: :ok
  def report_stop_failures(failures) do
    Enum.each(failures, fn {label, pid, reason} ->
      Log.error_with_context(
        "[Shutdown] #{label} #{inspect(pid)} did not stop cleanly",
        %{label: label, pid: pid, reason: reason}
      )
    end)
  end

  @doc """
  Runs `fun`; when `silent?` is true, log events from the caller and from
  `pids` are dropped until `fun` returns or exits. Other processes log as
  usual.

  On a TTY the Terminal Driver turns Logger off for the session and, when it
  is stopped, restores the level it found. The Driver is stopped first, so
  without this whatever the rest of the teardown logs prints on the terminal
  the Driver has just restored. A primary filter rather than the level: the
  Driver's restore inside `fun` must not reopen the window.

  Each call installs its own filter, so concurrent teardowns cannot lift
  each other's silence. The filter belongs to a process that monitors the
  caller and removes it when `fun` is done or the caller dies: a killed
  caller runs no `after`, and a supervisor's shutdown timeout can kill a
  Lifecycle mid-teardown.
  """
  @spec quietly(boolean(), [pid()], (-> result)) :: result when result: term()
  def quietly(false, _pids, fun), do: fun.()

  def quietly(true, pids, fun) do
    caller = self()

    {owner, ref} =
      spawn_monitor(fn -> hold_quiet_filter(caller, [caller | pids]) end)

    receive do
      {^owner, :silenced} ->
        try do
          fun.()
        after
          send(owner, {caller, :done})

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
          end
        end

      # The owner crashed installing the filter (its crash report says
      # why), so there is no silence to hold.
      {:DOWN, ^ref, :process, ^owner, _reason} ->
        fun.()
    end
  end

  # The filter id is an atom (`:logger` accepts no other), made per call.
  defp hold_quiet_filter(caller, pids) do
    caller_ref = Process.monitor(caller)
    filter = :"raxol_lifecycle_teardown_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_primary_filter(filter, {&__MODULE__.drop_log_event/2, pids})

    send(caller, {self(), :silenced})

    receive do
      {^caller, :done} -> :ok
      {:DOWN, ^caller_ref, :process, ^caller, _reason} -> :ok
    end

    :ok = :logger.remove_primary_filter(filter)
  end

  @doc false
  def drop_log_event(%{meta: %{pid: pid}}, pids) do
    if pid in pids, do: :stop, else: :ignore
  end

  def drop_log_event(_event, _pids), do: :ignore

  @doc """
  Cleans up the PluginManager if it is still alive.
  """
  def cleanup_plugin_manager(nil, _state), do: :ok
  def cleanup_plugin_manager(false, _state), do: :ok

  def cleanup_plugin_manager(true, state) do
    Log.info_with_context(
      "[Lifecycle] Terminate: Ensuring PluginManager PID #{inspect(state.plugin_manager)} is stopped."
    )

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           GenServer.stop(state.plugin_manager, :shutdown, :infinity)
         end) do
      {:ok, _result} ->
        :ok

      {:error, _reason} ->
        Log.warning_with_context(
          "[Lifecycle] Terminate: Failed to explicitly stop PluginManager #{inspect(state.plugin_manager)}, it might have already stopped.",
          %{}
        )
    end
  end

  @doc """
  Deletes the command registry ETS table if it exists.
  """
  def cleanup_registry_table(nil, _state), do: :ok
  def cleanup_registry_table(false, _state), do: :ok

  def cleanup_registry_table(true, state) do
    case CompilerState.safe_delete_table(state.command_registry_table) do
      :ok ->
        Log.debug(
          "[Lifecycle] Deleted ETS table: #{inspect(state.command_registry_table)}"
        )

      {:error, :table_not_found} ->
        Log.debug(
          "[Lifecycle] ETS table #{inspect(state.command_registry_table)} not found or already deleted."
        )
    end
  end
end
