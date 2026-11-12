defmodule Raxol.Agent.ClientProtocol.Turn do
  @moduledoc """
  One `session/prompt` as one turn of a Raxol agent.

  `runner/1` builds the `:turn_runner` of a
  `Raxol.AgentClientProtocol.Session`. The runner sends the agent an
  `{:acp_prompt, text, approver}` (the turn contract in `Raxol.Agent.Comm`),
  where `text` is the prompt's text blocks joined by a newline and
  `approver` is `Raxol.Agent.ClientProtocol.Permission.authorizer/2`. The
  agent's reply is posted as one `agent_message_chunk` ahead of the prompt
  response; there is no token streaming.

  ## Cancel

  On `session/cancel` the runner sends the turn's `{:acp_cancel, ref}` and
  waits for the agent session's answer, which comes once the turn's process
  is down. The prompt is answered `cancelled` only then, so the turn's
  process is gone when the client hears of it (work an agent runs inline in
  `update/2` is not stopped; see `Raxol.Agent.Comm`). The agent session
  gives a turn process that traps exits
  `config :raxol_agent, :turn_cancel_grace_ms` to stop, and journals the
  turn's brackets (`turn_started`, then `turn_completed`, `turn_canceled` or
  `error`). A runner still waiting when the ACP session's cancel backstop
  fires is killed, and the agent session then cancels the turn because its
  caller is down.

  ## Budget

  A prompt is refused while `Raxol.Agent.ClientProtocol.Budget` reports a
  cap exceeded, and each answered turn's `usage` is recorded there.

  ## Errors

  A turn that cannot be answered is a JSON-RPC internal error whose `data`
  carries a `tag` and a `reason`: `budget_exhausted`, `agent_not_running`,
  `agent_down`, `turn_failed` (the agent answered `{:error, reason}`) or
  `turn_reply_invalid` (the reply is not `{:ok, text, usage}`).
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Ctx,
              Raxol.AgentClientProtocol.Error,
              Raxol.AgentClientProtocol.Schema.ContentBlock,
              Raxol.AgentClientProtocol.Schema.ContentChunk,
              Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
            ]}

  require Logger

  alias Raxol.Agent.ClientProtocol.Budget
  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.Comm

  @ctx Raxol.AgentClientProtocol.Ctx
  @error Raxol.AgentClientProtocol.Error
  @content_block Raxol.AgentClientProtocol.Schema.ContentBlock
  @content_chunk Raxol.AgentClientProtocol.Schema.ContentChunk
  @notification Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  @registry Raxol.Agent.Registry
  @reason_limit 2_000

  @typedoc "What `Raxol.AgentClientProtocol.Session` takes as `:turn_runner`."
  @type runner :: (pid(), map() -> {:stop, atom()} | {:error, struct()})

  @typep turn :: %{
           session: pid(),
           session_id: String.t(),
           agent_id: String.t(),
           ref: reference(),
           agent_mref: reference()
         }

  @doc "The turn runner that prompts agent `agent_id`."
  @spec runner(String.t()) :: runner()
  def runner(agent_id) when is_binary(agent_id) do
    fn session, request -> run(session, request, agent_id) end
  end

  defp run(session, request, agent_id) do
    case Budget.check() do
      :ok -> prompt(session, request, agent_id)
      {:exceeded, cap} -> {:error, error(:budget_exhausted, cap)}
    end
  end

  # The prompt goes out in the envelope `Raxol.Agent.Comm.call/4` sends, so
  # this process can also take the session's `:acp_cancel` while it waits.
  defp prompt(session, request, agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{agent, _value}] ->
        turn = %{
          session: session,
          session_id: request.session_id,
          agent_id: agent_id,
          ref: make_ref(),
          agent_mref: Process.monitor(agent)
        }

        approver = Permission.authorizer(session, turn.session_id)
        envelope = {:call, self(), turn.ref, {:acp_prompt, text(request), approver}}
        _ = Comm.send(agent_id, envelope)
        await(turn)

      [] ->
        {:error, error(:agent_not_running, agent_id)}
    end
  end

  @spec await(turn()) :: {:stop, atom()} | {:error, struct()}
  defp await(%{ref: ref, agent_mref: agent_mref} = turn) do
    receive do
      {:agent_reply, ^ref, reply} -> answer(turn, reply)
      :acp_cancel -> cancel(turn)
      {:DOWN, ^agent_mref, :process, _pid, _reason} -> agent_down(turn)
    end
  end

  defp answer(turn, {:ok, text, usage}) when is_binary(text) and is_map(usage) do
    Budget.record(usage)
    Permission.settle(turn.session, turn.session_id, :completed)
    post_reply(turn, text)
    {:stop, :end_turn}
  end

  defp answer(turn, reply) do
    Permission.settle(turn.session, turn.session_id, :failed)
    refusal(reply)
  end

  defp refusal({:error, :cancelled}), do: {:stop, :cancelled}
  defp refusal({:error, reason}) when is_atom(reason), do: {:error, error(:turn_failed, reason)}
  defp refusal(_reply), do: {:error, error(:turn_reply_invalid, :not_ok_text_usage)}

  # The session answers the prompt once the turn's process is down. A reply
  # that was already on its way is still delivered: the agent did that work.
  defp cancel(%{ref: ref, agent_mref: agent_mref} = turn) do
    _ = Comm.send(turn.agent_id, {:acp_cancel, ref})

    receive do
      {:agent_reply, ^ref, reply} -> answer(turn, reply)
      {:DOWN, ^agent_mref, :process, _pid, _reason} -> agent_down(turn)
    end

    {:stop, :cancelled}
  end

  # The agent session restarted with its tree: a prompt that reached the new
  # one is cancelled there.
  defp agent_down(turn) do
    _ = Comm.send(turn.agent_id, {:acp_cancel, turn.ref})
    Permission.settle(turn.session, turn.session_id, :failed)
    {:error, error(:agent_down, turn.agent_id)}
  end

  # The session refuses an empty chunk.
  defp post_reply(_turn, ""), do: :ok

  defp post_reply(turn, text) do
    chunk = @content_chunk.new(@content_block.from_string(text))
    notification = @notification.new(turn.session_id, {:agent_message_chunk, chunk})
    _ = @ctx.post_update(turn.session, notification)
    :ok
  end

  defp text(%{prompt: blocks}) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      {:text, %{text: text}} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp text(_request), do: ""

  # Logged for the operator and carried to the client, which shows `data`.
  defp error(tag, reason) do
    detail = reason |> inspect() |> String.slice(0, @reason_limit)
    Logger.error("[acp] #{tag}: #{detail}")

    @error.with_data(@error.internal_error(), %{
      "tag" => Atom.to_string(tag),
      "reason" => detail
    })
  end
end
