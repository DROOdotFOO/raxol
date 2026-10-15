defmodule Raxol.Core.Runtime.Events.KeyboardTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Events.Keyboard

  defp make_key_event(key, modifiers \\ [ctrl: false, alt: false, shift: false]) do
    Event.new(:key, %{key: key, modifiers: modifiers})
  end

  defp make_state(opts \\ []) do
    %{
      quit_keys: Keyword.get(opts, :quit_keys, []),
      debug_mode: Keyword.get(opts, :debug_mode, false)
    }
  end

  describe "process_keyboard_event/2" do
    test "returns :application for normal key with no quit keys" do
      event = make_key_event(?a)
      state = make_state()

      assert {:application, ^event, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "returns :system :quit when key matches quit_keys atom" do
      event = make_key_event(?q)
      state = make_state(quit_keys: [?q])

      assert {:system, :quit, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "returns :system :quit for ctrl_c quit key" do
      event = make_key_event(?c, ctrl: true, alt: false, shift: false)
      state = make_state(quit_keys: [:ctrl_c])

      assert {:system, :quit, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "returns :system :quit for ctrl_q quit key" do
      event = make_key_event(?q, ctrl: true, alt: false, shift: false)
      state = make_state(quit_keys: [:ctrl_q])

      assert {:system, :quit, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "returns :system :quit for tuple quit key with modifiers" do
      event = make_key_event(?x, ctrl: true, alt: false, shift: false)
      state = make_state(quit_keys: [{?x, [:ctrl]}])

      assert {:system, :quit, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "does not quit when modifiers don't match" do
      event = make_key_event(?x, ctrl: false, alt: false, shift: false)
      state = make_state(quit_keys: [{?x, [:ctrl]}])

      assert {:application, ^event, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end

    test "ctrl+d toggles debug mode on" do
      event = make_key_event(?d, ctrl: true, alt: false, shift: false)
      state = make_state(debug_mode: false)

      assert {:system, {:set_debug_mode, true}, new_state} =
               Keyboard.process_keyboard_event(event, state)

      assert new_state.debug_mode == true
    end

    test "ctrl+d toggles debug mode off" do
      event = make_key_event(?d, ctrl: true, alt: false, shift: false)
      state = make_state(debug_mode: true)

      assert {:system, {:set_debug_mode, false}, new_state} =
               Keyboard.process_keyboard_event(event, state)

      assert new_state.debug_mode == false
    end

    test "quit takes priority over debug toggle" do
      event = make_key_event(?d, ctrl: true, alt: false, shift: false)
      state = make_state(quit_keys: [:ctrl_c, {?d, [:ctrl]}])

      assert {:system, :quit, ^state} =
               Keyboard.process_keyboard_event(event, state)
    end
  end

  describe "convert_to_message/1" do
    test "converts printable character to key_press message" do
      event = make_key_event(?a)

      assert {:key_press, "a"} = Keyboard.convert_to_message(event)
    end

    test "converts special key code to named key" do
      event = make_key_event(13)

      assert {:key_press, :enter} = Keyboard.convert_to_message(event)
    end

    test "converts escape key" do
      event = make_key_event(27)

      assert {:key_press, :escape} = Keyboard.convert_to_message(event)
    end

    test "converts tab key" do
      event = make_key_event(9)

      assert {:key_press, :tab} = Keyboard.convert_to_message(event)
    end

    test "converts space key" do
      event = make_key_event(32)

      assert {:key_press, " "} = Keyboard.convert_to_message(event)
    end

    test "converts backspace key" do
      event = make_key_event(127)

      assert {:key_press, :backspace} = Keyboard.convert_to_message(event)
    end

    test "converts atom key directly" do
      event = make_key_event(:arrow_up)

      assert {:key_press, :arrow_up} = Keyboard.convert_to_message(event)
    end

    test "includes modifiers when active" do
      event = make_key_event(?a, ctrl: true, alt: false, shift: true)

      assert {:key_press, "a", mods} = Keyboard.convert_to_message(event)
      assert :ctrl in mods
      assert :shift in mods
      refute :alt in mods
    end

    test "no modifier list when all modifiers inactive" do
      event = make_key_event(?z, ctrl: false, alt: false, shift: false)

      assert {:key_press, "z"} = Keyboard.convert_to_message(event)
    end
  end

  describe "check_shortcuts/2" do
    test "returns :none when no shortcuts match" do
      event = make_key_event(?a)
      shortcuts = %{save: ?s, quit: ?q}

      assert :none = Keyboard.check_shortcuts(event, shortcuts)
    end

    test "matches simple key shortcut" do
      event = make_key_event(?s, ctrl: false, alt: false, shift: false)
      shortcuts = %{save: ?s}

      assert {:ok, :save} = Keyboard.check_shortcuts(event, shortcuts)
    end

    test "matches key+modifier shortcut" do
      event = make_key_event(?s, ctrl: true, alt: false, shift: false)
      shortcuts = %{save: {?s, [:ctrl]}}

      assert {:ok, :save} = Keyboard.check_shortcuts(event, shortcuts)
    end

    test "does not match when modifier missing" do
      event = make_key_event(?s, ctrl: false, alt: false, shift: false)
      shortcuts = %{save: {?s, [:ctrl]}}

      assert :none = Keyboard.check_shortcuts(event, shortcuts)
    end

    test "matches atom key shortcut" do
      event = make_key_event(:escape, ctrl: false, alt: false, shift: false)
      shortcuts = %{cancel: :escape}

      assert {:ok, :cancel} = Keyboard.check_shortcuts(event, shortcuts)
    end
  end
end
