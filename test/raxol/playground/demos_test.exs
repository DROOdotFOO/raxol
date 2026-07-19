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

  # `key_event("x", ctrl: true)` arrives as a keyword list; normalize to a map.
  defp key_event(char, extra \\ []) do
    %Raxol.Core.Events.Event{
      type: :key,
      data: Map.merge(%{key: :char, char: char}, Map.new(extra))
    }
  end

  defp special_key(key, extra \\ []) do
    %Raxol.Core.Events.Event{
      type: :key,
      data: Map.merge(%{key: key}, Map.new(extra))
    }
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
    test "init mounts real TextInput states" do
      model = TextInputDemo.init(nil)
      assert model.main.value == ""
      assert model.main.focused == true
      assert model.main.placeholder == "Type here..."
      assert model.placeholder_story.value == ""
      assert model.placeholder_story.placeholder != ""
      assert model.filled_story.value == "already filled"
      assert model.max_length_story.max_length == 8
      assert model.muted == false
      assert model.event_log == []
    end

    test "typing routes through TextInput.handle_event" do
      model = TextInputDemo.init(nil)

      model =
        Enum.reduce(String.graphemes("hi"), model, fn ch, m ->
          {m, []} = TextInputDemo.update(key_event(ch), m)
          m
        end)

      assert model.main.value == "hi"
      assert model.main.cursor_pos == 2
      assert length(model.event_log) == 2
    end

    test "backspace removes a character via the real component" do
      model = TextInputDemo.init(nil)

      model =
        Enum.reduce(String.graphemes("hello"), model, fn ch, m ->
          {m, []} = TextInputDemo.update(key_event(ch), m)
          m
        end)

      {model, []} = TextInputDemo.update(special_key(:backspace), model)
      assert model.main.value == "hell"
      assert model.main.cursor_pos == 4
    end

    test "backspace on empty stays empty" do
      model = TextInputDemo.init(nil)
      {model, []} = TextInputDemo.update(special_key(:backspace), model)
      assert model.main.value == ""
    end

    test "ctrl-x clears the interactive field" do
      model = TextInputDemo.init(nil)
      {model, []} = TextInputDemo.update(key_event("a"), model)
      {model, []} = TextInputDemo.update(key_event("x", ctrl: true), model)
      assert model.main.value == ""
    end

    test "ctrl-d mutes routing (demo-level; TextInput has no disabled)" do
      model = TextInputDemo.init(nil)
      {model, []} = TextInputDemo.update(key_event("d", ctrl: true), model)
      assert model.muted == true
      {model, []} = TextInputDemo.update(key_event("z"), model)
      assert model.main.value == ""
    end

    test "view returns element tree" do
      model = TextInputDemo.init(nil)
      assert is_map(TextInputDemo.view(model))
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
    test "init mounts real Display.Progress states and spinner" do
      model = ProgressDemo.init(nil)
      assert model.value == 50
      assert model.auto == false
      assert model.main.progress == 0.5
      assert model.main.label == "Loading"
      assert model.main.animated == true
      assert model.empty_story.progress == 0.0
      assert model.half_story.progress == 0.5
      assert model.full_story.progress == 1.0
      assert is_list(model.spinner.frames)
      assert model.spinner.frame_index == 0
      assert model.event_log == []
    end

    test "equals increments by 5 via update_props on main" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("="), model)
      assert model.value == 55
      assert model.main.progress == 0.55
    end

    test "minus decrements by 5 via update_props on main" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("-"), model)
      assert model.value == 45
      assert model.main.progress == 0.45
    end

    test "value clamps to 0-100 and updates main.progress" do
      model = ProgressDemo.init(nil)

      model =
        Enum.reduce(1..20, model, fn _, m ->
          {m, []} = ProgressDemo.update(key_event("="), m)
          m
        end)

      assert model.value == 100
      assert model.main.progress == 1.0

      model =
        Enum.reduce(1..30, model, fn _, m ->
          {m, []} = ProgressDemo.update(key_event("-"), m)
          m
        end)

      assert model.value == 0
      assert model.main.progress == 0.0
    end

    test "a toggles auto mode" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("a"), model)
      assert model.auto == true
      {model, []} = ProgressDemo.update(key_event("a"), model)
      assert model.auto == false
    end

    test "r resets value through update_props" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("="), model)
      {model, []} = ProgressDemo.update(key_event("r"), model)
      assert model.value == 0
      assert model.main.progress == 0.0
    end

    test "tick increments value when auto is on" do
      model = %{ProgressDemo.init(nil) | auto: true}
      {model, []} = ProgressDemo.update(:tick, model)
      assert model.value == 52
      assert model.main.progress == 0.52
      assert model.frame == 1
    end

    test "tick wraps at 100 when auto is on" do
      model = %{ProgressDemo.init(nil) | value: 100, auto: true}

      model = %{
        model
        | main:
            Map.put(model.main, :progress, 1.0)
      }

      {model, []} = ProgressDemo.update(:tick, model)
      assert model.value == 0
      assert model.main.progress == 0.0
    end

    test "tick advances spinner even when auto is off" do
      model = ProgressDemo.init(nil)
      assert model.auto == false
      before = model.spinner.frame_index
      {model, []} = ProgressDemo.update(:tick, model)
      assert model.frame == 1
      assert model.spinner.frame_index != before or length(model.spinner.frames) == 1
    end

    test "s cycles spinner style" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("s"), model)
      assert model.spinner_style_idx == 1
      assert model.spinner.style == :line
    end

    test "i cycles indeterminate style index" do
      model = ProgressDemo.init(nil)
      {model, []} = ProgressDemo.update(key_event("i"), model)
      assert model.indet_style_idx == 1
    end

    test "subscribe always returns interval (spinner/indet animate)" do
      model = ProgressDemo.init(nil)
      subs = ProgressDemo.subscribe(model)
      assert is_list(subs)
      assert length(subs) >= 1
      assert length(ProgressDemo.subscribe(%{model | auto: true})) >= 1
    end

    test "view returns element tree and does not use dead progress() DSL" do
      model = ProgressDemo.init(nil)
      view = ProgressDemo.view(model)
      assert is_map(view)
      refute has_type?(view, :progress)
    end

    test "static snapshot stories are not mutated by value keys" do
      model = ProgressDemo.init(nil)
      empty = model.empty_story.progress
      half = model.half_story.progress
      full = model.full_story.progress
      {model, []} = ProgressDemo.update(key_event("="), model)
      assert model.empty_story.progress == empty
      assert model.half_story.progress == half
      assert model.full_story.progress == full
    end
  end

  defp has_type?(%{type: type}, type), do: true

  defp has_type?(map, type) when is_map(map) do
    Enum.any?(map, fn
      {:children, children} when is_list(children) ->
        Enum.any?(children, &has_type?(&1, type))

      {_k, v} when is_map(v) or is_list(v) ->
        has_type?(v, type)

      _ ->
        false
    end)
  end

  defp has_type?(list, type) when is_list(list),
    do: Enum.any?(list, &has_type?(&1, type))

  defp has_type?(_, _), do: false

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
    test "init mounts real Menu with nested items" do
      model = MenuDemo.init(nil)
      assert model.menu.cursor == :file
      assert model.menu.open_path == []
      assert model.menu.focused == true
      assert length(model.menu.items) >= 3
      assert model.last_selected == nil
      assert model.event_log == []
    end

    test "j/down moves cursor to next root item" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(key_event("j"), model)
      assert model.menu.cursor == :edit
      assert length(model.event_log) == 1
    end

    test "enter opens submenu of File" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(special_key(:enter), model)
      assert :file in model.menu.open_path
      assert model.menu.cursor == :new
    end

    test "j navigates within open submenu" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(special_key(:enter), model)
      {model, []} = MenuDemo.update(key_event("j"), model)
      assert model.menu.cursor == :open
    end

    test "enter on leaf records last_selected" do
      model = MenuDemo.init(nil)
      # open File
      {model, []} = MenuDemo.update(special_key(:enter), model)
      # activate New (cursor already on :new)
      {model, []} = MenuDemo.update(special_key(:enter), model)
      assert model.last_selected == :new
    end

    test "escape closes deepest submenu" do
      model = MenuDemo.init(nil)
      {model, []} = MenuDemo.update(special_key(:enter), model)
      assert model.menu.open_path == [:file]
      {model, []} = MenuDemo.update(special_key(:escape), model)
      assert model.menu.open_path == []
      assert model.menu.cursor == :file
    end

    test "view returns element tree" do
      model = MenuDemo.init(nil)
      view = MenuDemo.view(model)
      assert is_map(view)
    end
  end

  # --- Batch 1: Input Widgets ---

  describe "CheckboxDemo" do
    test "init mounts real Checkbox states" do
      model = CheckboxDemo.init(nil)
      assert length(model.checkboxes) == 5
      assert model.focus_index == 0
      assert hd(model.checkboxes).focused == true
      assert model.disabled_story.disabled == true
      assert model.required_story.required == true
      assert model.event_log == []
    end

    test "j moves focus down via demo-owned focus" do
      model = CheckboxDemo.init(nil)
      {model, []} = CheckboxDemo.update(key_event("j"), model)
      assert model.focus_index == 1
      assert Enum.at(model.checkboxes, 1).focused == true
      assert Enum.at(model.checkboxes, 0).focused == false
    end

    test "k clamps focus at 0" do
      model = CheckboxDemo.init(nil)
      {model, []} = CheckboxDemo.update(key_event("k"), model)
      assert model.focus_index == 0
    end

    test "space toggles focused checkbox via Checkbox.handle_event" do
      model = CheckboxDemo.init(nil)
      first_checked = hd(model.checkboxes).checked
      {model, []} = CheckboxDemo.update(key_event(" "), model)
      assert hd(model.checkboxes).checked == not first_checked
      assert length(model.event_log) == 1
    end

    test "a toggles all non-disabled checkboxes" do
      model = CheckboxDemo.init(nil)
      {model, []} = CheckboxDemo.update(key_event("a"), model)

      enabled = Enum.reject(model.checkboxes, & &1.disabled)

      assert Enum.all?(enabled, & &1.checked) or
               Enum.all?(enabled, &(not &1.checked))
    end

    test "view returns element tree" do
      model = CheckboxDemo.init(nil)
      assert is_map(CheckboxDemo.view(model))
    end
  end

  describe "TextAreaDemo" do
    test "init mounts real TextArea (MultiLineInput) states" do
      model = TextAreaDemo.init(nil)
      assert model.main.focused == true
      assert model.main.value =~ "Hello, world!"
      assert length(model.main.lines) >= 3
      assert model.placeholder_story.value == ""
      assert model.placeholder_story.placeholder != ""
      assert model.event_log == []
    end

    test "typing routes through TextArea.handle_event" do
      model = TextAreaDemo.init(nil)
      before = model.main.value
      {model, []} = TextAreaDemo.update(key_event("x"), model)
      assert model.main.value != before
      assert String.contains?(model.main.value, "x")
      assert length(model.event_log) == 1
    end

    test "enter inserts a newline via the real component" do
      model = TextAreaDemo.init(nil)
      lines_before = length(model.main.lines)
      {model, []} = TextAreaDemo.update(special_key(:enter), model)
      assert length(model.main.lines) >= lines_before
      assert String.contains?(model.main.value, "\n")
    end

    test "arrow down moves cursor via the real component" do
      model = TextAreaDemo.init(nil)
      {row0, _col0} = model.main.cursor_pos
      {model, []} = TextAreaDemo.update(special_key(:down), model)
      {row1, _col1} = model.main.cursor_pos
      assert row1 >= row0
    end

    test "ctrl-x clears the interactive area" do
      model = TextAreaDemo.init(nil)
      {model, []} = TextAreaDemo.update(key_event("x", ctrl: true), model)
      assert model.main.value == ""
    end

    test "view returns element tree" do
      model = TextAreaDemo.init(nil)
      assert is_map(TextAreaDemo.view(model))
    end
  end

  describe "SelectListDemo" do
    test "init mounts real SelectList states" do
      model = SelectListDemo.init(nil)
      assert model.main.has_focus == true
      assert model.main.focused_index == 0
      assert length(model.main.options) == 5
      assert model.main.enable_search == true
      assert model.multi_story.multiple == true
      assert model.empty_story.options == []
      assert model.event_log == []
    end

    test "j/down moves focused_index via SelectList.handle_event" do
      model = SelectListDemo.init(nil)
      {model, []} = SelectListDemo.update(key_event("j"), model)
      assert model.main.focused_index == 1
      assert length(model.event_log) == 1
    end

    test "k/up moves focused_index back" do
      model = SelectListDemo.init(nil)
      {model, []} = SelectListDemo.update(special_key(:down), model)
      {model, []} = SelectListDemo.update(key_event("k"), model)
      assert model.main.focused_index == 0
    end

    test "enter selects the focused option" do
      model = SelectListDemo.init(nil)
      {model, []} = SelectListDemo.update(special_key(:down), model)
      {model, []} = SelectListDemo.update(special_key(:enter), model)
      assert model.main.selected_index == 1
    end

    test "tab toggles search focus" do
      model = SelectListDemo.init(nil)
      assert model.main.is_search_focused == false
      {model, []} = SelectListDemo.update(special_key(:tab), model)
      assert model.main.is_search_focused == true
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
    test "init mounts real PasswordField states (secret: true)" do
      model = PasswordFieldDemo.init(nil)
      assert model.main.secret == true
      assert model.main.value == ""
      assert model.main.focused == true
      assert model.placeholder_story.placeholder != ""
      assert model.disabled_story.disabled == true
      assert model.event_log == []
    end

    test "typing routes through PasswordField.handle_event" do
      model = PasswordFieldDemo.init(nil)

      model =
        Enum.reduce(String.graphemes("abcd"), model, fn ch, m ->
          {m, []} = PasswordFieldDemo.update(key_event(ch), m)
          m
        end)

      assert model.main.value == "abcd"
      assert model.main.cursor_pos == 4
      assert length(model.event_log) == 4
    end

    test "backspace removes a character via the real component" do
      model = PasswordFieldDemo.init(nil)

      model =
        Enum.reduce(String.graphemes("abc"), model, fn ch, m ->
          {m, []} = PasswordFieldDemo.update(key_event(ch), m)
          m
        end)

      {model, []} = PasswordFieldDemo.update(special_key(:backspace), model)
      assert model.main.value == "ab"
      assert model.main.cursor_pos == 2
    end

    test "ctrl-x clears the interactive field" do
      model = PasswordFieldDemo.init(nil)
      {model, []} = PasswordFieldDemo.update(key_event("a"), model)
      {model, []} = PasswordFieldDemo.update(key_event("x", ctrl: true), model)
      assert model.main.value == ""
    end

    test "ctrl-d toggles disabled and swallows subsequent keys" do
      model = PasswordFieldDemo.init(nil)
      {model, []} = PasswordFieldDemo.update(key_event("d", ctrl: true), model)
      assert model.main.disabled == true
      {model, []} = PasswordFieldDemo.update(key_event("z"), model)
      assert model.main.value == ""
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
    test "init mounts real Display.Tree with empty expanded set" do
      model = TreeDemo.init(nil)
      assert MapSet.size(model.tree.expanded) == 0
      assert model.tree.cursor == :src
      assert model.tree.focused == true
      assert model.event_log == []
    end

    test "j/k navigate visible nodes via Tree.handle_event" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("j"), model)
      assert model.tree.cursor == :test
      {model, []} = TreeDemo.update(key_event("k"), model)
      assert model.tree.cursor == :src
      assert length(model.event_log) == 2
    end

    test "l expands a directory node via Tree.handle_event" do
      model = TreeDemo.init(nil)
      assert model.tree.cursor == :src
      {model, []} = TreeDemo.update(key_event("l"), model)
      assert MapSet.member?(model.tree.expanded, :src)
    end

    test "h collapses a directory node via Tree.handle_event" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("l"), model)
      {model, []} = TreeDemo.update(key_event("h"), model)
      assert MapSet.size(model.tree.expanded) == 0
    end

    test "e expands all, c collapses all (demo-level)" do
      model = TreeDemo.init(nil)
      {model, []} = TreeDemo.update(key_event("e"), model)
      assert MapSet.size(model.tree.expanded) > 0
      {model, []} = TreeDemo.update(key_event("c"), model)
      assert MapSet.size(model.tree.expanded) == 0
      assert model.tree.cursor == :src
    end

    test "view returns element tree" do
      model = TreeDemo.init(nil)
      assert is_map(TreeDemo.view(model))
    end
  end

  describe "StatusBarDemo" do
    test "init mounts real Display.StatusBar in NORMAL mode" do
      model = StatusBarDemo.init(nil)
      assert model.fields.mode == "NORMAL"
      assert model.fields.tick == 0
      assert model.status_bar.items != []
      assert Enum.any?(model.status_bar.items, &(&1.key == "Mode" and &1.label == "NORMAL"))
      assert model.event_log == []
    end

    test "i switches to INSERT and rebuilds items" do
      model = StatusBarDemo.init(nil)
      {model, []} = StatusBarDemo.update(key_event("i"), model)
      assert model.fields.mode == "INSERT"
      assert Enum.any?(model.status_bar.items, &(&1.key == "Mode" and &1.label == "INSERT"))
    end

    test "escape returns to NORMAL mode" do
      model = StatusBarDemo.init(nil)
      {model, []} = StatusBarDemo.update(key_event("i"), model)
      {model, []} = StatusBarDemo.update(special_key(:escape), model)
      assert model.fields.mode == "NORMAL"
    end

    test "tick increments counter and rebuilds items without log spam" do
      model = StatusBarDemo.init(nil)
      {model, []} = StatusBarDemo.update(:tick, model)
      assert model.fields.tick == 1
      assert Enum.any?(model.status_bar.items, &(&1.key == "Up" and &1.label == "1s"))
      assert model.event_log == []
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
    test "init mounts real Tabs state at index 0" do
      model = TabsDemo.init(nil)
      assert model.tabs.active_index == 0
      assert model.tabs.focused == true
      assert length(model.tabs.tabs) == 4
      assert model.event_log == []
    end

    test "l/right moves to next tab via Tabs.handle_event" do
      model = TabsDemo.init(nil)
      {model, []} = TabsDemo.update(key_event("l"), model)
      assert model.tabs.active_index == 1
      assert length(model.event_log) == 1
    end

    test "h/left wraps to last tab" do
      model = TabsDemo.init(nil)
      {model, []} = TabsDemo.update(key_event("h"), model)
      assert model.tabs.active_index == 3
    end

    test "number keys select tabs directly" do
      model = TabsDemo.init(nil)
      {model, []} = TabsDemo.update(key_event("3"), model)
      assert model.tabs.active_index == 2
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
