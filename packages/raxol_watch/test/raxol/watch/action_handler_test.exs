defmodule Raxol.Watch.ActionHandlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Watch.ActionHandler

  describe "handle_action/1" do
    test "maps 'pause' to space key" do
      event = ActionHandler.handle_action("pause")
      assert event.type == :key
      assert event.data.char == " "
    end

    test "maps 'details' to enter key" do
      event = ActionHandler.handle_action("details")
      assert event.type == :key
      assert event.data.key == :enter
    end

    test "maps 'quit' to q key" do
      event = ActionHandler.handle_action("quit")
      assert event.type == :key
      assert event.data.char == "q"
    end

    test "maps 'next' to tab key" do
      event = ActionHandler.handle_action("next")
      assert event.type == :key
      assert event.data.key == :tab
    end

    test "returns nil for 'dismiss'" do
      assert ActionHandler.handle_action("dismiss") == nil
    end

    test "returns nil for unknown actions" do
      assert ActionHandler.handle_action("unknown_action") == nil
    end
  end

  describe "handle_action/2 with custom map" do
    test "merges custom actions with defaults" do
      event = ActionHandler.handle_action("deploy", action_map: %{
        "deploy" => {:key, %{key: :char, char: "d"}}
      })
      assert event.type == :key
      assert event.data.char == "d"
    end

    test "custom actions override defaults" do
      event = ActionHandler.handle_action("pause", action_map: %{
        "pause" => {:key, %{key: :escape}}
      })
      assert event.type == :key
      assert event.data.key == :escape
    end
  end

  describe "default_action_map/0" do
    test "returns a map" do
      map = ActionHandler.default_action_map()
      assert is_map(map)
      assert map_size(map) > 0
    end
  end

  describe "dispatch/2" do
    setup do
      on_exit(fn -> Application.delete_env(:raxol_watch, :action_dispatcher) end)
      :ok
    end

    test "returns {:ok, nil} for dismiss" do
      assert ActionHandler.dispatch("dismiss") == {:ok, nil}
    end

    test "returns {:ok, nil} for unknown action" do
      assert ActionHandler.dispatch("unknown_xyz") == {:ok, nil}
    end

    test "sends {:watch_action, event} to a pid dispatcher" do
      assert {:ok, event} = ActionHandler.dispatch("details", to: self())
      assert_received {:watch_action, ^event}
      assert event.type == :key
      assert event.data.key == :enter
    end

    test "sends to a registered process by atom name" do
      name = :"action_handler_test_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      assert {:ok, _event} = ActionHandler.dispatch("next", to: name)
      assert_received {:watch_action, %{type: :key, data: %{key: :tab}}}
    end

    test "returns error for an unregistered atom name" do
      assert {:error, {:no_process, :nope_not_registered}, _event} =
               ActionHandler.dispatch("next", to: :nope_not_registered)
    end

    test "invokes a 1-arity function dispatcher" do
      test_pid = self()
      fun = fn ev -> send(test_pid, {:got, ev}) end
      assert {:ok, _event} = ActionHandler.dispatch("pause", to: fun)
      assert_received {:got, %{type: :key, data: %{char: " "}}}
    end

    test "invokes a {mod, fun, extra} dispatcher with the event prepended" do
      test_pid = self()

      defmodule MFArelay do
        def take(event, pid, tag), do: send(pid, {tag, event})
      end

      assert {:ok, _event} =
               ActionHandler.dispatch("quit",
                 to: {MFArelay, :take, [test_pid, :mfa]}
               )

      assert_received {:mfa, %{type: :key, data: %{char: "q"}}}
    end

    test "falls back to Application env when :to not given" do
      Application.put_env(:raxol_watch, :action_dispatcher, self())
      assert {:ok, _event} = ActionHandler.dispatch("details")
      assert_received {:watch_action, %{type: :key, data: %{key: :enter}}}
    end

    test "returns no_dispatcher when nothing configured" do
      assert {:error, :no_dispatcher, %{type: :key}} =
               ActionHandler.dispatch("details")
    end

    test "captures raised exceptions from function dispatcher" do
      assert {:error, {:dispatch_raised, %RuntimeError{}}, %{type: :key}} =
               ActionHandler.dispatch("details", to: fn _ -> raise "boom" end)
    end
  end
end
