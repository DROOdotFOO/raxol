defmodule Raxol.MCP.AgentBridgeSendTest do
  @moduledoc """
  `agent.send` through a real `Raxol.Headless` session. The MCP server runs
  tool callbacks in its own process, shared by every client, so a callback
  that waited for the app's `update/2` once per keystroke held every client
  for as long as the app took.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.MCP.AgentBridge

  # On "b", update/2 tells the process the model names that it is running and
  # holds the dispatcher until that process sends `:release`.
  defmodule BlockingApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{notify: nil, handled: 0}

    @impl true
    def update({:notify, pid}, model), do: {%{model | notify: pid}, []}

    def update(%Raxol.Core.Events.Event{type: :key, data: %{char: "b"}}, model) do
      send(model.notify, {:in_update, self()})

      receive do
        :release -> {%{model | handled: model.handled + 1}, []}
      end
    end

    def update(_message, model), do: {model, []}

    @impl true
    def view(model),
      do: Raxol.Core.Renderer.View.text("Handled: #{model.handled}")

    @impl true
    def subscriptions(_model), do: []
  end

  setup do
    if is_nil(Process.whereis(Headless)),
      do: start_supervised!({Headless, [name: Headless]})

    {:ok, id} = Headless.start(BlockingApp, id: :bridge_blocked)
    on_exit(fn -> if Process.whereis(Headless), do: Headless.stop(id) end)
    %{id: id}
  end

  # The callback returns while the first key's update/2 is still held, which
  # only this test can end: had it waited for update/2, it could not return.
  test "agent.send enqueues every keystroke without waiting for update/2", %{
    id: id
  } do
    :ok = Headless.send_message(id, {:notify, self()})
    agent_send = Enum.find(AgentBridge.meta_tools(), &(&1.name == "agent.send"))

    assert {:ok, [%{text: text}]} =
             agent_send.callback.(%{
               "id" => Atom.to_string(id),
               "message" => "bb"
             })

    assert text =~ "Enqueued 2 keystrokes"

    for _ <- 1..2 do
      assert_receive {:in_update, dispatcher}
      send(dispatcher, :release)
    end

    assert {:ok, %{handled: 2}} = Headless.get_model(id)
  end
end
