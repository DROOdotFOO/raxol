defmodule Raxol.Playground.AppTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.App

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp special_key(key, extra \\ %{}) do
    %Raxol.Core.Events.Event{type: :key, data: Map.merge(%{key: key}, extra)}
  end

  describe "init/1" do
    test "initializes with components and first selected" do
      model = App.init(nil)
      # 42 = 40 baseline + the 2 harness TEA block demos (message + reasoning).
      assert length(model.components) == 42
      assert model.cursor == 0
      assert model.selected != nil
      assert model.focus == :sidebar
      assert model.demo_model != nil
    end

    test "initializes with filter state" do
      model = App.init(nil)
      assert model.category_filter == nil
      assert model.complexity_filter == nil
      assert model.show_help == false
    end
  end

  describe "sidebar navigation" do
    test "j moves cursor down" do
      model = App.init(nil)
      {model, []} = App.update(key_event("j"), model)
      assert model.cursor == 1
    end

    test "k moves cursor up" do
      model = App.init(nil)
      {model, []} = App.update(key_event("j"), model)
      {model, []} = App.update(key_event("k"), model)
      assert model.cursor == 0
    end

    test "cursor clamps to bounds" do
      model = App.init(nil)
      {model, []} = App.update(key_event("k"), model)
      assert model.cursor == 0
    end

    test "arrow keys also navigate" do
      model = App.init(nil)
      {model, []} = App.update(special_key(:down), model)
      assert model.cursor == 1
      {model, []} = App.update(special_key(:up), model)
      assert model.cursor == 0
    end
  end

  describe "component selection" do
    test "enter selects component but keeps sidebar focus" do
      model = App.init(nil)
      {model, []} = App.update(key_event("j"), model)
      {model, []} = App.update(special_key(:enter), model)
      assert model.selected.name == Enum.at(model.components, 1).name
      assert model.focus == :sidebar
      assert model.demo_model != nil
    end

    test "can browse multiple demos without losing sidebar focus" do
      model = App.init(nil)
      first_comp = model.selected

      {model, []} = App.update(key_event("j"), model)
      {model, []} = App.update(special_key(:enter), model)
      assert model.focus == :sidebar
      assert model.selected != first_comp

      {model, []} = App.update(key_event("j"), model)
      {model, []} = App.update(special_key(:enter), model)
      assert model.focus == :sidebar
    end
  end

  describe "focus cycling" do
    test "tab cycles between sidebar and demo" do
      model = App.init(nil)
      assert model.focus == :sidebar
      {model, []} = App.update(special_key(:tab), model)
      assert model.focus == :demo
      {model, []} = App.update(special_key(:tab), model)
      assert model.focus == :sidebar
    end
  end

  describe "search" do
    test "/ enters search mode" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      assert model.focus == :search
      assert model.search == ""
    end

    test "typing in search filters components" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(key_event("b"), model)
      {model, []} = App.update(key_event("u"), model)
      {model, []} = App.update(key_event("t"), model)
      assert model.search == "but"
      assert model.components != []
      assert Enum.any?(model.components, &(&1.name == "Button"))
    end

    test "escape exits search" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(special_key(:escape), model)
      assert model.focus == :sidebar
    end

    test "backspace in search removes character" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(key_event("a"), model)
      {model, []} = App.update(key_event("b"), model)
      assert model.search == "ab"
      {model, []} = App.update(special_key(:backspace), model)
      assert model.search == "a"
    end

    test "search respects active category filter" do
      model = App.init(nil)
      # Set category to :input
      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == :input
      # Enter search and search for "check"
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(key_event("c"), model)
      {model, []} = App.update(key_event("h"), model)
      {model, []} = App.update(key_event("e"), model)
      {model, []} = App.update(key_event("c"), model)
      {model, []} = App.update(key_event("k"), model)
      assert Enum.all?(model.components, &(&1.category == :input))
    end
  end

  describe "code panel" do
    test "c toggles code panel" do
      model = App.init(nil)
      assert model.show_code == false
      {model, []} = App.update(key_event("c"), model)
      assert model.show_code == true
      {model, []} = App.update(key_event("c"), model)
      assert model.show_code == false
    end
  end

  describe "category filter" do
    test "f cycles through categories" do
      model = App.init(nil)
      assert model.category_filter == nil

      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == :input

      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == :display
    end

    test "f filters component list" do
      model = App.init(nil)
      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == :input
      assert Enum.all?(model.components, &(&1.category == :input))
    end

    test "f wraps back to nil (all)" do
      model = App.init(nil)
      categories = Raxol.Playground.Catalog.list_categories()

      model =
        Enum.reduce(categories, model, fn _cat, acc ->
          {acc, []} = App.update(key_event("f"), acc)
          acc
        end)

      # After cycling through all categories, next press returns to nil
      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == nil
      # 42 = 40 baseline + the 2 harness TEA block demos (message + reasoning).
      assert length(model.components) == 42
    end

    test "f resets cursor to 0" do
      model = App.init(nil)
      {model, []} = App.update(key_event("j"), model)
      assert model.cursor == 1
      {model, []} = App.update(key_event("f"), model)
      assert model.cursor == 0
    end

    test "f does not activate during search" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(key_event("f"), model)
      # "f" was typed as search character, not filter
      assert model.search == "f"
      assert model.category_filter == nil
    end
  end

  describe "complexity filter" do
    test "x cycles through complexities" do
      model = App.init(nil)
      assert model.complexity_filter == nil

      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == :basic

      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == :intermediate

      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == :advanced

      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == nil
    end

    test "x filters component list" do
      model = App.init(nil)
      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == :basic
      assert Enum.all?(model.components, &(&1.complexity == :basic))
    end

    test "category and complexity filters combine" do
      model = App.init(nil)
      # Filter to :input category
      {model, []} = App.update(key_event("f"), model)
      assert model.category_filter == :input
      # Filter to :basic complexity
      {model, []} = App.update(key_event("x"), model)
      assert model.complexity_filter == :basic

      assert Enum.all?(model.components, fn c ->
               c.category == :input and c.complexity == :basic
             end)

      assert model.components != []
    end
  end

  describe "help overlay" do
    test "? opens help overlay" do
      model = App.init(nil)
      {model, []} = App.update(key_event("?"), model)
      assert model.show_help == true
    end

    test "? closes help overlay" do
      model = App.init(nil)
      {model, []} = App.update(key_event("?"), model)
      assert model.show_help == true
      {model, []} = App.update(key_event("?"), model)
      assert model.show_help == false
    end

    test "escape closes help overlay" do
      model = App.init(nil)
      {model, []} = App.update(key_event("?"), model)
      {model, []} = App.update(special_key(:escape), model)
      assert model.show_help == false
    end

    test "other keys are swallowed when help is shown" do
      model = App.init(nil)
      {model, []} = App.update(key_event("?"), model)
      original = model

      # j, q, etc should be no-ops
      {model, []} = App.update(key_event("j"), model)
      assert model == original
      {model, commands} = App.update(key_event("q"), model)
      assert commands == []
      assert model == original
    end

    test "? does not activate during search" do
      model = App.init(nil)
      {model, []} = App.update(key_event("/"), model)
      {model, []} = App.update(key_event("?"), model)
      assert model.search == "?"
      assert model.show_help == false
    end
  end

  describe "demo forwarding" do
    test "events forward to demo when focused on demo" do
      model = App.init(nil)
      # Select Button demo, then Tab to demo focus
      {model, []} = App.update(special_key(:enter), model)
      {model, []} = App.update(special_key(:tab), model)
      assert model.focus == :demo
      # Send "1" which ButtonDemo handles as primary click
      {model, []} = App.update(key_event("1"), model)
      assert model.demo_model.clicks == 1
    end
  end

  describe "escape from demo" do
    test "escape returns to sidebar when demo does not consume it" do
      model = App.init(nil)
      # Tab to demo focus (ButtonDemo doesn't use Escape)
      {model, []} = App.update(special_key(:tab), model)
      assert model.focus == :demo
      {model, []} = App.update(special_key(:escape), model)
      assert model.focus == :sidebar
    end

    test "escape stays in demo when demo consumes it" do
      model = App.init(nil)
      # Navigate to ModalDemo
      modal_idx = Enum.find_index(model.components, &(&1.name == "Modal"))

      model =
        Enum.reduce(1..modal_idx, model, fn _, acc ->
          {acc, []} = App.update(key_event("j"), acc)
          acc
        end)

      {model, []} = App.update(special_key(:enter), model)
      assert model.selected.name == "Modal"
      # Tab to demo focus, open the modal
      {model, []} = App.update(special_key(:tab), model)
      assert model.focus == :demo
      {model, []} = App.update(key_event("o"), model)
      assert model.demo_model.show == true
      # Escape closes the modal but stays in demo focus
      {model, []} = App.update(special_key(:escape), model)
      assert model.focus == :demo
      assert model.demo_model.show == false
      # Second Escape returns to sidebar (modal already closed)
      {model, []} = App.update(special_key(:escape), model)
      assert model.focus == :sidebar
    end
  end

  describe "quit" do
    test "q sends quit command from sidebar" do
      model = App.init(nil)
      {_model, commands} = App.update(key_event("q"), model)
      assert commands != []
    end

    test "ctrl+c sends quit from any focus" do
      model = App.init(nil)

      event = %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      }

      {_model, commands} = App.update(event, model)
      assert commands != []
    end
  end

  describe "view" do
    test "renders without errors" do
      model = App.init(nil)
      view = App.view(model)
      assert is_map(view)
    end

    test "renders with code panel open" do
      model = App.init(nil)
      model = %{model | show_code: true}
      view = App.view(model)
      assert is_map(view)
    end

    test "renders with search active" do
      model = App.init(nil)
      model = %{model | focus: :search, search: "test"}
      view = App.view(model)
      assert is_map(view)
    end

    test "renders with no selection" do
      model = App.init(nil)
      model = %{model | selected: nil, demo_model: nil}
      view = App.view(model)
      assert is_map(view)
    end

    test "renders help overlay" do
      model = App.init(nil)
      model = %{model | show_help: true}
      view = App.view(model)
      assert is_map(view)
    end

    test "renders with active filters" do
      model = App.init(nil)
      {model, []} = App.update(key_event("f"), model)
      {model, []} = App.update(key_event("x"), model)
      view = App.view(model)
      assert is_map(view)
    end
  end
end
