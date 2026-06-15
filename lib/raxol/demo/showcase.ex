defmodule Raxol.Demo.Showcase do
  @moduledoc """
  Interactive component showcase for `mix raxol.demo showcase`.

  Demonstrates Raxol's View DSL across 5 tabbed sections:
  text/layout, form inputs, data display, interactive widgets, and about.

  Controls: 1-5 or Tab to switch sections, section-specific keys in footer,
  q/Ctrl+C to quit.
  """

  use Raxol.Core.Runtime.Application

  import Raxol.Animation.Helpers

  @tab_count 5
  @tab_labels [
    "Text & Layout",
    "Form Inputs",
    "Data Display",
    "Interactive",
    "About"
  ]

  @sample_table_rows [
    ["1", "Elixir", "Functional", "1.17"],
    ["2", "Rust", "Systems", "1.82"],
    ["3", "Go", "Compiled", "1.23"],
    ["4", "Python", "Scripting", "3.13"],
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
    handle_global_keys(message, model) ||
      handle_tab_keys(message, model) ||
      {model, []}
  end

  defp handle_global_keys(message, model) do
    case message do
      key_match("q") ->
        {model, [Directive.stop()]}

      key_match("c", ctrl: true) ->
        {model, [Directive.stop()]}

      key_match(:char, char: n) when n in ["1", "2", "3", "4", "5"] ->
        {%{model | tab: String.to_integer(n) - 1}, []}

      key_match(:tab) ->
        {%{model | tab: rem(model.tab + 1, @tab_count)}, []}

      :click ->
        {%{model | button_clicks: model.button_clicks + 1}, []}

      _ ->
        nil
    end
  end

  defp handle_tab_keys(message, %{tab: 1} = model) do
    case message do
      key_match(:space) ->
        {%{model | checkbox_checked: not model.checkbox_checked}, []}

      _ ->
        nil
    end
  end

  defp handle_tab_keys(message, %{tab: 2} = model) do
    case message do
      key_match("j") ->
        max_row = length(@sample_table_rows) - 1
        {%{model | table_cursor: min(model.table_cursor + 1, max_row)}, []}

      key_match("k") ->
        {%{model | table_cursor: max(model.table_cursor - 1, 0)}, []}

      _ ->
        nil
    end
  end

  defp handle_tab_keys(message, %{tab: 3} = model) do
    case message do
      key_match("=") -> {%{model | counter: model.counter + 1}, []}
      key_match("-") -> {%{model | counter: model.counter - 1}, []}
      key_match("r") -> {%{model | counter: 0}, []}
      _ -> nil
    end
  end

  defp handle_tab_keys(_message, _model), do: nil

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Raxol Component Showcase", style: [:bold]),
        tab_bar(model.tab),
        divider(),
        section_content(model),
        divider(),
        footer(model)
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Tab bar --

  defp tab_bar(active) do
    labels =
      @tab_labels
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        display = " #{idx + 1}:#{label} "

        if idx == active,
          do: text(display, style: [:bold, :underline]),
          else: text(display)
      end)

    row style: %{gap: 0} do
      labels
    end
  end

  # -- Section views --

  defp section_content(model) do
    section =
      case model.tab do
        0 -> section_text_layout()
        1 -> section_form_inputs(model)
        2 -> section_data_display(model)
        3 -> section_interactive(model)
        _ -> section_about()
      end

    section
    |> animate(
      property: :opacity,
      from: 0.0,
      to: 1.0,
      duration: 250,
      easing: :ease_out_cubic
    )
  end

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
          stagger(
            [
              box id: "box-single",
                  style: %{border: :single, padding: 1, width: 16} do
                text("single")
              end,
              box id: "box-double",
                  style: %{border: :double, padding: 1, width: 16} do
                text("double")
              end,
              box id: "box-rounded",
                  style: %{border: :rounded, padding: 1, width: 16} do
                text("rounded")
              end
            ],
            property: :opacity,
            from: 0.0,
            to: 1.0,
            duration: 300,
            offset: 100
          )
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

  defp section_data_display(model) do
    headers = ["#", "Language", "Type", "Version"]

    table_rows =
      @sample_table_rows
      |> Enum.with_index()
      |> Enum.map(fn {row_data, idx} ->
        prefix = if idx == model.table_cursor, do: "> ", else: "  "
        style = if idx == model.table_cursor, do: [:bold], else: []

        text(prefix <> Enum.join(row_data, "  |  "),
          id: "row-#{idx}",
          style: style
        )
      end)
      |> stagger(
        property: :opacity,
        from: 0.0,
        to: 1.0,
        duration: 200,
        offset: 40
      )

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
