defmodule Raxol.Agent.Comm do
  @moduledoc """
  Agent communication primitives.

  Agents discover each other via `Raxol.Agent.Registry` and communicate
  through their Session GenServers. Messages arrive in the target agent's
  `update/2` as `{:agent_message, from_id, payload}` — `from_id` is the
  sender's agent id when the sender identified itself (the `:from` option
  to `send/3`), `nil` otherwise. The framework never guesses a sender.

  ## Request-reply

  `call/3` delivers `{:call, caller_pid, ref, message}` as the payload of
  an `:agent_message`. The receiving agent answers with `reply/3`;
  without a reply the caller times out:

      def update({:agent_message, _from, {:call, caller, ref, question}}, model) do
        Raxol.Agent.Comm.reply(caller, ref, answer(question, model))
        {model, []}
      end
  """

  alias Raxol.Agent.Session

  @doc """
  Send an async message to another agent by id.

  Pass `from: my_agent_id` to identify the sender; it arrives as the
  second element of the `:agent_message` tuple (`nil` when omitted).
  """
  @spec send(term(), term(), keyword()) :: :ok | {:error, :not_found}
  def send(target_id, message, opts \\ []) do
    Session.send_message(target_id, message, Keyword.take(opts, [:from]))
  end

  @doc """
  Synchronous request-reply with another agent.

  The target agent must answer with `reply/3` (see the module doc);
  otherwise this returns `{:error, :timeout}`. A target that dies before
  replying fails fast with `{:error, :agent_down}` instead of waiting out
  the timeout.
  """
  @spec call(term(), term(), timeout()) ::
          {:ok, term()} | {:error, :timeout | :not_found | :agent_down}
  def call(target_id, message, timeout \\ 5_000) do
    case Registry.lookup(Raxol.Agent.Registry, target_id) do
      [{pid, _}] ->
        mref = Process.monitor(pid)
        ref = make_ref()
        GenServer.cast(pid, {:send_message, {:call, self(), ref, message}})

        receive do
          {:agent_reply, ^ref, reply} ->
            Process.demonitor(mref, [:flush])
            {:ok, reply}

          {:DOWN, ^mref, :process, ^pid, _reason} ->
            {:error, :agent_down}
        after
          timeout ->
            Process.demonitor(mref, [:flush])
            flush_reply(ref)
            {:error, :timeout}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Best-effort sweep of a reply that raced the timeout. A reply arriving
  # after this returns is abandoned in the caller's mailbox; callers doing
  # selective receives should treat stray {:agent_reply, _, _} as noise.
  defp flush_reply(ref) do
    receive do
      {:agent_reply, ^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  @doc "Answer a `{:call, caller, ref, message}` received via `call/3`."
  @spec reply(pid(), reference(), term()) :: :ok
  def reply(caller, ref, response) when is_pid(caller) and is_reference(ref) do
    Kernel.send(caller, {:agent_reply, ref, response})
    :ok
  end

  @doc """
  Broadcast a message to all agents in a team.

  Delivery is filtered by the receiving session's `team_id` (set by
  `Raxol.Agent.Team` or the `:team_id` start option): only members of
  `team_id` see the message, as
  `{:agent_message, nil, {:team_broadcast, team_id, message}}`.
  """
  @spec broadcast_team(term(), term()) :: :ok
  def broadcast_team(team_id, message) do
    # Sessions register with the value :session; auxiliary entries in the
    # same Registry (lifecycles, emit bridges) carry other values and must
    # not receive the cast. uniq_by guards against a pid registered under
    # more than one session key.
    Registry.select(Raxol.Agent.Registry, [
      {{:"$1", :"$2", :session}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.uniq_by(fn {_id, pid} -> pid end)
    |> Enum.each(fn {_id, pid} ->
      GenServer.cast(pid, {:send_message, {:team_broadcast, team_id, message}})
    end)

    :ok
  end
end
