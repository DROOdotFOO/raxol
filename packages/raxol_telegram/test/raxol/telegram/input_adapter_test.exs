defmodule Raxol.Telegram.InputAdapterTest do
  use ExUnit.Case, async: true

  alias Raxol.Telegram.InputAdapter

  describe "translate_callback/1" do
    test "translates single char key" do
      event = InputAdapter.translate_callback("key:q")
      assert event.type == :key
      assert event.data.key == :char
      assert event.data.char == "q"
    end

    test "translates arrow keys" do
      for {name, expected} <- [{"up", :up}, {"down", :down}, {"left", :left}, {"right", :right}] do
        event = InputAdapter.translate_callback("key:#{name}")
        assert event.type == :key
        assert event.data.key == expected
      end
    end

    test "translates enter key" do
      event = InputAdapter.translate_callback("key:enter")
      assert event.type == :key
      assert event.data.key == :enter
    end

    test "translates tab key" do
      event = InputAdapter.translate_callback("key:tab")
      assert event.type == :key
      assert event.data.key == :tab
    end

    test "translates space as char event" do
      event = InputAdapter.translate_callback("key:space")
      assert event.type == :key
      assert event.data.key == :char
      assert event.data.char == " "
    end

    test "translates button callback" do
      event = InputAdapter.translate_callback("btn:submit")
      assert event.type == :click
      assert event.data.component_id == "submit"
    end

    test "returns nil for unknown callback" do
      assert InputAdapter.translate_callback("unknown:data") == nil
    end

    test "returns nil for multi-char non-special key" do
      assert InputAdapter.translate_callback("key:abc") == nil
    end
  end

  describe "translate_text/1" do
    test "single character becomes key event" do
      event = InputAdapter.translate_text("q")
      assert event.type == :key
      assert event.data.char == "q"
    end

    test "slash command returns command tuple" do
      assert InputAdapter.translate_text("/start") == {:command, "start"}
      assert InputAdapter.translate_text("/stop") == {:command, "stop"}
      assert InputAdapter.translate_text("/help") == {:command, "help"}
    end

    test "command with args extracts just the command name" do
      assert InputAdapter.translate_text("/start arg1 arg2") == {:command, "start"}
    end

    test "multi-char text becomes paste event" do
      event = InputAdapter.translate_text("hello world")
      assert event.type == :paste
      assert event.data.text == "hello world"
    end

    test "empty string returns nil" do
      assert InputAdapter.translate_text("") == nil
      assert InputAdapter.translate_text("   ") == nil
    end

    test "nil returns nil" do
      assert InputAdapter.translate_text(nil) == nil
    end
  end
end
