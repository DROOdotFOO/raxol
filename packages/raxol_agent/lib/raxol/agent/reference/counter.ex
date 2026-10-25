defmodule Raxol.Agent.Reference.Counter do
  @moduledoc """
  Reference agent for the agent turn contract (see `Raxol.Agent.Comm`).

  Answers `{:acp_prompt, text, approver}` with `{:ok, text, usage}`. The
  prompt text is one command:

    * `increment` - add one, reply with the count
    * `get` - reply with the count
    * `reset` - set the count to zero; a sensitive action, so `approver`
      must allow it
    * `hold` - block until a `release` prompt or `{:acp_cancel, ref}`
    * `release` - release every held turn

  Actions run through `Raxol.Agent.Action.ToolConverter` with `approver` as
  the turn's `:tool_authorizer`, in the turn process
  `Raxol.Agent.Comm.run_turn/3` starts, never in the agent process: a
  blocked approver holds up only its turn, and a cancel kills it. `increment`
  and `reset` return a change that the turn process sends back to `update/2`,
  which applies it and hands the new count to the turn for its reply, so a
  turn cancelled before its change is sent changes nothing. `update/2`
  applies a change only for a turn it still tracks: it forgets a turn once
  the change is applied, the approver denies it, or `{:acp_cancel, ref}`
  arrives (the turn was cancelled or failed), so no other process can change
  the count. Usage is always zero: no model is called.
  """

  use Raxol.Agent

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Comm

  defmodule Increment do
    @moduledoc "Add one to the count (returns the change for the agent to apply)."
    use Raxol.Agent.Action, name: "increment", description: "Add one to the count"

    @impl true
    def run(_params, _context), do: {:ok, %{add: 1}}
  end

  defmodule Reset do
    @moduledoc "Set the count to zero (returns the change for the agent to apply)."
    use Raxol.Agent.Action,
      name: "reset",
      description: "Set the count to zero",
      sensitive: true

    @impl true
    def run(_params, _context), do: {:ok, %{set: 0}}
  end

  defmodule Hold do
    @moduledoc "Block until the running process receives `:release`."
    use Raxol.Agent.Action, name: "hold", description: "Block until released"

    @impl true
    def run(_params, _context) do
      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  @actions [Increment, Reset, Hold]
  @usage %{input_tokens: 0, output_tokens: 0}
  @help "commands: increment, get, reset, hold, release"

  def init(_context), do: %{count: 0, holds: MapSet.new(), changes: %{}}

  def available_actions, do: @actions

  def update(
        {:agent_message, _from, {:call, session, ref, {:acp_prompt, text, approver}}},
        model
      ),
      do: prompt(String.trim(text), session, ref, approver, model)

  def update({:agent_message, _from, {:acp_cancel, ref}}, model) do
    model = %{model | holds: MapSet.delete(model.holds, ref)}
    {%{model | changes: Map.delete(model.changes, ref)}, []}
  end

  # An approved change from a live turn: apply it, then let the turn reply.
  def update({:command_result, {:counter_change, ref, change}}, %{changes: changes} = model)
      when is_map_key(changes, ref) do
    {session, changes} = Map.pop(changes, ref)
    count = apply_change(change, model.count)
    Comm.send_turn(session, ref, {:count, count})
    {%{model | count: count, changes: changes}, []}
  end

  def update({:command_result, {:counter_denied, ref}}, model),
    do: {%{model | changes: Map.delete(model.changes, ref)}, []}

  def update(_msg, model), do: {model, []}

  defp prompt(command, session, ref, approver, model) when command in ["increment", "reset"] do
    agent = self()
    Comm.run_turn(session, ref, fn -> change_turn(agent, ref, command, approver) end)
    {%{model | changes: Map.put(model.changes, ref, session)}, []}
  end

  defp prompt("get", session, ref, _approver, model) do
    Comm.reply(session, ref, {:ok, "count: #{model.count}", @usage})
    {model, []}
  end

  defp prompt("hold", session, ref, approver, model) do
    Comm.run_turn(session, ref, fn ->
      case dispatch("hold", approver) do
        {:ok, _released} -> {:ok, "released", @usage}
        {:error, reason} -> {:ok, ToolConverter.public_error("hold", reason), @usage}
      end
    end)

    {%{model | holds: MapSet.put(model.holds, ref)}, []}
  end

  defp prompt("release", session, ref, _approver, model) do
    Enum.each(model.holds, &Comm.send_turn(session, &1, :release))
    Comm.reply(session, ref, {:ok, "released #{MapSet.size(model.holds)}", @usage})
    {%{model | holds: MapSet.new()}, []}
  end

  defp prompt(_unknown, session, ref, _approver, model) do
    Comm.reply(session, ref, {:ok, @help, @usage})
    {model, []}
  end

  # Runs in the turn process: the approver is asked here, and only an approved
  # change is sent to the agent (`agent`, the process running `update/2`). The
  # turn watches the agent, so it ends if the agent dies before replying.
  defp change_turn(agent, ref, command, approver) do
    case dispatch(command, approver) do
      {:ok, change} ->
        agent_mref = Process.monitor(agent)
        send(agent, {:command_result, {:counter_change, ref, change}})

        receive do
          {:count, count} ->
            Process.demonitor(agent_mref, [:flush])
            {:ok, "count: #{count}", @usage}

          {:DOWN, ^agent_mref, :process, ^agent, _reason} ->
            {:error, :agent_down}
        end

      {:error, reason} ->
        send(agent, {:command_result, {:counter_denied, ref}})
        {:ok, ToolConverter.public_error(command, reason), @usage}
    end
  end

  defp apply_change(%{add: n}, count), do: count + n
  defp apply_change(%{set: n}, _count), do: n

  defp dispatch(name, approver) do
    ToolConverter.dispatch_tool_call(
      %{"name" => name, "arguments" => %{}},
      @actions,
      %{tool_authorizer: approver}
    )
  end
end
