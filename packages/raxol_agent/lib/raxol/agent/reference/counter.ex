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
  the turn's `:tool_authorizer`. `increment` and `reset` run in the agent
  process; `hold` runs in the turn process `Raxol.Agent.Comm.run_turn/3`
  starts, so a cancel kills it. Usage is always zero: no model is called.
  """

  use Raxol.Agent

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Comm

  defmodule Increment do
    @moduledoc "Add one to the count."
    use Raxol.Agent.Action, name: "increment", description: "Add one to the count"

    @impl true
    def run(_params, %{count: count}), do: {:ok, %{count: count + 1}}
  end

  defmodule Reset do
    @moduledoc "Set the count to zero."
    use Raxol.Agent.Action,
      name: "reset",
      description: "Set the count to zero",
      sensitive: true

    @impl true
    def run(_params, _context), do: {:ok, %{count: 0}}
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

  def init(_context), do: %{count: 0, holds: MapSet.new()}

  def available_actions, do: @actions

  def update({:agent_message, _from, {:call, caller, ref, {:acp_prompt, text, approver}}}, model),
    do: prompt(String.trim(text), caller, ref, approver, model)

  def update({:agent_message, _from, {:acp_cancel, ref}}, model),
    do: {%{model | holds: MapSet.delete(model.holds, ref)}, []}

  def update(_msg, model), do: {model, []}

  defp prompt(command, caller, ref, approver, model) when command in ["increment", "reset"] do
    case dispatch(command, approver, %{count: model.count}) do
      {:ok, %{count: count}} ->
        Comm.reply(caller, ref, {:ok, "count: #{count}", @usage})
        {%{model | count: count}, []}

      {:error, reason} ->
        Comm.reply(caller, ref, {:ok, ToolConverter.public_error(command, reason), @usage})
        {model, []}
    end
  end

  defp prompt("get", caller, ref, _approver, model) do
    Comm.reply(caller, ref, {:ok, "count: #{model.count}", @usage})
    {model, []}
  end

  defp prompt("hold", caller, ref, approver, model) do
    Comm.run_turn(caller, ref, fn ->
      case dispatch("hold", approver, %{}) do
        {:ok, _released} -> {:ok, "released", @usage}
        {:error, reason} -> {:ok, ToolConverter.public_error("hold", reason), @usage}
      end
    end)

    {%{model | holds: MapSet.put(model.holds, ref)}, []}
  end

  defp prompt("release", caller, ref, _approver, model) do
    Enum.each(model.holds, &Comm.send_turn(caller, &1, :release))
    Comm.reply(caller, ref, {:ok, "released #{MapSet.size(model.holds)}", @usage})
    {%{model | holds: MapSet.new()}, []}
  end

  defp prompt(_unknown, caller, ref, _approver, model) do
    Comm.reply(caller, ref, {:ok, @help, @usage})
    {model, []}
  end

  defp dispatch(name, approver, context) do
    ToolConverter.dispatch_tool_call(
      %{"name" => name, "arguments" => %{}},
      @actions,
      Map.put(context, :tool_authorizer, approver)
    )
  end
end
