defmodule Raxol.Playground.AppTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.App

  # A demo whose init/1 raises. Before the guard, selecting it made
  # `select_current` crash, the Lifecycle swallowed it, and the entry read
  # as "Enter does nothing" -- see the "resilience" describe below.
  defmodule RaisingInitDemo do
    def init(_context), do: raise("boom-init")
    def view(_model), do: %{type: :text, content: "unreachable"}
    def update(_msg, model), do: {model, []}
    def subscribe(_model), do: []
  end

  # A demo whose view/1 raises: the frame must degrade to an error line,
  # not crash the whole playground.
  defmodule RaisingViewDemo do
    def init(_context), do: %{ok: true}
    def view(_model), do: raise("boom-view")
    def update(_msg, model), do: {model, []}
    def subscribe(_model), do: []
  end

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp special_key(key, extra \\ %{}) do
    %Raxol.Core.Events.Event{type: :key, data: Map.merge(%{key: key}, extra)}
  end

  defp fake_component(module) do
    %{
      module: module,
      name: "Boom",
      category: :input,
      description: "",
      complexity: :basic,
      tags: [],
      code_snippet: ""
    }
  end

  defp flat_texts(view) when is_map(view) do
    own = case Map.get(view, :content) do t when is_binary(t) -> [t]; _ -> [] end
    own ++ flat_texts(Map.get(view, :children))
  end

  defp flat_texts(list) when is_list(list), do: Enum.flat_map(list, &flat_texts/1)
  defp flat_texts(_other), do: []

  describe "init/1" do
    test "initializes with components and first selected" do
      model = App.init(nil)
      # 51 = 44 (through U1-c approval) + 1 (U3 overlay)
      # + 3 (U2 footer_stack/status_strip/composer) + 1 (U4 assembled)
      # + 1 (indication primitive).
      assert length(model.components) == 51
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
      # 51 = 44 (through U1-c approval) + 1 (U3 overlay)
      # + 3 (U2 footer_stack/status_strip/composer) + 1 (U4 assembled)
      # + 1 (indication primitive).
      assert length(model.components) == 51
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

  describe "demo failure resilience (Enter never silently no-ops)" do
    test "a demo whose init raises selects into an honest error, not a no-op" do
      model = App.init(nil)
      model = %{model | components: [fake_component(RaisingInitDemo)], cursor: 0}

      # Enter on the sidebar selects the (raising) demo.
      {model, _cmds} = App.update(special_key(:enter), model)

      # Selection ADVANCED (not swallowed) and the demo_model is the honest
      # error placeholder rather than a crash-induced unchanged model.
      assert model.selected.module == RaisingInitDemo
      assert match?(%{__demo_error__: _}, model.demo_model)

      # The preview renders the error text, never a blank/frozen pane.
      texts = flat_texts(App.view(model))
      assert Enum.any?(texts, &(&1 =~ "failed to load"))
    end

    test "a demo whose view raises degrades to an error line, not a frame crash" do
      model = App.init(nil)
      model = %{model | components: [fake_component(RaisingViewDemo)], cursor: 0}
      {model, _cmds} = App.update(special_key(:enter), model)

      # init succeeded, so the model is real; the view raises at render time.
      assert model.selected.module == RaisingViewDemo
      texts = flat_texts(App.view(model))
      assert Enum.any?(texts, &(&1 =~ "render error"))
    end

    test "the assembled harness demo inits without raising (cwd-independent fixture)" do
      # Regression: the demo loaded its fixture via a cwd-RELATIVE path and
      # raised when launched from anywhere but the repo root, which made the
      # entry read as "Enter does nothing". It must resolve the fixture
      # source-relative and never raise.
      model =
        Raxol.Playground.Demos.HarnessAssembledDemo.init(%{width: 60, height: 20})

      assert %Raxol.Harness.HarnessApp.Model{} = model
    end
  end
end
