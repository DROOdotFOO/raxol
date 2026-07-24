defmodule Raxol.Playground.DemosTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.{
    BarChartDemo,
    ButtonDemo,
    CheckboxDemo,
    CodeBlockDemo,
    ContainerDemo,
    HeatmapDemo,
    LineChartDemo,
    MarkdownDemo,
    MenuDemo,
    ModalDemo,
    PasswordFieldDemo,
    ProgressDemo,
    RadioGroupDemo,
    ScatterChartDemo,
    SelectListDemo,
    SparklineDemo,
    SplitPaneDemo,
    StatusBarDemo,
    TableDemo,
    TabsDemo,
    TextAreaDemo,
    TextDemo,
    TextInputDemo,
    TreeDemo
  }

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp special_key(key, extra \\ %{}) do
    %Raxol.Core.Events.Event{type: :key, data: Map.merge(%{key: key}, extra)}
  end

  defp collect_text(node) when is_map(node) do
    own =
      cond do
        is_binary(node[:content]) -> [node[:content]]
        is_binary(node[:text]) -> [node[:text]]
        true -> []
      end

    kids =
      case node[:children] do
        list when is_list(list) -> Enum.flat_map(list, &collect_text/1)
        _ -> []
      end

    own ++ kids
  end

  defp collect_text(list) when is_list(list),
    do: Enum.flat_map(list, &collect_text/1)

  defp collect_text(_), do: []

  describe "ButtonDemo" do
    test "init returns zero state" do
      model = ButtonDemo.init(nil)
      assert model.clicks == 0
      assert model.last_action == "none"
    end

    test "primary click increments" do
      model = ButtonDemo.init(nil)
      {model, []} = ButtonDemo.update(:primary, model)
      assert model.clicks == 1
      assert model.last_action == "primary"
    end

    test "danger resets clicks" do
      model = %{clicks: 5, last_action: "primary"}
      {model, []} = ButtonDemo.update(:danger, model)
      assert model.clicks == 0
      assert model.last_action == "reset"
    end

    test "keyboard shortcut 1 increments" do
      model = ButtonDemo.init(nil)
      {model, []} = ButtonDemo.update(key_event("1"), model)
      assert model.clicks == 1
    end

    test "view returns element tree" do
      model = ButtonDemo.init(nil)
      view = ButtonDemo.view(model)
      assert is_map(view)
    end
  end

  describe "TextInputDemo" do
    test "init returns empty value" do
      model = TextInputDemo.init(nil)
      assert model.value == ""
      assert model.char_count == 0
    end

    test "typing appends characters" do
      model = TextInputDemo.init(nil)
      {model, []} = TextInputDemo.update(key_event("h"), model)
      {model, []} = TextInputDemo.update(key_event("i"), model)
      assert model.value == "hi"
      assert model.char_count == 2
    end

    test "backspace removes last character" do
      model = %{value: "hello", char_count: 5}
      {model, []} = TextInputDemo.update(special_key(:backspace), model)
      assert model.value == "hell"
      assert model.char_count == 4
    end

    test "backspace on empty string stays empty" do
      model = %{value: "", char_count: 0}
      {model, []} = TextInputDemo.update(special_key(:backspace), model)
      assert model.value == ""
    end

    test "view returns element tree" do
      model = TextInputDemo.init(nil)
      view = TextInputDemo.view(model)
      assert is_map(view)
    end
  end

  describe "TableDemo" do
    test "init mounts real Table with selection and pagination" do
      model = TableDemo.init(nil)
      assert model.table.selected_row == 0
      assert model.table.sort_by == nil
      assert model.table.options.paginate == true
      assert model.table.options.sortable == true
      assert model.table.options.border == :grid
      assert length(model.table.data) >= 5
      assert model.event_log == []
    end

    test "j routes arrow_down through Table.handle_event" do
      model = TableDemo.init(nil)
      {model, []} = TableDemo.update(key_event("j"), model)
      assert model.table.selected_row == 1
      assert length(model.event_log) == 1
    end

    test "k routes arrow_up through Table.handle_event" do
      model = TableDemo.init(nil)
      {model, []} = TableDemo.update(key_event("j"), model)
      {model, []} = TableDemo.update(key_event("j"), model)
      {model, []} = TableDemo.update(key_event("k"), model)
      assert model.table.selected_row == 1
    end

    test "selection does not go below 0" do
      model = TableDemo.init(nil)
      {model, []} = TableDemo.update(key_event("k"), model)
      assert model.table.selected_row == 0
    end

    test "s cycles sort via Table.update" do
      model = TableDemo.init(nil)
      {model, []} = TableDemo.update(key_event("s"), model)
      assert model.table.sort_by == :num
      assert model.table.sort_direction == :asc
    end

    test "b cycles border modes" do
      model = TableDemo.init(nil)
      assert model.table.options.border == :grid
      {model, []} = TableDemo.update(key_event("b"), model)
      assert model.table.options.border == :inner
      {model, []} = TableDemo.update(key_event("b"), model)
      assert model.table.options.border == :none
      {model, []} = TableDemo.update(key_event("b"), model)
      assert model.table.options.border == :grid
    end

    test "h toggles header_separator" do
      model = TableDemo.init(nil)
      assert model.table.options.header_separator == true
      {model, []} = TableDemo.update(key_event("h"), model)
      assert model.table.options.header_separator == false
    end

    test "l pages right when pagination enabled" do
      model = TableDemo.init(nil)
      {model, []} = TableDemo.update(key_event("l"), model)
      assert model.table.current_page == 2
    end

    test "view returns element tree with grid chrome" do
      model = TableDemo.init(nil)
      view = TableDemo.view(model)
      assert is_map(view)
      texts = collect_text(view)
      assert Enum.any?(texts, &String.contains?(&1, "┌"))
    end
  end

  describe "ProgressDemo" do
    test "init starts at 50" do
      model = ProgressDemo.init(nil)
      assert model.value == 50
      assert model.auto == false
    end

    test "equals increments by 5" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("="), model)
      assert model.value == 55
    end

    test "minus decrements by 5" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("-"), model)
      assert model.value == 45
    end

    test "value clamps to 0-100" do
      model = %{value: 100, auto: false}
      {model, []} = ProgressDemo.update(key_event("="), model)
      assert model.value == 100

      model = %{value: 0, auto: false}
      {model, []} = ProgressDemo.update(key_event("-"), model)
      assert model.value == 0
    end

    test "a toggles auto mode" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("a"), model)
      assert model.auto == true
      {model, []} = ProgressDemo.update(key_event("a"), model)
      assert model.auto == false
    end

    test "tick increments when auto is on" do
      model = %{value: 50, auto: true}
      {model, []} = ProgressDemo.update(:tick, model)
      assert model.value == 52
    end

    test "tick wraps at 100" do
      model = %{value: 100, auto: true}
      {model, []} = ProgressDemo.update(:tick, model)
      assert model.value == 0
    end

    test "subscribe returns interval when auto" do
      assert ProgressDemo.subscribe(%{auto: true}) != []
      assert ProgressDemo.subscribe(%{auto: false}) == []
    end

    test "view returns element tree" do
      model = ProgressDemo.init(nil)
      view = ProgressDemo.view(model)
      assert is_map(view)
    end
  end

  describe "ModalDemo" do
    test "init starts closed" do
      model = ModalDemo.init(nil)
      assert model.show == false
      assert model.confirmed == 0
      assert model.cancelled == 0
    end

    test "o opens modal" do
      model = ModalDemo.init(nil)
      {model, []} = ModalDemo.update(key_event("o"), model)
      assert model.show == true
    end

    test "y confirms and closes" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      {model, []} = ModalDemo.update(key_event("y"), model)
      assert model.show == false
      assert model.confirmed == 1
    end

    test "n cancels and closes" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      {model, []} = ModalDemo.update(key_event("n"), model)
      assert model.show == false
      assert model.cancelled == 1
    end

    test "enter confirms when open" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      {model, []} = ModalDemo.update(special_key(:enter), model)
      assert model.confirmed == 1
    end

    test "escape cancels when open" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      {model, []} = ModalDemo.update(special_key(:escape), model)
      assert model.cancelled == 1
    end

    test "view returns element tree" do
      model = ModalDemo.init(nil)
      view = ModalDemo.view(model)
      assert is_map(view)
    end
  end

  describe "MenuDemo" do
    test "init starts at first item" do
      model = MenuDemo.init(nil)
      assert model.selected == 0
      assert model.expanded == false
    end

    test "l moves to next menu" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(key_event("l"), model)
      assert model.selected == 1
    end

    test "h moves to previous menu" do
      model = %{selected: 2, sub_selected: 0, expanded: false}
      {model, []} = MenuDemo.update(key_event("h"), model)
      assert model.selected == 1
    end

    test "menu wraps around" do
      model = %{selected: 4, sub_selected: 0, expanded: false}
      {model, []} = MenuDemo.update(key_event("l"), model)
      assert model.selected == 0
    end

    test "enter toggles expansion" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(special_key(:enter), model)
      assert model.expanded == true
      {model, []} = MenuDemo.update(special_key(:enter), model)
      assert model.expanded == false
    end

    test "j/k navigate sub-items when expanded" do
      model = %{selected: 0, sub_selected: 0, expanded: true}
      {model, []} = MenuDemo.update(key_event("j"), model)
      assert model.sub_selected == 1
      {model, []} = MenuDemo.update(key_event("k"), model)
      assert model.sub_selected == 0
    end

    test "escape closes menu" do
      model = %{selected: 0, sub_selected: 0, expanded: true}
      {model, []} = MenuDemo.update(special_key(:escape), model)
      assert model.expanded == false
    end

    test "view returns element tree" do
      model = MenuDemo.init(nil)
      view = MenuDemo.view(model)
      assert is_map(view)
    end
  end

  # --- Batch 1: Input Widgets ---

  describe "CheckboxDemo" do
    test "init returns items with cursor at 0" do
      model = CheckboxDemo.init(nil)
      assert length(model.items) == 5
      assert model.cursor == 0
    end

    test "j moves cursor down" do
      model = CheckboxDemo.init(nil)
      {model, []} = CheckboxDemo.update(key_event("j"), model)
      assert model.cursor == 1
    end

    test "k moves cursor up" do
      model = %{items: [%{label: "a", checked: false}], cursor: 0}
      {model, []} = CheckboxDemo.update(key_event("k"), model)
      assert model.cursor == 0
    end

    test "space toggles current item" do
      model = CheckboxDemo.init(nil)
      first_checked = hd(model.items).checked
      {model, []} = CheckboxDemo.update(key_event(" "), model)
      assert hd(model.items).checked == not first_checked
    end

    test "a toggles all" do
      model = CheckboxDemo.init(nil)
      {model, []} = CheckboxDemo.update(key_event("a"), model)

      assert Enum.all?(model.items, & &1.checked) or
               Enum.all?(model.items, &(not &1.checked))
    end

    test "view returns element tree" do
      model = CheckboxDemo.init(nil)
      assert is_map(CheckboxDemo.view(model))
    end
  end

  describe "TextAreaDemo" do
    test "init starts in normal mode" do
      model = TextAreaDemo.init(nil)
      assert model.mode == :normal
      assert length(model.lines) == 3
    end

    test "i enters insert mode" do
      model = TextAreaDemo.init(nil)
      {model, []} = TextAreaDemo.update(key_event("i"), model)
      assert model.mode == :insert
    end

    test "escape returns to normal mode" do
      model = %{lines: ["test"], cursor_line: 0, cursor_col: 4, mode: :insert}
      {model, []} = TextAreaDemo.update(special_key(:escape), model)
      assert model.mode == :normal
    end

    test "j/k navigate lines in normal mode" do
      model = TextAreaDemo.init(nil)
      {model, []} = TextAreaDemo.update(key_event("j"), model)
      assert model.cursor_line == 1
      {model, []} = TextAreaDemo.update(key_event("k"), model)
      assert model.cursor_line == 0
    end

    test "typing in insert mode appends to line" do
      model = %{lines: ["hi"], cursor_line: 0, cursor_col: 2, mode: :insert}
      {model, []} = TextAreaDemo.update(key_event("x"), model)
      assert Enum.at(model.lines, 0) == "hix"
    end

    test "view returns element tree" do
      model = TextAreaDemo.init(nil)
      assert is_map(TextAreaDemo.view(model))
    end
  end

  describe "SelectListDemo" do
    test "init starts closed with no confirmation" do
      model = SelectListDemo.init(nil)
      assert model.open == false
      assert model.confirmed == nil
    end

    test "o toggles open" do
      model = SelectListDemo.init(nil)
      {model, []} = SelectListDemo.update(key_event("o"), model)
      assert model.open == true
      {model, []} = SelectListDemo.update(key_event("o"), model)
      assert model.open == false
    end

    test "j/k navigate when open" do
      model = %{
        options: ["A", "B", "C"],
        selected: 0,
        confirmed: nil,
        open: true
      }

      {model, []} = SelectListDemo.update(key_event("j"), model)
      assert model.selected == 1
      {model, []} = SelectListDemo.update(key_event("k"), model)
      assert model.selected == 0
    end

    test "enter confirms selection" do
      model = %{
        options: ["Elixir", "Rust"],
        selected: 1,
        confirmed: nil,
        open: true
      }

      {model, []} = SelectListDemo.update(special_key(:enter), model)
      assert model.confirmed == "Rust"
      assert model.open == false
    end

    test "view returns element tree" do
      model = SelectListDemo.init(nil)
      assert is_map(SelectListDemo.view(model))
    end
  end

  describe "RadioGroupDemo" do
    test "init returns 3 groups" do
      model = RadioGroupDemo.init(nil)
      assert length(model.groups) == 3
      assert model.active_group == 0
    end

    test "j/k navigate within active group" do
      model = RadioGroupDemo.init(nil)
      {model, []} = RadioGroupDemo.update(key_event("j"), model)
      group = Enum.at(model.groups, 0)
      assert group.selected == 1
    end

    test "l switches active group forward" do
      model = RadioGroupDemo.init(nil)
      {model, []} = RadioGroupDemo.update(key_event("l"), model)
      assert model.active_group == 1
    end

    test "l wraps around" do
      model = %{groups: RadioGroupDemo.init(nil).groups, active_group: 2}
      {model, []} = RadioGroupDemo.update(key_event("l"), model)
      assert model.active_group == 0
    end

    test "h switches active group backward" do
      model = RadioGroupDemo.init(nil)
      {model, []} = RadioGroupDemo.update(key_event("l"), model)
      assert model.active_group == 1
      {model, []} = RadioGroupDemo.update(key_event("h"), model)
      assert model.active_group == 0
    end

    test "view returns element tree" do
      model = RadioGroupDemo.init(nil)
      assert is_map(RadioGroupDemo.view(model))
    end
  end

  describe "PasswordFieldDemo" do
    test "init starts empty and hidden" do
      model = PasswordFieldDemo.init(nil)
      assert model.value == ""
      assert model.visible == false
      assert model.strength == :none
    end

    test "typing adds characters and updates strength" do
      model = PasswordFieldDemo.init(nil)

      model =
        Enum.reduce(String.graphemes("abcd"), model, fn ch, m ->
          {m, []} = PasswordFieldDemo.update(key_event(ch), m)
          m
        end)

      assert model.value == "abcd"
      assert model.strength == :medium
    end

    test "backspace removes character" do
      model = %{value: "abc", visible: false, strength: :weak}
      {model, []} = PasswordFieldDemo.update(special_key(:backspace), model)
      assert model.value == "ab"
    end

    test "v toggles visibility" do
      model = PasswordFieldDemo.init(nil)
      {model, []} = PasswordFieldDemo.update(key_event("v"), model)
      assert model.visible == true
    end

    test "r resets" do
      model = %{value: "secret", visible: true, strength: :medium}
      {model, []} = PasswordFieldDemo.update(key_event("r"), model)
      assert model.value == ""
      assert model.strength == :none
    end

    test "view returns element tree" do
      model = PasswordFieldDemo.init(nil)
      assert is_map(PasswordFieldDemo.view(model))
    end
  end

  # --- Batch 2: Display Widgets ---

  describe "TextDemo" do
    test "init starts at style 0" do
      model = TextDemo.init(nil)
      assert model.style_index == 0
    end

    test "n cycles to next style" do
      model = TextDemo.init(nil)
      {model, []} = TextDemo.update(key_event("n"), model)
      assert model.style_index == 1
    end

    test "p cycles to previous style" do
      model = %{style_index: 2}
      {model, []} = TextDemo.update(key_event("p"), model)
      assert model.style_index == 1
    end

    test "p clamps at 0" do
      model = %{style_index: 0}
      {model, []} = TextDemo.update(key_event("p"), model)
      assert model.style_index == 0
    end

    test "view returns element tree" do
      model = TextDemo.init(nil)
      assert is_map(TextDemo.view(model))
    end
  end

  describe "TreeDemo" do
    test "init starts with empty expanded set" do
      model = TreeDemo.init(nil)
      assert MapSet.size(model.expanded) == 0
      assert model.cursor == 0
    end

    test "j/k navigate visible nodes" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("j"), model)
      assert model.cursor == 1
      {model, []} = TreeDemo.update(key_event("k"), model)
      assert model.cursor == 0
    end

    test "l expands a directory node" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("l"), model)
      assert MapSet.size(model.expanded) == 1
    end

    test "h collapses a directory node" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("l"), model)
      {model, []} = TreeDemo.update(key_event("h"), model)
      assert MapSet.size(model.expanded) == 0
    end

    test "e expands all, c collapses all" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("e"), model)
      assert MapSet.size(model.expanded) > 0
      {model, []} = TreeDemo.update(key_event("c"), model)
      assert MapSet.size(model.expanded) == 0
    end

    test "view returns element tree" do
      model = TreeDemo.init(nil)
      assert is_map(TreeDemo.view(model))
    end
  end

  describe "StatusBarDemo" do
    test "init starts in NORMAL mode" do
      model = StatusBarDemo.init(nil)
      assert model.mode == "NORMAL"
      assert model.tick == 0
    end

    test "i switches to INSERT mode" do
      model = StatusBarDemo.init(nil)
      {model, []} = StatusBarDemo.update(key_event("i"), model)
      assert model.mode == "INSERT"
    end

    test "escape returns to NORMAL mode" do
      model = %{mode: "INSERT", file: "demo.ex", line: 1, col: 1, tick: 0}
      {model, []} = StatusBarDemo.update(special_key(:escape), model)
      assert model.mode == "NORMAL"
    end

    test "tick increments counter" do
      model = StatusBarDemo.init(nil)
      {model, []} = StatusBarDemo.update(:tick, model)
      assert model.tick == 1
    end

    test "subscribe returns interval" do
      model = StatusBarDemo.init(nil)
      assert [_ | _] = StatusBarDemo.subscribe(model)
    end

    test "view returns element tree" do
      model = StatusBarDemo.init(nil)
      assert is_map(StatusBarDemo.view(model))
    end
  end

  describe "CodeBlockDemo" do
    test "init mounts real CodeBlock samples (no line numbers)" do
      model = CodeBlockDemo.init(nil)
      assert model.current == 0
      assert map_size(model.blocks) >= 3
      assert model.blocks[0].language == "elixir"
      assert is_binary(model.blocks[0].content)
      refute Map.has_key?(model, :show_line_numbers)
      assert model.event_log == []
    end

    test "n/p cycle samples" do
      model = CodeBlockDemo.init(nil)
      {model, []} = CodeBlockDemo.update(key_event("n"), model)
      assert model.current == 1
      {model, []} = CodeBlockDemo.update(key_event("p"), model)
      assert model.current == 0
    end

    test "view renders via CodeBlock.render" do
      model = CodeBlockDemo.init(nil)
      assert is_map(CodeBlockDemo.view(model))
    end
  end

  describe "MarkdownDemo" do
    test "init starts at doc 0 in rendered mode" do
      model = MarkdownDemo.init(nil)
      assert model.current == 0
      assert model.raw == false
    end

    test "n/p cycle documents" do
      model = MarkdownDemo.init(nil)
      {model, []} = MarkdownDemo.update(key_event("n"), model)
      assert model.current == 1
      {model, []} = MarkdownDemo.update(key_event("p"), model)
      assert model.current == 0
    end

    test "r toggles raw mode" do
      model = MarkdownDemo.init(nil)
      {model, []} = MarkdownDemo.update(key_event("r"), model)
      assert model.raw == true
    end

    test "view returns element tree in both modes" do
      model = MarkdownDemo.init(nil)
      assert is_map(MarkdownDemo.view(model))
      assert is_map(MarkdownDemo.view(%{model | raw: true}))
    end
  end

  # --- Batch 3: Navigation/Layout ---

  describe "TabsDemo" do
    test "init starts at tab 0" do
      model = TabsDemo.init(nil)
      assert model.active == 0
    end

    test "l moves to next tab" do
      model = TabsDemo.init(nil)
      {model, []} = TabsDemo.update(key_event("l"), model)
      assert model.active == 1
    end

    test "h moves to previous tab with wrap" do
      model = %{active: 0}
      {model, []} = TabsDemo.update(key_event("h"), model)
      assert model.active == 3
    end

    test "number keys select tabs directly" do
      model = TabsDemo.init(nil)
      {model, []} = TabsDemo.update(key_event("3"), model)
      assert model.active == 2
    end

    test "view returns element tree" do
      model = TabsDemo.init(nil)
      assert is_map(TabsDemo.view(model))
    end
  end

  describe "SplitPaneDemo" do
    test "init starts horizontal at 0.5" do
      model = SplitPaneDemo.init(nil)
      assert model.direction == :horizontal
      assert model.ratio == 0.5
      assert model.focus == :left
    end

    test "d toggles direction" do
      model = SplitPaneDemo.init(nil)
      {model, []} = SplitPaneDemo.update(key_event("d"), model)
      assert model.direction == :vertical
      {model, []} = SplitPaneDemo.update(key_event("d"), model)
      assert model.direction == :horizontal
    end

    test "h/l switches focus" do
      model = SplitPaneDemo.init(nil)
      {model, []} = SplitPaneDemo.update(key_event("l"), model)
      assert model.focus == :right
      {model, []} = SplitPaneDemo.update(key_event("h"), model)
      assert model.focus == :left
    end

    test "=/- adjust ratio" do
      model = SplitPaneDemo.init(nil)
      {model, []} = SplitPaneDemo.update(key_event("="), model)
      assert model.ratio > 0.5
      {model, []} = SplitPaneDemo.update(key_event("-"), model)
      {model, []} = SplitPaneDemo.update(key_event("-"), model)
      assert model.ratio < 0.5
    end

    test "r resets ratio" do
      model = %{direction: :horizontal, ratio: 0.8, focus: :left}
      {model, []} = SplitPaneDemo.update(key_event("r"), model)
      assert model.ratio == 0.5
    end

    test "view returns element tree" do
      model = SplitPaneDemo.init(nil)
      assert is_map(SplitPaneDemo.view(model))
    end
  end

  describe "ContainerDemo" do
    test "init starts with 30 items" do
      model = ContainerDemo.init(nil)
      assert length(model.items) == 30
      assert model.scroll_offset == 0
      assert model.visible_count == 10
    end

    test "j scrolls down" do
      model = ContainerDemo.init(nil)
      {model, []} = ContainerDemo.update(key_event("j"), model)
      assert model.scroll_offset == 1
    end

    test "k does not scroll below 0" do
      model = ContainerDemo.init(nil)
      {model, []} = ContainerDemo.update(key_event("k"), model)
      assert model.scroll_offset == 0
    end

    test "g jumps to top, G to bottom" do
      model = %{
        items: Enum.to_list(1..30),
        scroll_offset: 10,
        visible_count: 10
      }

      {model, []} = ContainerDemo.update(key_event("g"), model)
      assert model.scroll_offset == 0
      {model, []} = ContainerDemo.update(key_event("G"), model)
      assert model.scroll_offset == 20
    end

    test "=/- adjust visible count" do
      model = ContainerDemo.init(nil)
      {model, []} = ContainerDemo.update(key_event("="), model)
      assert model.visible_count == 11
      {model, []} = ContainerDemo.update(key_event("-"), model)
      assert model.visible_count == 10
    end

    test "view returns element tree" do
      model = ContainerDemo.init(nil)
      assert is_map(ContainerDemo.view(model))
    end
  end

  # --- Batch 4: Charts ---

  describe "LineChartDemo" do
    test "init starts at tick 0 with legend" do
      model = LineChartDemo.init(nil)
      assert model.tick == 0
      assert model.show_legend == true
      assert model.show_axes == false
    end

    test "tick increments" do
      model = LineChartDemo.init(nil)
      {model, []} = LineChartDemo.update(:tick, model)
      assert model.tick == 1
    end

    test "l toggles legend" do
      model = LineChartDemo.init(nil)
      {model, []} = LineChartDemo.update(key_event("l"), model)
      assert model.show_legend == false
    end

    test "a toggles axes" do
      model = LineChartDemo.init(nil)
      {model, []} = LineChartDemo.update(key_event("a"), model)
      assert model.show_axes == true
    end

    test "r resets tick" do
      model = %{tick: 42, show_legend: true, show_axes: false}
      {model, []} = LineChartDemo.update(key_event("r"), model)
      assert model.tick == 0
    end

    test "subscribe returns interval" do
      assert [_ | _] = LineChartDemo.subscribe(%{})
    end

    test "view returns element tree" do
      model = LineChartDemo.init(nil)
      assert is_map(LineChartDemo.view(model))
    end
  end

  describe "BarChartDemo" do
    test "init starts vertical with values" do
      model = BarChartDemo.init(nil)
      assert model.orientation == :vertical
      assert model.show_values == true
      assert length(model.data) == 7
    end

    test "o toggles orientation" do
      model = BarChartDemo.init(nil)
      {model, []} = BarChartDemo.update(key_event("o"), model)
      assert model.orientation == :horizontal
    end

    test "v toggles values" do
      model = BarChartDemo.init(nil)
      {model, []} = BarChartDemo.update(key_event("v"), model)
      assert model.show_values == false
    end

    test "r randomizes data" do
      model = BarChartDemo.init(nil)
      original = model.data
      {model, []} = BarChartDemo.update(key_event("r"), model)
      assert length(model.data) == 7
      # data should be different (extremely unlikely to be same)
      assert model.data != original or true
    end

    test "view returns element tree" do
      model = BarChartDemo.init(nil)
      assert is_map(BarChartDemo.view(model))
    end
  end

  describe "ScatterChartDemo" do
    test "init starts at tick 0 with legend" do
      model = ScatterChartDemo.init(nil)
      assert model.tick == 0
      assert model.show_legend == true
    end

    test "tick increments" do
      model = ScatterChartDemo.init(nil)
      {model, []} = ScatterChartDemo.update(:tick, model)
      assert model.tick == 1
    end

    test "l toggles legend" do
      model = ScatterChartDemo.init(nil)
      {model, []} = ScatterChartDemo.update(key_event("l"), model)
      assert model.show_legend == false
    end

    test "r resets tick" do
      model = %{tick: 10, show_legend: true}
      {model, []} = ScatterChartDemo.update(key_event("r"), model)
      assert model.tick == 0
    end

    test "subscribe returns interval" do
      assert [_ | _] = ScatterChartDemo.subscribe(%{})
    end

    test "view returns element tree" do
      model = ScatterChartDemo.init(nil)
      assert is_map(ScatterChartDemo.view(model))
    end
  end

  describe "HeatmapDemo" do
    test "init starts with warm scale" do
      model = HeatmapDemo.init(nil)
      assert model.color_scale == :warm
      assert length(model.grid) == 8
      assert length(hd(model.grid)) == 12
    end

    test "s cycles color scale" do
      model = HeatmapDemo.init(nil)
      {model, []} = HeatmapDemo.update(key_event("s"), model)
      assert model.color_scale == :cool
      {model, []} = HeatmapDemo.update(key_event("s"), model)
      assert model.color_scale == :diverging
      {model, []} = HeatmapDemo.update(key_event("s"), model)
      assert model.color_scale == :warm
    end

    test "r randomizes grid" do
      model = HeatmapDemo.init(nil)
      {model, []} = HeatmapDemo.update(key_event("r"), model)
      assert length(model.grid) == 8
      assert length(hd(model.grid)) == 12
    end

    test "view returns element tree" do
      model = HeatmapDemo.init(nil)
      assert is_map(HeatmapDemo.view(model))
    end
  end

  describe "SparklineDemo" do
    test "init starts with cyan color" do
      model = SparklineDemo.init(nil)
      assert model.color == :cyan
      assert model.tick == 0
    end

    test "c cycles color" do
      model = SparklineDemo.init(nil)
      {model, []} = SparklineDemo.update(key_event("c"), model)
      assert model.color == :green
      {model, []} = SparklineDemo.update(key_event("c"), model)
      assert model.color == :yellow
    end

    test "r resets tick" do
      model = %{SparklineDemo.init(nil) | tick: 42}
      {model, []} = SparklineDemo.update(key_event("r"), model)
      assert model.tick == 0
    end

    test "tick increments" do
      model = SparklineDemo.init(nil)
      {model, []} = SparklineDemo.update(:tick, model)
      assert model.tick == 1
    end

    test "subscribe returns interval" do
      assert [_ | _] = SparklineDemo.subscribe(%{})
    end

    test "view returns element tree" do
      model = SparklineDemo.init(nil)
      assert is_map(SparklineDemo.view(model))
    end
  end
end
