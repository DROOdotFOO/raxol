defmodule Raxol.Agent.ClientProtocol.Permission do
  @moduledoc """
  Bridge the LLM tool-call path to ACP's `session/request_permission`.

  This is what lets the ACP surface carry the MUTATING toolset. Before this
  existed, `Raxol.Agent.ClientProtocol.Serve` handed the agent read/grep/glob
  only, because an unattended surface with no approval channel has to fail
  closed -- so an editor could ask raxol to read code but never to change it,
  and a benchmark harness scored zero on every task by construction.

  The gate is `Raxol.Agent.ToolPolicy`'s `:tool_authorizer` seam, the same one
  the TUI uses to defer to its human. Where the TUI messages its app process
  and waits, this asks the ACP CLIENT and waits: one `session/request_permission`
  per sensitive call, offering allow-once and reject-once. Non-sensitive calls
  (`read_file`, `list_dir`, `file_stat`, `grep`, `glob`) are allowed without a
  round-trip, so a read-heavy turn costs no protocol traffic.

  ## Fail-closed, inherited not reimplemented

  `Raxol.AgentClientProtocol.Ctx.request_permission/4` already guarantees that
  the only allow is a literal `{:selected, outcome}` decoded from the client's
  reply; timeout, client error, decode failure, disconnect and a `session/cancel`
  racing the ask all resolve `{:ok, :cancelled}`. This module adds one more
  narrowing on top: a `:selected` naming an option we did not offer, or naming
  our reject option, is a DENY. So a client that echoes back a wrong or
  attacker-chosen `optionId` cannot talk its way into a write.

  ACP has no permission capability to negotiate -- `session/request_permission`
  is a core client method (`capability: nil` in the method table), so a client
  that does not implement it answers method-not-found, which `Ctx` folds to
  `:cancelled`. Such a client keeps working: reads succeed, writes are denied.
  That is why the toolset no longer needs to be narrowed up front.

  The wait is bounded by the Session's `:permission_timeout` (default 600s),
  which is the single timeout authority; this module arms no timer of its own.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Ctx,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdate,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields,
              Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
            ]}

  alias Raxol.Agent.ToolPolicy

  @ctx Raxol.AgentClientProtocol.Ctx
  @tool_call_update Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  @tcu_fields Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  @option Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption

  @allow_id "raxol-allow-once"
  @reject_id "raxol-reject-once"

  @doc "The option id that means allow. Public so a test can assert on the exact wire value."
  @spec allow_option_id() :: String.t()
  def allow_option_id, do: @allow_id

  @doc "The option id that means reject."
  @spec reject_option_id() :: String.t()
  def reject_option_id, do: @reject_id

  @doc """
  Build a `:tool_authorizer` that asks `session`'s ACP client per sensitive call.

  Goes in the agent context (`context: %{tool_authorizer: ...}`), which
  `Raxol.Agent.Action.ToolConverter.dispatch_tool_call/3` consults before
  invoking any Action. Runs inside the turn task, so blocking here blocks that
  turn and nothing else -- the Session is a separate process, so the call cannot
  deadlock against it.
  """
  @spec authorizer(GenServer.server(), String.t()) ::
          (module() | Raxol.Agent.Action.Dynamic.t(), map(), map() -> :ok | {:deny, term()})
  def authorizer(session, session_id) when is_binary(session_id) do
    fn action, _params, _context ->
      case ToolPolicy.identity(action) do
        {_name, false} -> :ok
        {name, true} -> ask(session, session_id, name)
      end
    end
  end

  # One ask per sensitive call. `tool_call_id` is per-ask rather than the
  # model's tool-use id: the client uses it to correlate the prompt with the
  # `tool_call` update it already saw, and a retried call must not reuse an id
  # whose decision is already recorded.
  defp ask(session, session_id, name) do
    tool_call =
      @tool_call_update.new(
        "perm-" <> Integer.to_string(System.unique_integer([:positive])),
        %{@tcu_fields.new() | title: title(name), status: :pending}
      )

    session
    |> @ctx.request_permission(session_id, tool_call, options())
    |> decide(name)
  end

  defp decide({:ok, {:selected, %{option_id: @allow_id}}}, _name), do: :ok

  # A selected outcome naming our reject option, or naming anything we never
  # offered, is a deny -- not an allow with a shrug. The reason distinguishes
  # them so a confused client is debuggable.
  defp decide({:ok, {:selected, %{option_id: @reject_id}}}, name),
    do: {:deny, {:permission_rejected, name}}

  defp decide({:ok, {:selected, %{option_id: other}}}, name),
    do: {:deny, {:permission_unknown_option, name, other}}

  # Every non-allow terminal Ctx defines: timeout, client error, decode
  # failure, disconnect, a cancel racing the ask.
  defp decide({:ok, :cancelled}, name), do: {:deny, {:permission_cancelled, name}}

  # Ctx's spec admits no other shape; treat a surprise as a deny rather than
  # letting an unmatched clause crash the turn into an opaque failure.
  defp decide(other, name), do: {:deny, {:permission_unexpected, name, other}}

  defp options do
    [
      @option.new(@allow_id, "Allow once", :allow_once),
      @option.new(@reject_id, "Reject", :reject_once)
    ]
  end

  defp title(name) when is_binary(name), do: "Run `#{name}`"
  defp title(name), do: "Run `#{inspect(name)}`"
end
