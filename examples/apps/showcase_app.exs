# Showcase App
#
# Interactive component showcase demonstrating Raxol's View DSL.
#
# What you'll learn:
#   - Tab navigation: model.tab index drives which section renders
#   - View dispatch by pattern matching on model state (section_content/1)
#   - Conditional key handling: guards scope keys to specific tabs
#   - Multiple widget types: text, box, button, checkbox, progress, list
#
# Usage:
#   mix run examples/apps/showcase_app.exs
#
# Controls:
#   1-5       Switch sections
#   Tab       Next section
#   q/Ctrl+C  Quit
#   Section-specific keys listed in each section's footer

defmodule Raxol.Examples.Showcase do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @tab_count 5
  @tab_labels [
    "Text & Layout",
    "Form Inputs",
    "Data Display",
    "Interactive",
    "About"
  ]

  @sample_table_rows [
    ["1", "Elixir", "Functional", "1.16"],
    ["2", "Rust", "Systems", "1.77"],
    ["3", "Go", "Compiled", "1.22"],
    ["4", "Python", "Scripting", "3.12"],
    ["5", "Lua", "Embedded", "5.4"]
  ]

  @impl true
  def init(_context) do
    %{
      tab: 0,
      checkbox_checked: false,
      text_input_value: "",
      button_clicks: 0,
      counter: 0,
      table_cursor: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # -- Quit --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # -- Tab switching: number keys --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: n}}
      when n in ["1", "2", "3", "4", "5"] ->
        {%{model | tab: String.to_integer(n) - 1}, []}

      # -- Tab switching: Tab key --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        {%{model | tab: rem(model.tab + 1, @tab_count)}, []}

      # -- Section 2: Space toggles checkbox --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :space}}
      when model.tab == 1 ->
        {%{model | checkbox_checked: not model.checkbox_checked}, []}

      # -- Section 3: j/k navigate table --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}}
      when model.tab == 2 ->
        max_row = length(@sample_table_rows) - 1
        {%{model | table_cursor: min(model.table_cursor + 1, max_row)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}}
      when model.tab == 2 ->
        {%{model | table_cursor: max(model.table_cursor - 1, 0)}, []}

      # -- Section 4: +/-/r for counter --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}}
      when model.tab == 3 ->
        {%{model | counter: model.counter + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}}
      when model.tab == 3 ->
        {%{model | counter: model.counter - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "r"}}
      when model.tab == 3 ->
        {%{model | counter: 0}, []}

      # -- Section 4: button click messages --
      :click ->
        {%{model | button_clicks: model.button_clicks + 1}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Raxol Component Showcase", style: [:bold]),
        tab_bar(model.tab),
        divider(),
        content_region(model),
        divider(),
        footer(model)
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # flex: 1 pins the footer while tab body height changes
  defp content_region(model) do
    box style: %{flex: 1} do
      section_content(model)
    end
  end

  # -- Tab bar --

  defp tab_bar(active) do
    labels =
      @tab_labels
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        display = " #{idx + 1}:#{label} "

        if idx == active do
          text(display, style: [:bold, :underline])
        else
          text(display)
        end
      end)

    row style: %{gap: 0} do
      labels
    end
  end

  # -- Section views --
  # Pattern matching on model.tab dispatches to the right section.
  # Each section is an independent view helper returning an element tree.

  defp section_content(%{tab: 0}), do: section_text_layout()
  defp section_content(%{tab: 1} = m), do: section_form_inputs(m)
  defp section_content(%{tab: 2} = m), do: section_data_display(m)
  defp section_content(%{tab: 3} = m), do: section_interactive(m)
  defp section_content(%{tab: 4}), do: section_about()

  # 1. Text & Layout
  defp section_text_layout do
    column style: %{gap: 1} do
      [
        text("-- Text Styles --", style: [:bold]),
        row style: %{gap: 2} do
          [
            text("bold", style: [:bold]),
            text("underline", style: [:underline]),
            text("dim", style: [:dim]),
            text("normal")
          ]
        end,
        text("-- Box Borders --", style: [:bold]),
        row style: %{gap: 1} do
          [
            box style: %{border: :single, padding: 1, width: 16} do
              text("single")
            end,
            box style: %{border: :double, padding: 1, width: 16} do
              text("double")
            end,
            box style: %{border: :rounded, padding: 1, width: 16} do
              text("rounded")
            end
          ]
        end,
        text("-- Row / Column / Spacer --", style: [:bold]),
        row style: %{gap: 1} do
          [
            column style: %{gap: 0} do
              [text("col A line 1"), text("col A line 2")]
            end,
            spacer(),
            column style: %{gap: 0} do
              [text("col B line 1"), text("col B line 2")]
            end
          ]
        end,
        divider()
      ]
    end
  end

  # 2. Form Inputs
  defp section_form_inputs(model) do
    check_mark = if model.checkbox_checked, do: "[x]", else: "[ ]"

    column style: %{gap: 1} do
      [
        text("-- Checkbox --", style: [:bold]),
        text("#{check_mark} Enable feature  (press Space to toggle)"),
        text("-- Button --", style: [:bold]),
        button("Click me", on_click: :click),
        text("Button clicks: #{model.button_clicks}"),
        text("-- Text Input (display only) --", style: [:bold]),
        text_input(value: model.text_input_value, placeholder: "Type here...")
      ]
    end
  end

  # 3. Data Display
  defp section_data_display(model) do
    headers = ["#", "Language", "Type", "Version"]

    table_rows =
      @sample_table_rows
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        prefix = if idx == model.table_cursor, do: "> ", else: "  "
        style = if idx == model.table_cursor, do: [:bold], else: []
        text(prefix <> Enum.join(row, "  |  "), style: style)
      end)

    column style: %{gap: 1} do
      [
        text("-- Table --", style: [:bold]),
        text(Enum.join(headers, "  |  "), style: [:underline]),
        column style: %{gap: 0} do
          table_rows
        end,
        text("-- Progress --", style: [:bold]),
        progress(value: 65, max: 100),
        text("65%"),
        text("-- List --", style: [:bold]),
        list(items: ["Elixir", "Rust", "Go", "Python", "Lua"])
      ]
    end
  end

  # 4. Interactive
  defp section_interactive(model) do
    column style: %{gap: 1} do
      [
        text("-- Counter --", style: [:bold]),
        box style: %{
              border: :single,
              padding: 1,
              width: 24,
              justify_content: :center
            } do
          text("Count: #{model.counter}", style: [:bold])
        end,
        row style: %{gap: 1} do
          [
            button("Increment (=)", on_click: :increment),
            button("Reset (r)", on_click: :reset),
            button("Decrement (-)", on_click: :decrement)
          ]
        end,
        text("Press =/- keys or r to reset"),
        text("-- Click Counter --", style: [:bold]),
        text("Total button clicks: #{model.button_clicks}")
      ]
    end
  end

  # 5. About
  defp section_about do
    column style: %{gap: 1} do
      [
        text("-- About Raxol --", style: [:bold]),
        text("Raxol is a multi-surface application runtime for Elixir."),
        text("Architecture: TEA (The Elm Architecture)"),
        text("Callbacks: init/1, update/2, view/1, subscribe/1"),
        text("Layout: Flexbox + CSS Grid engines"),
        text(
          "Widgets: text, box, button, checkbox, table, progress, list, modal"
        ),
        text(""),
        text("-- Keyboard Reference --", style: [:bold]),
        text("  1-5       Switch sections"),
        text("  Tab       Next section"),
        text("  q/Ctrl+C  Quit"),
        text("  Space     Toggle checkbox (section 2)"),
        text("  j/k       Navigate table rows (section 3)"),
        text("  =/-/r     Counter controls (section 4)")
      ]
    end
  end

  # -- Footer --

  defp footer(%{tab: 1}), do: text("[Space] toggle  [1-5] sections  [q] quit")
  defp footer(%{tab: 2}), do: text("[j/k] navigate  [1-5] sections  [q] quit")

  defp footer(%{tab: 3}),
    do: text("[=/-] count  [r] reset  [1-5] sections  [q] quit")

  defp footer(_), do: text("[1-5] sections  [Tab] next  [q] quit")
end

Raxol.Core.Runtime.Log.info("Showcase: Starting Raxol...")
{:ok, pid} = Raxol.start_link(Raxol.Examples.Showcase, [])
Raxol.Core.Runtime.Log.info("Showcase: Raxol started. Running...")

ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
