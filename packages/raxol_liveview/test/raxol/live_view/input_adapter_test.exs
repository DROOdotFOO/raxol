defmodule Raxol.LiveView.InputAdapterTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.LiveView.InputAdapter

  describe "translate_key_event/1" do
    test "translates regular character keys" do
      event =
        InputAdapter.translate_key_event(%{
          "key" => "a",
          "ctrlKey" => false,
          "altKey" => false,
          "shiftKey" => false
        })

      assert %Event{type: :key, data: %{key: :char, char: "a"}} = event
    end

    test "translates special keys" do
      event =
        InputAdapter.translate_key_event(%{
          "key" => "Enter",
          "ctrlKey" => false,
          "altKey" => false,
          "shiftKey" => false
        })

      assert %Event{type: :key, data: %{key: :enter, char: nil}} = event
    end

    test "translates arrow keys" do
      for {js_key, raxol_key} <- [
            {"ArrowUp", :up},
            {"ArrowDown", :down},
            {"ArrowLeft", :left},
            {"ArrowRight", :right}
          ] do
        event =
          InputAdapter.translate_key_event(%{
            "key" => js_key,
            "ctrlKey" => false,
            "altKey" => false,
            "shiftKey" => false
          })

        assert %Event{type: :key, data: %{key: ^raxol_key}} = event
      end
    end

    test "translates modifier keys" do
      event =
        InputAdapter.translate_key_event(%{
          "key" => "a",
          "ctrlKey" => true,
          "altKey" => false,
          "shiftKey" => true
        })

      assert %Event{
               type: :key,
               data: %{key: :char, char: "a", ctrl: true, shift: true, alt: false}
             } = event
    end

    test "ignores modifier-only presses" do
      event =
        InputAdapter.translate_key_event(%{
          "key" => "Control",
          "ctrlKey" => true,
          "altKey" => false,
          "shiftKey" => false
        })

      assert %Event{type: :key, data: %{key: :modifier}} = event
    end

    test "translates function keys" do
      for n <- 1..12 do
        event =
          InputAdapter.translate_key_event(%{
            "key" => "F#{n}",
            "ctrlKey" => false,
            "altKey" => false,
            "shiftKey" => false
          })

        expected_key = String.to_atom("f#{n}")
        assert %Event{type: :key, data: %{key: ^expected_key}} = event
      end
    end

    test "translates navigation keys" do
      for {js_key, raxol_key} <- [
            {"Home", :home},
            {"End", :end},
            {"PageUp", :page_up},
            {"PageDown", :page_down},
            {"Delete", :delete},
            {"Insert", :insert},
            {"Escape", :escape},
            {"Backspace", :backspace},
            {"Tab", :tab}
          ] do
        event =
          InputAdapter.translate_key_event(%{
            "key" => js_key,
            "ctrlKey" => false,
            "altKey" => false,
            "shiftKey" => false
          })

        assert %Event{type: :key, data: %{key: ^raxol_key}} = event
      end
    end
  end

  describe "translate_click_event/1" do
    test "translates cell coordinates into a mouse press the dispatcher hit-tests" do
      event = InputAdapter.translate_click_event(%{"x" => 5, "y" => 12})

      assert %Event{
               type: :mouse,
               data: %{action: :press, button: :left, x: 5, y: 12}
             } = event
    end

    test "origin cell is valid" do
      assert %Event{data: %{x: 0, y: 0}} =
               InputAdapter.translate_click_event(%{"x" => 0, "y" => 0})
    end

    test "malformed coordinates are refused, not raised" do
      # The params arrive from a browser client; anything the hook did not
      # produce is answered with nil rather than crashing the LiveView.
      for params <- [
            %{"x" => -1, "y" => 0},
            %{"x" => 0, "y" => -3},
            %{"x" => 1.5, "y" => 2},
            %{"x" => "5", "y" => "5"},
            %{"y" => 5},
            %{}
          ] do
        assert InputAdapter.translate_click_event(params) == nil
      end
    end
  end
end
