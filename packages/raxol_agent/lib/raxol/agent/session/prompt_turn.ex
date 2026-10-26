defmodule Raxol.Agent.Session.PromptTurn do
  @moduledoc false
  # The process behind `Raxol.Agent.Comm.run_turn/3`. An owner that traps
  # exits runs the turn's work in a linked worker and sends the worker's
  # return to the session as `{:agent_reply, ref, reply}`, or
  # `{:acp_turn_failed, ref, owner}` when the work fails or the worker dies. The
  # owner, not the worker, is what the session monitors, so `abort/2` can
  # return only after the worker is dead, and the work also dies with the
  # session or the owner.

  require Logger

  @doc "Start the turn for `session`. Returns `{owner_pid, monitor_ref}`."
  @spec start(pid(), reference(), (-> term())) :: {pid(), reference()}
  def start(session, ref, fun) do
    spawn_monitor(fn -> own(session, ref, fun) end)
  end

  @doc "Kill the turn's worker and wait until the owner is down."
  @spec abort(pid(), reference()) :: :ok
  def abort(owner, mref) do
    send(owner, :abort)

    receive do
      {:DOWN, ^mref, :process, ^owner, _reason} -> :ok
    end
  end

  @doc """
  Name an exit reason by its shape (exception module or leading atom), never
  its content: a turn's failure can carry what its approver or work handled.
  """
  @spec failure_shape(term()) :: String.t()
  def failure_shape({%{__exception__: true, __struct__: module}, _stacktrace}),
    do: inspect(module)

  def failure_shape(%{__exception__: true, __struct__: module}), do: inspect(module)
  def failure_shape(reason) when is_atom(reason), do: inspect(reason)
  def failure_shape({{tag, _value}, _stacktrace}) when is_atom(tag), do: inspect(tag)
  def failure_shape({tag, _detail}) when is_atom(tag), do: inspect(tag)
  def failure_shape(_reason), do: "an unnamed reason"

  defp own(session, ref, fun) do
    Process.flag(:trap_exit, true)
    session_mref = Process.monitor(session)
    owner = self()
    worker = spawn_link(fn -> send(owner, {:result, self(), run(fun)}) end)
    loop(session, session_mref, ref, worker)
  end

  # A raise caught here never reaches the emulator's crash report, which
  # would log the exception's message: only its shape is kept.
  defp run(fun) do
    {:ok, fun.()}
  catch
    :error, reason ->
      {:failed, failure_shape(Exception.normalize(:error, reason, __STACKTRACE__))}

    :exit, reason ->
      {:failed, failure_shape(reason)}

    :throw, _value ->
      {:failed, ":throw"}
  end

  defp loop(session, session_mref, ref, worker) do
    receive do
      {:result, ^worker, {:ok, reply}} ->
        send(session, {:agent_reply, ref, reply})

      {:result, ^worker, {:failed, shape}} ->
        failed(session, ref, shape)

      {:EXIT, ^worker, reason} ->
        failed(session, ref, failure_shape(reason))

      {:turn_message, message} ->
        send(worker, message)
        loop(session, session_mref, ref, worker)

      :abort ->
        kill(worker)

      {:DOWN, ^session_mref, :process, ^session, _reason} ->
        kill(worker)
    end
  end

  defp failed(session, ref, shape) do
    Logger.warning("[Agent.Session] turn #{inspect(ref)} failed: #{shape}")
    send(session, {:acp_turn_failed, ref, self()})
  end

  defp kill(worker) do
    Process.exit(worker, :kill)

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    end
  end
end
