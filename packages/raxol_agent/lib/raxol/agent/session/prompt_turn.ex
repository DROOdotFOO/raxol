defmodule Raxol.Agent.Session.PromptTurn do
  @moduledoc false
  # The process behind `Raxol.Agent.Comm.run_turn/3`. An owner that traps
  # exits runs the turn's work in a linked worker and sends the worker's
  # return to the session as `{:agent_reply, ref, reply}`. The owner, not the
  # worker, is what the session monitors, so `abort/2` can return only after
  # the worker is dead, and the work also dies with the session or the owner.

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

  defp own(session, ref, fun) do
    Process.flag(:trap_exit, true)
    session_mref = Process.monitor(session)
    owner = self()
    worker = spawn_link(fn -> send(owner, {:result, self(), fun.()}) end)
    loop(session, session_mref, ref, worker)
  end

  defp loop(session, session_mref, ref, worker) do
    receive do
      {:result, ^worker, reply} ->
        send(session, {:agent_reply, ref, reply})

      {:EXIT, ^worker, reason} ->
        Logger.warning("[Agent.Session] turn #{inspect(ref)} failed: #{inspect(reason)}")
        send(session, {:agent_reply, ref, {:error, :turn_failed}})

      {:turn_message, message} ->
        send(worker, message)
        loop(session, session_mref, ref, worker)

      :abort ->
        kill(worker)

      {:DOWN, ^session_mref, :process, ^session, _reason} ->
        kill(worker)
    end
  end

  defp kill(worker) do
    Process.exit(worker, :kill)

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    end
  end
end
