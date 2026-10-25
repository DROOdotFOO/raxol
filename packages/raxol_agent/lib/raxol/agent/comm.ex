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

  ## Agent turn contract

  `call(agent, {:acp_prompt, text, approver}, timeout)` asks the agent for
  one turn, answered `{:ok, text, usage}` (so the call returns
  `{:ok, {:ok, text, usage}}`). `approver` is an arity-3 `:tool_authorizer`
  (see `Raxol.Agent.ToolPolicy`) that the turn's tool calls must pass. The
  timeout is required, as a timeout cancels the turn: `call/2` refuses a
  prompt with `{:error, :timeout_required}` without sending it (other
  messages keep the 5 s default). Pass `:infinity` for a turn with no limit.

  The session proxies the turn: the agent's `update/2` sees
  `{:call, session_pid, ref, {:acp_prompt, text, approver}}` and answers it
  inline with `reply/3`, or with `run_turn/3` for work that blocks. A
  `{:acp_cancel, ref}` (via `send/3`, or `call/3` for an `:ok` that returns
  once the turn's process is dead) kills that process, answers the prompt
  `{:error, :cancelled}` and is then forwarded to `update/2`. Pass
  `ref: ref` to `call/4` to know the prompt's ref; it must be a fresh
  `make_ref/0`, used for one call only. A prompt is also cancelled when its
  caller goes down, or when `call/4` times out (the `{:error, :cancelled}`
  answer may then arrive in the caller's mailbox as a stray reply).

  An agent consults `approver`, and runs the actions it gates, in the
  `run_turn/3` process, never inline in `update/2`: an inline ask would
  block the whole agent until it is answered, and a cancel stops only the
  `run_turn/3` process, so inline work is neither stopped nor undone. A turn
  process that changes agent state sends the change to the agent process
  (`self()` in `update/2`) as `{:command_result, msg}`, which `update/2`
  receives; `Raxol.Agent.Reference.Counter` shows the pattern.

  Besides `{:ok, text, usage}`, a prompt can be answered:

    * `{:error, :invalid_prompt}` - `text` is not a binary or `approver` is
      not an arity-3 function
    * `{:error, :duplicate_ref}` - `ref` already names an in-flight turn of
      that agent
    * `{:error, :no_dispatcher}` - the agent is not running (its lifecycle
      is starting or restarting)
    * `{:error, :turn_failed}` - the `run_turn/3` process crashed or was
      killed from outside
    * `{:error, :cancelled}` - the turn was cancelled

  A cancel sent with `call/3` answers `:ok`, or `{:error, :not_found}` when
  no in-flight turn has that ref.
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
  `call/4` with the default 5 s timeout, for any message except an
  `{:acp_prompt, text, approver}`: a prompt needs an explicit timeout (it
  cancels the turn), so it is refused with `{:error, :timeout_required}`
  and never sent.
  """
  @spec call(term(), term()) ::
          {:ok, term()} | {:error, :timeout | :not_found | :agent_down | :timeout_required}
  def call(target_id, message)

  def call(_target_id, {:acp_prompt, _text, _approver}), do: {:error, :timeout_required}
  def call(target_id, message), do: call(target_id, message, 5_000)

  @doc """
  Synchronous request-reply with another agent.

  The target agent must answer with `reply/3` (see the module doc);
  otherwise this returns `{:error, :timeout}`. A target that dies before
  replying fails fast with `{:error, :agent_down}` instead of waiting out
  the timeout.

  Pass `ref: ref` to choose the request's ref (default `make_ref()`), so
  another process can name the request, as in `{:acp_cancel, ref}`. `ref`
  must be a fresh reference used for one call only: a late reply to an
  earlier call with the same ref would be taken as this call's answer.
  Raises `ArgumentError` when `ref` is not a reference.

  When an `{:acp_prompt, text, approver}` call times out, it sends the
  turn's `{:acp_cancel, ref}` before returning `{:error, :timeout}`.
  """
  @spec call(term(), term(), timeout(), keyword()) ::
          {:ok, term()} | {:error, :timeout | :not_found | :agent_down}
  def call(target_id, message, timeout, opts \\ []) do
    ref = call_ref(opts)

    case Registry.lookup(Raxol.Agent.Registry, target_id) do
      [{pid, _}] ->
        mref = Process.monitor(pid)
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
            cancel_abandoned(pid, ref, message)
            flush_reply(ref)
            {:error, :timeout}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp call_ref(opts) do
    case Keyword.get_lazy(opts, :ref, &make_ref/0) do
      ref when is_reference(ref) -> ref
      other -> raise ArgumentError, "Comm.call/4 :ref must be a reference, got: #{inspect(other)}"
    end
  end

  # A prompt nobody waits for any more is aborted, not left running.
  defp cancel_abandoned(pid, ref, {:acp_prompt, _text, _approver}),
    do: GenServer.cast(pid, {:send_message, {:acp_cancel, ref}})

  defp cancel_abandoned(_pid, _ref, _message), do: :ok

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
  Answer an `{:acp_prompt, text, approver}` call by running `fun` in a turn
  process the session owns; `fun`'s return is the reply. `{:acp_cancel, ref}`
  kills that process. Call it from `update/2` with the prompt's `ref` and
  `session`, the pid in the prompt's caller position (the session stands in
  for the real caller).
  """
  @spec run_turn(pid(), reference(), (-> term())) :: :ok
  def run_turn(session, ref, fun)
      when is_pid(session) and is_reference(ref) and is_function(fun, 0) do
    Kernel.send(session, {:acp_run, ref, fun})
    :ok
  end

  @doc """
  Send `message` to the process running turn `ref` of `session` (see
  `run_turn/3`).
  """
  @spec send_turn(pid(), reference(), term()) :: :ok
  def send_turn(session, ref, message) when is_pid(session) and is_reference(ref) do
    Kernel.send(session, {:acp_turn_message, ref, message})
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
