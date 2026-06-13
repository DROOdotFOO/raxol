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
      event =
        ActionHandler.handle_action("deploy",
          action_map: %{
            "deploy" => {:key, %{key: :char, char: "d"}}
          }
        )

      assert event.type == :key
      assert event.data.char == "d"
    end

    test "custom actions override defaults" do
      event =
        ActionHandler.handle_action("pause",
          action_map: %{
            "pause" => {:key, %{key: :escape}}
          }
        )

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

  describe "chat tap-back actions (W4)" do
    test "mute maps to a :custom event with action :mute" do
      event = ActionHandler.handle_action("mute")
      assert event.type == :custom
      assert event.data.action == :mute
    end

    test "pin maps to a :custom event with action :pin" do
      event = ActionHandler.handle_action("pin")
      assert event.type == :custom
      assert event.data.action == :pin
    end

    test "delete maps to a :custom event with action :delete" do
      event = ActionHandler.handle_action("delete")
      assert event.type == :custom
      assert event.data.action == :delete
    end

    test "dispatch routes custom events through the same channel as key events" do
      assert {:ok, event} = ActionHandler.dispatch("mute", to: self())
      assert_received {:watch_action, ^event}
      assert event.type == :custom
      assert event.data.action == :mute
    end

    test "the generalized dispatcher still routes legacy :key actions" do
      # Backward compatibility check: existing {:key, data} action_map values
      # still produce :key events.
      event = ActionHandler.handle_action("pause")
      assert event.type == :key
      assert event.data.char == " "
    end

    test "custom action with arbitrary type works via :action_map override" do
      event =
        ActionHandler.handle_action("deploy",
          action_map: %{"deploy" => {:custom, %{action: :deploy, env: "prod"}}}
        )

      assert event.type == :custom
      assert event.data == %{action: :deploy, env: "prod"}
    end
  end

  describe "handle_reply_action/3" do
    test "produces a :reply event carrying the action id and typed text" do
      event = ActionHandler.handle_reply_action("reply", "Hi there!")
      assert event.type == :reply
      assert event.data.action == "reply"
      assert event.data.text == "Hi there!"
    end

    test "accepts arbitrary action ids" do
      event = ActionHandler.handle_reply_action("quick_response_42", "ok")
      assert event.data.action == "quick_response_42"
    end

    test "requires text to be a binary" do
      assert_raise FunctionClauseError, fn ->
        ActionHandler.handle_reply_action("reply", nil)
      end
    end
  end

  describe "dispatch_reply/3" do
    setup do
      on_exit(fn -> Application.delete_env(:raxol_watch, :action_dispatcher) end)
      :ok
    end

    test "routes the reply event to a pid via the :watch_action channel" do
      assert {:ok, event} = ActionHandler.dispatch_reply("reply", "Hi", to: self())
      assert_received {:watch_action, ^event}
      assert event.type == :reply
      assert event.data.text == "Hi"
    end

    test "invokes a 1-arity function dispatcher" do
      test_pid = self()
      fun = fn ev -> send(test_pid, {:reply_via_fn, ev}) end

      assert {:ok, _event} = ActionHandler.dispatch_reply("reply", "Hi", to: fun)
      assert_received {:reply_via_fn, %{type: :reply, data: %{text: "Hi"}}}
    end

    test "falls back to app env action_dispatcher" do
      Application.put_env(:raxol_watch, :action_dispatcher, self())
      assert {:ok, _event} = ActionHandler.dispatch_reply("reply", "Hi")
      assert_received {:watch_action, %{type: :reply}}
    end

    test "returns no_dispatcher when nothing configured" do
      assert {:error, :no_dispatcher, %{type: :reply}} =
               ActionHandler.dispatch_reply("reply", "Hi")
    end
  end
end
