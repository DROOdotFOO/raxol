defmodule Raxol.Agent.ClientProtocol.Permission do
  @moduledoc """
  The tool authorizer of an ACP turn: the `approver` an agent receives with
  `{:acp_prompt, text, approver}` (see `Raxol.Agent.Comm`).

  Every tool call the agent runs past it is announced to the client as a
  `tool_call` update. A call to an action marked `sensitive` then waits on
  one `session/request_permission`, offering allow-once and reject-once; any
  other action is allowed without a round trip.

  ## What the client is shown

  The announcement and the permission request carry the action's name as the
  title and the call's params as `rawInput`, bounded by
  `Raxol.Agent.ClientProtocol.RawInput`: a call is allowed or rejected with
  its arguments in view.

  ## Denials

  `Raxol.AgentClientProtocol.Ctx.request_permission/4` answers
  `{:selected, outcome}` only for a reply decoded from the client. A timeout,
  a client error, a disconnect, a `session/cancel`, a turn that ends first
  and a client that does not implement the method all arrive as
  `:cancelled`. Here a call is allowed only when the selected option is the
  allow option this module offered: the reject option, an option it never
  offered and `:cancelled` deny.

  The wait is bounded by the session's `:permission_timeout` alone.

  ## Tool call status

  A sensitive call is announced `pending` and becomes `in_progress` once
  allowed or `failed` once denied; any other call is announced
  `in_progress`. The authorizer sees a call start and never end. It tells
  the process that built it of each call before announcing it and again on
  allowing it, and that process closes the calls with `settle/3` when the
  turn ends:

    * an allowed call is `completed` when the agent answered the turn. When
      it did not (a cancel, a failure, the agent going down) the call is
      `failed` with a note that its outcome is unknown: the action may have
      run.
    * a call that was never allowed, such as one still waiting for
      permission, is `failed`. It did not run.

  A call whose process is killed between telling the turn and announcing is
  closed without having been announced.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Ctx,
              Raxol.AgentClientProtocol.Schema.ContentBlock,
              Raxol.AgentClientProtocol.Schema.ToolCall,
              Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdate,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields,
              Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption,
              Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
            ]}

  alias Raxol.Agent.ClientProtocol.RawInput
  alias Raxol.Agent.ToolPolicy

  @ctx Raxol.AgentClientProtocol.Ctx
  @content_block Raxol.AgentClientProtocol.Schema.ContentBlock
  @content_wrapper Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper
  @tool_call Raxol.AgentClientProtocol.Schema.ToolCall
  @tool_call_update Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  @tcu_fields Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  @option Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
  @notification Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  @allow_id "raxol-allow-once"
  @reject_id "raxol-reject-once"

  @outcome_unknown "Outcome unknown: the turn ended before this call reported back. " <>
                     "The action may have run."

  @typep call :: %{
           session: GenServer.server(),
           session_id: String.t(),
           turn: pid(),
           id: String.t(),
           name: String.t() | atom(),
           shown: %{title: String.t(), raw_input: term()}
         }

  @doc "The option id that means allow."
  @spec allow_option_id() :: String.t()
  def allow_option_id, do: @allow_id

  @doc "The option id that means reject."
  @spec reject_option_id() :: String.t()
  def reject_option_id, do: @reject_id

  @doc """
  Build the authorizer for one turn of `session` (the ACP session process).

  Call it in the process that ends the turn: that process is told of every
  call the authorizer takes, and closes them with `settle/3`. The authorizer
  itself runs wherever the agent dispatches the tool call.
  """
  @spec authorizer(GenServer.server(), String.t()) ::
          (module() | Raxol.Agent.Action.Dynamic.t(), map(), map() -> :ok | {:deny, term()})
  def authorizer(session, session_id) when is_binary(session_id) do
    turn = self()

    fn action, params, _context ->
      {name, sensitive?} = ToolPolicy.identity(action)

      decide(
        %{
          session: session,
          session_id: session_id,
          turn: turn,
          id: call_id(),
          name: name,
          shown: %{title: title(name), raw_input: RawInput.render(params)}
        },
        sensitive?
      )
    end
  end

  @doc """
  Close every tool call the calling process's authorizer took and that is
  still open (see "Tool call status"). `outcome` is `:answered` when the
  agent replied to the turn and `:unanswered` when the turn ended any other
  way.
  """
  @spec settle(GenServer.server(), String.t(), :answered | :unanswered) :: :ok
  def settle(session, session_id, outcome) when outcome in [:answered, :unanswered] do
    for {id, state} <- open_calls([]) do
      {status, note} = closing(state, outcome)
      update(%{session: session, session_id: session_id, id: id}, status, note)
    end

    :ok
  end

  # `[{id, :taken | :allowed}]` in the order the calls were taken, from what
  # the authorizer has sent this process.
  defp open_calls(calls) do
    receive do
      {:acp_tool_call, id, :closed} -> open_calls(List.keydelete(calls, id, 0))
      {:acp_tool_call, id, state} -> open_calls(List.keystore(calls, id, 0, {id, state}))
    after
      0 -> calls
    end
  end

  defp closing(:allowed, :answered), do: {:completed, nil}
  defp closing(:allowed, :unanswered), do: {:failed, @outcome_unknown}
  defp closing(:taken, _outcome), do: {:failed, nil}

  defp decide(call, false) do
    track(call, :taken)
    announce(call, :in_progress)
    allow(call)
  end

  defp decide(call, true) do
    track(call, :taken)
    announce(call, :pending)

    case ask(call) do
      :ok ->
        update(call, :in_progress)
        allow(call)

      {:deny, _reason} = denial ->
        update(call, :failed)
        track(call, :closed)
        denial
    end
  end

  # The last step before the action may run: a call the turn's process was
  # not told this of did not run.
  defp allow(call) do
    track(call, :allowed)
    :ok
  end

  defp track(call, state) do
    send(call.turn, {:acp_tool_call, call.id, state})
    :ok
  end

  # A fresh id per call: a client records the decision under it.
  defp call_id do
    "call-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  @spec ask(call()) :: :ok | {:deny, term()}
  defp ask(call) do
    request = @tool_call_update.new(call.id, fields(:pending, call.shown))

    call.session
    |> @ctx.request_permission(call.session_id, request, options())
    |> verdict(call.name)
  end

  defp verdict({:ok, {:selected, %{option_id: @allow_id}}}, _name), do: :ok

  defp verdict({:ok, {:selected, %{option_id: @reject_id}}}, name),
    do: {:deny, {:permission_rejected, name}}

  defp verdict({:ok, {:selected, %{option_id: other}}}, name),
    do: {:deny, {:permission_unknown_option, name, other}}

  defp verdict({:ok, :cancelled}, name), do: {:deny, {:permission_cancelled, name}}
  defp verdict(other, name), do: {:deny, {:permission_unexpected, name, other}}

  defp options do
    [
      @option.new(@allow_id, "Allow once", :allow_once),
      @option.new(@reject_id, "Reject", :reject_once)
    ]
  end

  # An update for a turn that is over is refused by the session; nothing
  # then needs telling.
  defp announce(call, status) do
    tool_call = @tool_call.new(call.id, call.shown.title)
    post(call, {:tool_call, @tool_call.update(tool_call, fields(status, call.shown))})
  end

  defp update(call, status, note \\ nil) do
    fields = fields(status, %{note: note})
    post(call, {:tool_call_update, @tool_call_update.new(call.id, fields)})
  end

  # What every frame about a call says of it. `shown` holds the `:title` and
  # `:raw_input` a client reads before deciding, or the `:note` it reads
  # after.
  defp fields(status, shown) do
    %{
      @tcu_fields.new()
      | status: status,
        title: shown[:title],
        raw_input: shown[:raw_input],
        content: note_content(shown[:note])
    }
  end

  defp note_content(nil), do: nil

  defp note_content(note),
    do: [{:content, @content_wrapper.new(@content_block.from_string(note))}]

  defp post(call, update) do
    _ = @ctx.post_update(call.session, @notification.new(call.session_id, update))
    :ok
  end

  defp title(name) when is_binary(name), do: "Run `#{name}`"
  defp title(name), do: "Run `#{inspect(name)}`"
end
