defmodule Raxol.Agent.ClientProtocol.Permission do
  @moduledoc """
  The tool authorizer of an ACP turn: the `approver` an agent receives with
  `{:acp_prompt, text, approver}` (see `Raxol.Agent.Comm`).

  Every tool call the agent runs past it is announced to the client as a
  `tool_call` update. A call to an action marked `sensitive` then waits on
  one `session/request_permission`, offering allow-once and reject-once; any
  other action is allowed without a round trip.

  ## Denials

  `Raxol.AgentClientProtocol.Ctx.request_permission/4` answers
  `{:selected, outcome}` only for a reply decoded from the client. A timeout,
  a client error, a disconnect, a `session/cancel` and a client that does not
  implement the method all arrive as `:cancelled`. Here a call is allowed
  only when the selected option is the allow option this module offered:
  the reject option, an option it never offered and `:cancelled` deny.

  The wait is bounded by the session's `:permission_timeout` alone.

  ## Tool call status

  A sensitive call is announced `pending` and becomes `in_progress` once
  allowed or `failed` once denied; any other call is announced
  `in_progress`. The authorizer sees a call start and never end, so the
  process that built it closes the allowed calls with `settle/3` when the
  turn ends.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Ctx,
              Raxol.AgentClientProtocol.Schema.ToolCall,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdate,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields,
              Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption,
              Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
            ]}

  alias Raxol.Agent.ToolPolicy

  @ctx Raxol.AgentClientProtocol.Ctx
  @tool_call Raxol.AgentClientProtocol.Schema.ToolCall
  @tool_call_update Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  @tcu_fields Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  @option Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
  @notification Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  @allow_id "raxol-allow-once"
  @reject_id "raxol-reject-once"

  @typep call :: %{
           session: GenServer.server(),
           session_id: String.t(),
           id: String.t(),
           name: String.t() | atom()
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
  call the authorizer allows, and closes them with `settle/3`. The
  authorizer itself runs wherever the agent dispatches the tool call.
  """
  @spec authorizer(GenServer.server(), String.t()) ::
          (module() | Raxol.Agent.Action.Dynamic.t(), map(), map() -> :ok | {:deny, term()})
  def authorizer(session, session_id) when is_binary(session_id) do
    turn = self()

    fn action, _params, _context ->
      {name, sensitive?} = ToolPolicy.identity(action)
      call = %{session: session, session_id: session_id, id: call_id(), name: name}
      decide(call, sensitive?, turn)
    end
  end

  @doc """
  Close every tool call the calling process's authorizer allowed and that is
  still open, with `status` (`:completed` or `:failed`).
  """
  @spec settle(GenServer.server(), String.t(), :completed | :failed) :: :ok
  def settle(session, session_id, status) when status in [:completed, :failed] do
    receive do
      {:acp_tool_call, id} ->
        update(%{session: session, session_id: session_id, id: id}, status)
        settle(session, session_id, status)
    after
      0 -> :ok
    end
  end

  defp decide(call, false, turn) do
    announce(call, :in_progress)
    send(turn, {:acp_tool_call, call.id})
    :ok
  end

  defp decide(call, true, turn) do
    announce(call, :pending)

    case ask(call) do
      :ok ->
        update(call, :in_progress)
        send(turn, {:acp_tool_call, call.id})
        :ok

      {:deny, _reason} = denial ->
        update(call, :failed)
        denial
    end
  end

  # A fresh id per call: a client records the decision under it.
  defp call_id do
    "call-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  @spec ask(call()) :: :ok | {:deny, term()}
  defp ask(call) do
    request = @tool_call_update.new(call.id, %{@tcu_fields.new() | title: title(call.name)})

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
    tool_call = %{@tool_call.new(call.id, title(call.name)) | status: status}
    post(call, {:tool_call, tool_call})
  end

  defp update(call, status) do
    fields = %{@tcu_fields.new() | status: status}
    post(call, {:tool_call_update, @tool_call_update.new(call.id, fields)})
  end

  defp post(call, update) do
    _ = @ctx.post_update(call.session, @notification.new(call.session_id, update))
    :ok
  end

  defp title(name) when is_binary(name), do: "Run `#{name}`"
  defp title(name), do: "Run `#{inspect(name)}`"
end
