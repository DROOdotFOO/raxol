defmodule Raxol.Core.Runtime.Lifecycle.Shutdown do
  @moduledoc """
  Shutdown, cleanup, and registry management helpers for Lifecycle.
  Extracted from Lifecycle to reduce file size.
  """

  alias Raxol.Core.CompilerState
  alias Raxol.Core.Runtime.Log

  @quiet_filter :raxol_lifecycle_teardown

  @doc """
  Stops a supervised process by PID; no-ops on nil or dead processes.

  Never exits the caller. `GenServer.stop/3` exits (it does not raise) when
  the process crashes in its `terminate/2`, is already gone, or overruns the
  timeout; that exit is logged and swallowed here so the Lifecycle's ordered
  teardown goes on to stop the remaining children.
  """
  def stop_process(nil, _label), do: :ok

  def stop_process(pid, label) when is_pid(pid) do
    if Process.alive?(pid) do
      Log.info_with_context(
        "[Lifecycle] Stopping #{label} PID: #{inspect(pid)}"
      )

      GenServer.stop(pid, :shutdown, Raxol.Core.Defaults.shutdown_timeout_ms())
    end
  catch
    :exit, {:noproc, _} ->
      Log.debug("[Shutdown] #{label} #{inspect(pid)} had already exited")
      :ok

    :exit, reason ->
      Log.warning_with_context(
        "[Shutdown] #{label} #{inspect(pid)} did not stop cleanly; continuing teardown",
        %{label: label, pid: pid, reason: reason}
      )

      :ok
  end

  @doc """
  Runs `fun`; when the first argument is true, every log event is dropped
  until `fun` returns or exits.

  On a TTY the Terminal Driver turns Logger off for the session and, when it
  is stopped, restores the level it found. The Driver is stopped first, so
  without this whatever the rest of the teardown logs prints on the terminal
  the Driver has just restored. A primary filter rather than the level: the
  Driver's restore inside `fun` must not reopen the window.
  """
  @spec quietly(boolean(), (-> result)) :: result when result: term()
  def quietly(false, fun), do: fun.()

  def quietly(true, fun) do
    case :logger.add_primary_filter(
           @quiet_filter,
           {&__MODULE__.drop_log_event/2, nil}
         ) do
      :ok ->
        try do
          fun.()
        after
          :logger.remove_primary_filter(@quiet_filter)
        end

      # Another teardown already holds the filter and will remove it.
      {:error, {:already_exist, @quiet_filter}} ->
        fun.()
    end
  end

  @doc false
  def drop_log_event(_event, _extra), do: :stop

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
