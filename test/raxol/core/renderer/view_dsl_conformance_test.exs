defmodule Raxol.Core.Renderer.ViewDslConformanceTest.ProbeWidget do
  @moduledoc false
  # A component for the `process_component` row: the rendering engine runs it
  # in its own process and draws its render tree.
  def init(props), do: {:ok, props}
  def render(state, _context), do: %{type: :text, content: state.label}
end

defmodule Raxol.Core.Renderer.ViewDslConformanceTest.Rows do
  @moduledoc false
  # The conformance table: one row per public constructor of the View DSL
  # (#1129). A row either renders a representative call, using the options
  # the constructor documents, and lists what must be visible in the frame,
  # or excludes the constructor with the reason it has nothing to draw.
  #
  # Row: {module, name, arities, spec}
  #
  # Spec:
  #   {:render, call, checks}  -- `call` builds the view; see `check/2` in the
  #                               test module for the check vocabulary
  #   {:helper, reason}        -- builds no node (macro plumbing, arithmetic)
  #   {:alias, target}         -- `target.name` is a `defdelegate` to this
  #                               function; the target's row renders it
  #
  # The row lists are data, one closure per row, so their "complexity" is
  # the table's length:
  # credo:disable-for-this-file Credo.Check.Refactor.ABCSize

  require Raxol.Core.Renderer.View
  require Raxol.View.Elements

  alias Raxol.Core.Renderer.View
  alias Raxol.Core.Renderer.ViewDslConformanceTest.ProbeWidget
  alias Raxol.View.{Components, Elements}

  @macro_helper "public so the container macros can call it at expansion " <>
                  "time; builds no view node"

  def all, do: view_rows() ++ elements_rows() ++ components_rows()

  def fetch!(key) do
    Enum.find(all(), fn {mod, name, arities, _spec} ->
      {mod, name, arities} == key
    end) || raise "no conformance row #{inspect(key)}"
  end

  defp render(call, checks), do: {:render, call, checks}

  defp lines(range),
    do: View.column(children: Enum.map(range, &View.text("line #{&1}")))

  defp view_rows do
    [
      {View, :new, [1, 2],
       render(
         fn ->
           View.new(:box,
             border: :single,
             fg: :red,
             children: [View.new(:text, content: "new node")]
           )
         end,
         text: "new node",
         styled: {"┌", fg: :red}
       )},
      {View, :text, [1, 2],
       render(
         fn ->
           View.column(
             children: [
               View.text("styled", fg: :green, style: [:bold, bg: :blue]),
               View.text("right", align: :right),
               View.text("mid", align: :center),
               View.text("wrap these words onto a second line of the frame",
                 wrap: :word
               )
             ]
           )
         end,
         styled: {"styled", fg: :green, bg: :blue, bold: true},
         cell: {35, 1, char: "r"},
         cell: {18, 2, char: "m"},
         line: {3, "wrap these words onto a second line of"},
         line: {4, "the frame"}
       )},
      {View, :box, [0, 1],
       render(
         fn ->
           View.box(
             title: "Title",
             border: :single,
             fg: :red,
             padding: 1,
             children: [View.text("inside")]
           )
         end,
         styled: {"Title", fg: :red},
         styled: {"┌", fg: :red},
         cell: {2, 2, char: "i"}
       )},
      {View, :box, [2],
       render(
         fn ->
           View.box title: "Macro box", border: :double do
             View.text("inside")
           end
         end,
         text: "╔",
         text: "Macro box",
         text: "inside"
       )},
      {View, :row, [0, 1],
       render(
         fn ->
           View.row(
             style: %{gap: 2},
             children: [View.text("a"), View.text("b")]
           )
         end,
         line: {0, "a  b"}
       )},
      {View, :row, [2],
       render(
         fn ->
           View.row style: %{gap: 1} do
             [View.text("a"), View.text("b")]
           end
         end,
         line: {0, "a b"}
       )},
      {View, :column, [1],
       render(
         fn ->
           View.column(
             style: %{gap: 1},
             children: [View.text("first"), View.text("second")]
           )
         end,
         line: {0, "first"},
         line: {2, "second"}
       )},
      {View, :column, [2],
       render(
         fn ->
           View.column style: %{gap: 1} do
             [View.text("first"), View.text("second")]
           end
         end,
         line: {0, "first"},
         line: {2, "second"}
       )},
      {View, :flex, [2],
       render(
         fn ->
           View.flex direction: :column do
             [View.text("top"), View.text("bottom")]
           end
         end,
         line: {0, "top"},
         line: {1, "bottom"}
       )},
      {View, :flex, [1],
       {:helper,
        "layout arithmetic: returns %{width:, height:} for flex constraints"}},
      {View, :border, [1, 2],
       render(
         fn ->
           View.border(View.text("inside"),
             title: "Border",
             style: :rounded,
             fg: :cyan
           )
         end,
         text: "Border",
         text: "inside",
         styled: {"╭", fg: :cyan}
       )},
      {View, :border, [3],
       render(
         fn ->
           View.border :double, title: "Macro" do
             View.text("inside")
           end
         end,
         text: "╔",
         text: "Macro",
         text: "inside"
       )},
      {View, :border_wrap, [2],
       render(
         fn ->
           View.border_wrap :double do
             View.text("wrapped")
           end
         end,
         text: "╔",
         text: "wrapped"
       )},
      {View, :wrap_with_border, [1, 2],
       render(
         fn ->
           View.wrap_with_border(View.text("inside"),
             title: "Wrapped",
             style: :double,
             fg: :yellow
           )
         end,
         text: "Wrapped",
         text: "inside",
         styled: {"╔", fg: :yellow}
       )},
      {View, :block_border, [1, 2],
       render(fn -> View.block_border(View.text("inside"), title: "Block") end,
         text: "Block",
         text: "inside",
         text: "┌"
       )},
      {View, :double_border, [1, 2],
       render(
         fn -> View.double_border(View.text("inside"), title: "Double") end,
         text: "Double",
         text: "╔"
       )},
      {View, :rounded_border, [1, 2],
       render(
         fn -> View.rounded_border(View.text("inside"), title: "Round") end,
         text: "Round",
         text: "╭"
       )},
      {View, :bold_border, [1, 2],
       render(fn -> View.bold_border(View.text("inside"), title: "Bold") end,
         text: "Bold",
         text: "inside",
         text: "┌"
       )},
      {View, :simple_border, [1, 2],
       render(
         fn -> View.simple_border(View.text("inside"), title: "Simple") end,
         text: "Simple",
         text: "inside",
         text: "┌"
       )},
      {View, :scroll, [1, 2],
       render(
         fn -> View.scroll(lines(1..6), viewport: {12, 3}, offset: {0, 2}) end,
         line: {0, "line 3"},
         line: {2, "line 5"},
         no_text: "line 2",
         no_text: "line 6",
         cell: {11, 0, char: "│"},
         cell: {11, 1, char: "█"}
       )},
      {View, :scroll_wrap, [2],
       render(
         fn ->
           View.scroll_wrap viewport: {12, 2}, offset: {0, 1} do
             lines(1..4)
           end
         end,
         line: {0, "line 2"},
         line: {1, "line 3"},
         no_text: "line 1",
         no_text: "line 4"
       )},
      {View, :table, [0, 1],
       render(
         fn -> View.table(headers: ["Name", "Qty"], data: [["apple", "3"]]) end,
         text: "Name",
         text: "apple"
       )},
      {View, :panel, [0, 1],
       render(
         fn ->
           View.panel(
             title: "Panel",
             fg: :blue,
             children: [View.text("inside")]
           )
         end,
         styled: {"Panel", fg: :blue},
         styled: {"┌", fg: :blue},
         text: "inside"
       )},
      {View, :promote_do_to_children, [1], {:helper, @macro_helper}},
      {View, :children_from_block, [1], {:helper, @macro_helper}},
      {View, :do_normalize_spacing, [1], {:helper, @macro_helper}},
      {View, :validate_keyword_opts, [2], {:helper, @macro_helper}},
      {View, :ensure_keyword, [1], {:helper, @macro_helper}},
      {View, :ensure_keyword_list, [1], {:helper, @macro_helper}},
      {View, :split, [3],
       render(
         fn ->
           View.split :horizontal, ratio: {1, 1} do
             [View.text("left"), View.text("right")]
           end
         end,
         line: {0, "left"},
         text: "right",
         cell: {19, 0, char: "|"},
         cell: {19, 1, char: "|"}
       )},
      {View, :split, [2],
       render(
         fn ->
           View.split :vertical do
             [View.text("top"), View.text("bottom")]
           end
         end,
         line: {0, "top"},
         text: "bottom",
         text: "---"
       )},
      {View, :split_layout, [2],
       render(
         fn ->
           View.split_layout :sidebar do
             [View.text("side"), View.text("main")]
           end
         end,
         text: "side",
         text: "main"
       )},
      {View, :split_pane, [0, 1],
       render(
         fn ->
           View.split_pane(
             direction: :vertical,
             children: [View.text("top"), View.text("bottom")]
           )
         end,
         line: {0, "top"},
         text: "bottom",
         text: "---"
       )},
      {View, :button, [1, 2],
       render(
         fn ->
           View.column(
             children: [
               View.button("Go", style: %{fg: :green}),
               View.button(label: "Keyword", on_click: :save)
             ]
           )
         end,
         styled: {"Go", fg: :green},
         text: "┌",
         text: "Keyword"
       )},
      {View, :checkbox, [1, 2],
       render(
         fn ->
           View.column(
             children: [
               View.checkbox("Opt", checked: true),
               View.checkbox(label: "Agree")
             ]
           )
         end,
         line: {0, "[x] Opt"},
         line: {1, "[ ] Agree"}
       )},
      {View, :text_input, [0, 1],
       render(
         fn ->
           View.column(
             children: [
               View.text_input(value: "typed"),
               View.text_input(placeholder: "hint"),
               View.text_input()
             ]
           )
         end,
         text: "typed",
         text: "hint",
         text: "┌"
       )},
      {View, :view, [2],
       render(
         fn ->
           View.view id: "root" do
             View.text("in view")
           end
         end,
         text: "in view"
       )},
      {View, :box_element, [0, 1],
       render(
         fn ->
           View.box_element(
             style: %{border: :double},
             children: [View.text("element")]
           )
         end,
         text: "╔",
         text: "element"
       )},
      {View, :shadow, [0, 1],
       render(
         fn ->
           View.shadow(
             offset: {1, 1},
             color: :blue,
             children: [
               View.box(border: :single, children: [View.text("lifted")])
             ]
           )
         end,
         cell: {0, 0, char: "┌"},
         text: "lifted",
         cell: {8, 3, bg: :blue},
         cell: {0, 3, bg: nil}
       )},
      {View, :process_component, [1, 2],
       render(
         fn ->
           View.process_component(ProbeWidget, %{label: "from a process"})
         end,
         text: "from a process"
       )},
      {View, :label, [0, 1, 2],
       render(
         fn ->
           View.column(
             children: [
               View.label("Name:", style: %{fg: :cyan}),
               View.label(content: "keyword label")
             ]
           )
         end,
         styled: {"Name:", fg: :cyan},
         text: "keyword label"
       )},
      {View, :input, [0, 1],
       render(fn -> View.input(value: "typed", placeholder: "hint") end,
         text: "typed",
         text: "┌"
       )},
      # The selected item is laid out in reverse video; the frame cannot
      # show it until the cell-to-buffer bridge keeps `:reverse` (reported
      # with #1129: `Backends.apply_cells_to_buffer/2` keeps only bold,
      # underline and italic).
      {View, :list, [0, 1],
       render(fn -> View.list(items: ["Elixir", "Rust"], selected: 1) end,
         line: {0, "Elixir"},
         line: {1, "Rust"}
       )},
      {View, :spacer, [0, 1],
       render(
         fn ->
           View.column(
             children: [
               View.text("above"),
               View.spacer(size: 2),
               View.text("below")
             ]
           )
         end,
         line: {0, "above"},
         line: {3, "below"}
       )},
      {View, :divider, [0, 1],
       render(fn -> View.divider(variant: :double, style: %{fg: :red}) end,
         text: "════",
         styled: {"═", fg: :red}
       )},
      {View, :image, [0, 1],
       render(
         fn -> View.image(src: "no/such/image.png", width: 12, height: 2) end,
         text: "[image]"
       )},
      {View, :progress, [0, 1],
       render(fn -> View.progress(value: 30, max: 60, style: %{fg: :green}) end,
         text: "50%",
         styled: {"█", fg: :green},
         text: "░"
       )},
      {View, :modal, [0, 1],
       render(
         fn ->
           View.column(
             children: [
               View.modal(
                 visible: true,
                 title: "Confirm",
                 content: View.text("Delete?")
               ),
               View.modal(title: "Hidden", content: View.text("not shown"))
             ]
           )
         end,
         text: "Confirm",
         text: "Delete?",
         text: "┌",
         no_text: "Hidden",
         no_text: "not shown"
       )},
      {View, :select, [0, 1],
       render(
         fn ->
           View.column(
             children: [
               View.select(options: ["Elixir", "Rust"], selected: "Rust"),
               View.select(options: ["Elixir"], placeholder: "Pick one")
             ]
           )
         end,
         line: {0, "[Rust ▾]"},
         no_text: "Elixir",
         line: {1, "[Pick one ▾]"}
       )},
      {View, :radio_group, [0, 1],
       render(
         fn ->
           View.radio_group(options: ["Small", "Large"], selected: "Large")
         end,
         line: {0, "( ) Small"},
         line: {1, "(o) Large"}
       )},
      {View, :textarea, [0, 1],
       render(fn -> View.textarea(value: "line one\nline two", rows: 3) end,
         text: "┌",
         line: {1, "│line one"},
         line: {2, "│line two"},
         line: {4, "└"},
         no_text_on: {5, "│"}
       )},
      {View, :container, [0, 1],
       render(
         fn ->
           View.column(
             children: [
               View.container(
                 scrollable: true,
                 style: %{height: 2},
                 children: [
                   View.text("one"),
                   View.text("two"),
                   View.text("three overflows")
                 ]
               ),
               View.text("after")
             ]
           )
         end,
         line: {0, "one"},
         line: {1, "two"},
         line: {2, "after"},
         no_text: "overflows"
       )},
      # The active tab is laid out in reverse video; see the `list` row.
      {View, :tabs, [0, 1],
       render(fn -> View.tabs(tabs: ["Overview", "Details"], active: 1) end,
         line: {0, " Overview | Details "}
       )},
      {View, :span, [1, 2],
       render(
         fn -> View.span("spanned", style: %{fg: :magenta, bold: true}) end,
         styled: {"spanned", fg: :magenta, bold: true}
       )},
      {View, :scrubber, [0, 1],
       render(fn -> View.scrubber(max: 10, position: 3) end, text: "3/10")},
      {View, :line_chart, [0, 1],
       render(
         fn ->
           View.line_chart(
             series: [%{name: "s", data: [1, 4, 2, 5], color: :magenta}],
             width: 12,
             height: 3
           )
         end,
         any_cell: [fg: :magenta],
         extent: {12, 3}
       )},
      {View, :bar_chart, [0, 1],
       render(
         fn ->
           View.bar_chart(
             series: [%{name: "s", data: [1, 3, 2], color: :green}],
             width: 12,
             height: 4
           )
         end,
         any_cell: [fg: :green],
         extent: {12, 4}
       )},
      {View, :scatter_chart, [0, 1],
       render(
         fn ->
           View.scatter_chart(
             series: [%{name: "p", data: [{0, 0}, {5, 5}], color: :yellow}],
             width: 10,
             height: 3
           )
         end,
         any_cell: [fg: :yellow],
         extent: {10, 3}
       )},
      {View, :heatmap, [0, 1],
       render(
         fn -> View.heatmap(data: [[1, 2], [3, 4]], width: 4, height: 2) end,
         any_cell: [bg: :painted],
         extent: {4, 2}
       )},
      {View, :sparkline, [0, 1],
       render(fn -> View.sparkline(data: [1, 5, 2, 8]) end,
         any_cell: [fg: :cyan],
         extent: {20, 3}
       )}
    ]
  end

  defp elements_rows do
    [
      {Elements, :box, [0, 1],
       render(
         fn ->
           Elements.box(
             title: "E box",
             border: :single,
             children: [Elements.text("inside")]
           )
         end,
         text: "E box",
         text: "inside"
       )},
      {Elements, :box, [2],
       render(
         fn ->
           Elements.box title: "E macro", border: :single do
             Elements.text("inside")
           end
         end,
         text: "E macro",
         text: "inside"
       )},
      {Elements, :row, [0, 1],
       render(
         fn ->
           Elements.row(
             gap: 1,
             children: [Elements.text("r1"), Elements.text("r2")]
           )
         end,
         line: {0, "r1 r2"}
       )},
      {Elements, :row, [2],
       render(
         fn ->
           Elements.row gap: 1 do
             [Elements.text("r1"), Elements.text("r2")]
           end
         end,
         line: {0, "r1 r2"}
       )},
      {Elements, :column, [0, 1],
       render(
         fn ->
           Elements.column(children: [Elements.text("c1"), Elements.text("c2")])
         end,
         line: {0, "c1"},
         line: {1, "c2"}
       )},
      {Elements, :column, [2],
       render(
         fn ->
           Elements.column style: %{gap: 1} do
             [Elements.text("c1"), Elements.text("c2")]
           end
         end,
         line: {0, "c1"},
         line: {2, "c2"}
       )},
      {Elements, :panel, [0, 1],
       render(
         fn ->
           Elements.panel(title: "E panel", children: [Elements.text("inside")])
         end,
         text: "E panel",
         text: "inside"
       )},
      {Elements, :panel, [2],
       render(
         fn ->
           Elements.panel title: "E panel macro" do
             Elements.text("inside")
           end
         end,
         text: "E panel macro",
         text: "inside"
       )},
      {Elements, :text, [1, 2],
       render(fn -> Elements.text("e text", fg: :red) end,
         styled: {"e text", fg: :red}
       )},
      {Elements, :button, [1, 2],
       render(
         fn ->
           Elements.column(
             children: [
               Elements.button("Press"),
               Elements.button(label: "Search", id: "search_button")
             ]
           )
         end,
         text: "Press",
         text: "Search",
         text: "┌"
       )},
      {Elements, :checkbox, [1, 2],
       render(
         fn ->
           Elements.column(
             children: [
               Elements.checkbox("On", checked: true),
               Elements.checkbox(label: "High Contrast", checked: false)
             ]
           )
         end,
         line: {0, "[x] On"},
         line: {1, "[ ] High Contrast"}
       )},
      {Elements, :text_input, [0, 1],
       render(fn -> Elements.text_input(value: "e input") end,
         text: "e input",
         text: "┌"
       )},
      {Elements, :table, [0, 1],
       render(fn -> Elements.table(headers: ["H"], data: [["v"]]) end,
         text: "H",
         text: "v"
       )},
      {Elements, :label, [0, 1, 2],
       render(
         fn ->
           Elements.column(
             children: [
               Elements.label("Username:", style: %{fg: :cyan}),
               Elements.label(content: "keyword label")
             ]
           )
         end,
         styled: {"Username:", fg: :cyan},
         text: "keyword label"
       )},
      {Elements, :border, [1, 2],
       render(
         fn -> Elements.border(Elements.text("inside"), title: "Elements") end,
         text: "Elements",
         text: "┌"
       )},
      {Elements, :scroll, [1, 2],
       render(
         fn ->
           Elements.scroll(Elements.text("scrolled"), viewport: {10, 1})
         end,
         text: "scrolled"
       )},
      {Elements, :shadow, [0, 1],
       render(
         fn ->
           Elements.shadow(color: :red, children: [Elements.text("hi")])
         end,
         text: "hi",
         cell: {2, 1, bg: :red}
       )},
      {Elements, :flex, [1],
       {:helper,
        "layout arithmetic: returns %{width:, height:} for flex constraints"}}
    ]
  end

  defp components_rows do
    delegated =
      for name <- [
            :input,
            :list,
            :spacer,
            :divider,
            :image,
            :progress,
            :modal,
            :select,
            :radio_group,
            :textarea,
            :container,
            :tabs,
            :scrubber,
            :line_chart,
            :bar_chart,
            :scatter_chart,
            :heatmap,
            :sparkline
          ] do
        {Components, name, [0, 1], {:alias, View}}
      end

    [
      {Components, :label, [0, 1, 2], {:alias, View}},
      {Components, :span, [1, 2], {:alias, View}},
      {Components, :text, [1],
       render(fn -> Components.text(content: "c text", style: %{fg: :red}) end,
         styled: {"c text", fg: :red}
       )},
      {Components, :box, [0, 1],
       render(
         fn ->
           Components.box(
             style: %{border: :single},
             children: [View.text("c box")]
           )
         end,
         text: "┌",
         text: "c box"
       )},
      {Components, :row, [0, 1],
       render(
         fn ->
           Components.row(gap: 1, children: [View.text("a"), View.text("b")])
         end,
         line: {0, "a b"}
       )},
      {Components, :column, [0, 1],
       render(
         fn ->
           Components.column(
             gap: 1,
             children: [View.text("c1"), View.text("c2")]
           )
         end,
         line: {0, "c1"},
         line: {2, "c2"}
       )},
      {Components, :button, [0, 1],
       render(fn -> Components.button(content: "C button") end,
         text: "C button",
         text: "┌"
       )},
      {Components, :checkbox, [0, 1],
       render(fn -> Components.checkbox(label: "C check", checked: true) end,
         line: {0, "[x] C check"}
       )},
      {Components, :table, [0, 1],
       render(fn -> Components.table(headers: ["K"], rows: [["v1"]]) end,
         text: "K",
         text: "v1"
       )},
      {Components, :split_pane, [0, 1],
       render(
         fn ->
           Components.split_pane(children: [View.text("L"), View.text("R")])
         end,
         line: {0, "L"},
         text: "R",
         cell: {19, 1, char: "|"}
       )}
    ] ++ delegated
  end
end

defmodule Raxol.Core.Renderer.ViewDslConformanceTest do
  @moduledoc """
  Every public constructor of the View DSL must draw what it is given (#1129).

  `Raxol.Core.Renderer.View`, `Raxol.View.Elements` and
  `Raxol.View.Components` each shipped constructors whose nodes the layout
  engine had no clause for, or whose options it dropped: `box title:` never
  drew, `checkbox/2`, `border/2`, `scroll/2` and `progress/1` rendered
  nothing, `text(style: [fg: :red])` lost its colour. Each was found one at a
  time, by hand.

  The table in `Rows` closes the class. It is checked against the modules'
  exports, so a constructor added without a row fails here, and each row is
  rendered by a headless session (the runtime's own layout, cell render and
  buffer), then its frame is checked for the text and the documented styles.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Renderer.View
  alias Raxol.Core.Renderer.ViewDslConformanceTest.{ProbeWidget, Rows}
  alias Raxol.Headless

  @dsl_modules [View, Raxol.View.Elements, Raxol.View.Components]
  @width 40
  @height 12

  defmodule ProbeApp do
    @moduledoc false
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{view: nil}

    @impl true
    def update({:show, view}, model), do: {%{model | view: view}, []}
    def update(_message, model), do: {model, []}

    @impl true
    def view(%{view: nil}), do: text("")
    def view(%{view: view}), do: view

    @impl true
    def subscriptions(_model), do: []
  end

  setup do
    case Process.whereis(Headless) do
      nil -> start_supervised!({Headless, [name: Headless]})
      _pid -> :ok
    end

    :ok
  end

  describe "the table" do
    test "has exactly one row per public constructor" do
      exported =
        for mod <- @dsl_modules,
            {name, arity} <- mod.__info__(:functions) ++ mod.__info__(:macros),
            into: MapSet.new(),
            do: {mod, name, arity}

      covered =
        for {mod, name, arities, _spec} <- Rows.all(),
            arity <- arities,
            do: {mod, name, arity}

      duplicated = covered -- Enum.uniq(covered)
      covered = MapSet.new(covered)

      missing = exported |> MapSet.difference(covered) |> Enum.sort()
      stale = covered |> MapSet.difference(exported) |> Enum.sort()

      assert missing == [],
             "public View DSL constructors with no conformance row: " <>
               "#{inspect(missing)}. Add a row that renders it, or exclude " <>
               "it with the reason it has nothing to draw."

      assert stale == [],
             "rows for functions that are not exported: #{inspect(stale)}"

      assert duplicated == [],
             "constructors with two rows: #{inspect(duplicated)}"
    end

    test "every alias row names a delegate that builds the same node" do
      for {mod, name, arities, {:alias, target}} <- Rows.all(),
          arity <- arities do
        assert function_exported?(target, name, arity),
               "#{inspect(mod)}.#{name}/#{arity} is excused as an alias of " <>
                 "#{inspect(target)}, which does not export it"
      end

      for {mod, name, _arities, {:alias, target}} <- Rows.all() do
        args = if name == :span, do: ["x"], else: [[]]

        assert apply(target, name, args) == apply(mod, name, args),
               "#{inspect(target)}.#{name} is not a plain delegate to " <>
                 "#{inspect(mod)}.#{name}; give it its own row"
      end
    end
  end

  describe "rendered frame" do
    for {mod, name, arities, {:render, _call, _checks}} <- Rows.all() do
      @row_key {mod, name, arities}
      test "#{inspect(mod)}.#{name}/#{Enum.join(arities, "|")}" do
        {_mod, _name, _arities, {:render, call, checks}} = Rows.fetch!(@row_key)
        frame = render_frame(call.())

        for check <- checks do
          assert check(frame, check), failure(frame, check)
        end
      end
    end
  end

  # --- rendering -----------------------------------------------------------

  defp render_frame(view) do
    id = :"view_dsl_conformance_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(ProbeApp, id: id, width: @width, height: @height)

    try do
      :ok = Headless.send_message(id, {:show, view})
      {:ok, buffer} = Headless.get_buffer(id)
      %{rows: buffer.cells, lines: Enum.map(buffer.cells, &row_text/1)}
    after
      Headless.stop(id)
      stop_probe_widgets()
    end
  end

  defp row_text(row), do: Enum.map_join(row, &cell_char/1)

  defp cell_char(%{wide_placeholder: true}), do: ""
  defp cell_char(%{char: char}), do: char

  # The rendering engine starts a component process for a
  # `process_component` node under `Raxol.DynamicSupervisor`; stop the ones
  # this table's widget started so they do not outlive the row.
  defp stop_probe_widgets do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Raxol.DynamicSupervisor),
        is_pid(pid),
        probe_widget?(pid) do
      DynamicSupervisor.terminate_child(Raxol.DynamicSupervisor, pid)
    end
  end

  defp probe_widget?(pid) do
    match?(%{module: ProbeWidget}, :sys.get_state(pid, 1_000))
  catch
    :exit, _ -> false
  end

  # --- checks --------------------------------------------------------------

  # `text:` appears somewhere in the frame.
  defp check(frame, {:text, string}),
    do: Enum.any?(frame.lines, &String.contains?(&1, string))

  # `no_text:` appears nowhere in the frame.
  defp check(frame, {:no_text, string}), do: not check(frame, {:text, string})

  # `line: {row, string}` -- that row starts with `string`.
  defp check(frame, {:line, {row, string}}),
    do: frame.lines |> Enum.at(row, "") |> String.starts_with?(string)

  # `no_text_on: {row, string}` -- that row does not contain `string`.
  defp check(frame, {:no_text_on, {row, string}}),
    do: not (frame.lines |> Enum.at(row, "") |> String.contains?(string))

  # `styled: {string, attrs}` -- every cell of the first occurrence of
  # `string` carries `attrs`.
  defp check(frame, {:styled, {string, attrs}}) do
    case find_cells(frame, string) do
      nil -> false
      cells -> Enum.all?(cells, &cell_has?(&1, attrs))
    end
  end

  # `cell: {x, y, attrs}` -- the cell at column x, row y carries `attrs`.
  defp check(frame, {:cell, {x, y, attrs}}) do
    case frame.rows |> Enum.at(y, []) |> Enum.at(x) do
      nil -> false
      cell -> cell_has?(cell, attrs)
    end
  end

  # `any_cell: attrs` -- at least one painted cell carries `attrs`.
  defp check(frame, {:any_cell, attrs}) do
    frame.rows
    |> List.flatten()
    |> Enum.any?(&(painted?(&1) and cell_has?(&1, attrs)))
  end

  # `extent: {width, height}` -- something is painted, and nothing at or past
  # column `width` or row `height`.
  defp check(frame, {:extent, {width, height}}) do
    painted =
      for {row, y} <- Enum.with_index(frame.rows),
          {cell, x} <- Enum.with_index(row),
          painted?(cell),
          do: {x, y}

    painted != [] and
      Enum.all?(painted, fn {x, y} -> x < width and y < height end)
  end

  defp find_cells(frame, string) do
    target = String.graphemes(string)
    Enum.find_value(frame.rows, &find_in_row(&1, target))
  end

  defp find_in_row(row, target) do
    chars = Enum.map(row, &cell_char/1)
    size = length(target)

    index =
      Enum.find(
        0..max(length(chars) - size, 0),
        &(Enum.slice(chars, &1, size) == target)
      )

    index && Enum.slice(row, index, size)
  end

  defp painted?(cell),
    do: cell.char not in [" ", ""] or not is_nil(cell.style.background)

  defp cell_has?(cell, attrs), do: Enum.all?(attrs, &cell_attr?(cell, &1))

  defp cell_attr?(cell, {:char, char}), do: cell.char == char
  defp cell_attr?(cell, {:fg, color}), do: cell.style.foreground == color
  defp cell_attr?(cell, {:bg, :painted}), do: not is_nil(cell.style.background)
  defp cell_attr?(cell, {:bg, color}), do: cell.style.background == color
  defp cell_attr?(cell, {:dim, value}), do: cell.style.faint == value

  defp cell_attr?(cell, {attr, value}),
    do: Map.fetch!(cell.style, attr) == value

  defp failure(frame, check) do
    "check #{inspect(check)} failed on the frame:\n" <>
      Enum.map_join(frame.lines, "\n", &("  |" <> String.trim_trailing(&1)))
  end
end
