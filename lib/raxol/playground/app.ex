defmodule Raxol.Playground.App do
  @moduledoc """
  Terminal playground for Raxol widgets.

  Browse, interact with, and copy code for all playground-ready widgets.
  Launch with `mix raxol.playground` or `Raxol.start_link(Raxol.Playground.App, [])`.

  Controls:
    j/k or arrows  Navigate component list
    Enter          Select component (preview)
    Tab            Cycle focus (sidebar / demo)
    Escape         Return to sidebar from demo
    /              Search components
    f              Cycle category filter
    x              Cycle complexity filter
    c              Toggle code snippet
    ?              Help overlay
    q or Ctrl+C    Quit
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.Catalog

  @categories [nil] ++ Catalog.list_categories()
  @complexities [nil, :basic, :intermediate, :advanced]
  @sidebar_width 28
  @sidebar_border_overhead 2
  @help_key_pad 18
  @unknown_category_order 99
  @default_terminal_width 80

  @category_order %{
    input: 0,
    display: 1,
    feedback: 2,
    navigation: 3,
    overlay: 4,
    layout: 5,
    visualization: 6,
    effects: 7
  }

  @impl true
  def init(_context) do
    components = Catalog.list_components() |> sort_by_category()
    terminal_width = detect_terminal_width()

    %{
      components: components,
      cursor: 0,
      selected: List.first(components),
      focus: :sidebar,
      search: nil,
      show_code: false,
      demo_model: nil,
      copied: false,
      category_filter: nil,
      complexity_filter: nil,
      show_help: false,
      terminal_width: terminal_width,
      available_width: demo_available_width(terminal_width)
    }
    |> init_demo()
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        forward_tick_to_demo(model)

      %Raxol.Core.Events.Event{type: :resize, data: %{width: w}} ->
        new_avail = demo_available_width(w)

        model =
          model
          |> Map.put(:terminal_width, w)
          |> Map.put(:available_width, new_avail)
          |> inject_width_into_demo()

        {model, []}

      _ ->
        cond do
          model.show_help -> handle_help(message, model)
          model.focus == :search -> handle_search(message, model)
          true -> handle_normal(message, model)
        end
    end
  end

  defp handle_help(message, model) do
    case message do
      key_match("?") -> {%{model | show_help: false}, []}
      key_match(:escape) -> {%{model | show_help: false}, []}
      _ -> {model, []}
    end
  end

  defp handle_search(message, model) do
    case message do
      key_match("c", ctrl: true) ->
        {model, [Directive.stop()]}

      key_match(:char, char: ch) ->
        new_search = (model.search || "") <> ch
        {refilter(%{model | search: new_search}), []}

      key_match(:backspace) ->
        new_search = String.slice(model.search || "", 0..-2//1)
        {refilter(%{model | search: new_search}), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
      when key in [:escape, :enter] ->
        {%{model | focus: :sidebar}, []}

      _ ->
        {model, []}
    end
  end

  defp handle_normal(message, model) do
    case message do
      key_match("q") ->
        {model, [Directive.stop()]}

      key_match("c", ctrl: true) ->
        {model, [Directive.stop()]}

      key_match(:tab) ->
        {cycle_focus(model), []}

      key_match("?") ->
        {%{model | show_help: true}, []}

      _ ->
        handle_normal_continued(message, model)
    end
  end

  defp handle_normal_continued(message, model) do
    case message do
      key_match("c") ->
        {%{model | show_code: not model.show_code, copied: false}, []}

      key_match("f") ->
        {cycle_filter(model, :category_filter, @categories), []}

      key_match("x") ->
        {cycle_filter(model, :complexity_filter, @complexities), []}

      key_match("/") ->
        {%{model | focus: :search, search: ""}, []}

      _ ->
        handle_focus_specific(message, model)
    end
  end

  defp handle_focus_specific(message, %{focus: :sidebar} = model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
      when key in [:up, :down] ->
        delta = if key == :up, do: -1, else: 1
        {move_cursor(model, delta), []}

      key_match(:char, char: ch) when ch in ["j", "k"] ->
        delta = if ch == "k", do: -1, else: 1
        {move_cursor(model, delta), []}

      key_match(:enter) ->
        {select_current(model), []}

      _ ->
        {model, []}
    end
  end

  defp handle_focus_specific(
         %Raxol.Core.Events.Event{type: :key, data: %{key: :escape}} = message,
         %{focus: :demo, selected: selected} = model
       )
       when selected != nil do
    {new_demo_model, demo_commands} =
      model.selected.module.update(message, model.demo_model)

    if new_demo_model == model.demo_model do
      {%{model | focus: :sidebar}, []}
    else
      {%{model | demo_model: new_demo_model}, demo_commands}
    end
  end

  defp handle_focus_specific(
         message,
         %{focus: :demo, selected: selected} = model
       )
       when selected != nil do
    forward_to_demo(model, message)
  end

  defp handle_focus_specific(_message, model), do: {model, []}

  @impl true
  def view(model) do
    if model.show_help do
      help_overlay(model)
    else
      main_view(model)
    end
  end

  @impl true
  def subscribe(model) do
    case {model.selected, model.demo_model} do
      {nil, _} -> []
      {_, nil} -> []
      {comp, demo_model} -> comp.module.subscribe(demo_model)
    end
  end

  # -- Layout --

  defp main_view(model) do
    content =
      row style: %{gap: 0} do
        [
          sidebar_panel(model),
          demo_panel(model)
        ]
      end

    # Grow the content row so it absorbs all vertical space between the
    # header and the status bar; the status bar stays pinned to the bottom
    # of the terminal instead of floating under the content.
    content = Map.put(content, :attrs, %{flex: %{grow: 1}})

    column style: %{gap: 0} do
      [
        header_bar(),
        content,
        status_bar(model)
      ]
    end
  end

  defp header_bar do
    row style: %{gap: 0} do
      [
        text(" raxol", style: [:bold], fg: :magenta),
        text(" playground ", style: [:bold], fg: :cyan),
        text("-- browse, interact, copy", style: [:dim])
      ]
    end
  end

  defp sidebar_panel(model) do
    items = build_sidebar_items(model)
    border_fg = if model.focus == :sidebar, do: :cyan, else: :white
    total = length(Catalog.list_components())
    showing = length(model.components)

    count_line =
      if showing == total do
        [text(" #{total} widgets", style: [:dim])]
      else
        [text(" #{showing}/#{total} widgets", style: [:dim])]
      end

    search_line =
      if model.focus == :search do
        [text(" / #{model.search || ""}_", fg: :yellow)]
      else
        []
      end

    filter_lines = active_filters(model)

    box style: %{border: :rounded, fg: border_fg, width: @sidebar_width} do
      column style: %{gap: 0} do
        count_line ++ filter_lines ++ search_line ++ items
      end
    end
  end

  defp build_sidebar_items(%{components: []} = _model) do
    [text("   No matches", style: [:dim], fg: :yellow)]
  end

  defp build_sidebar_items(model) do
    {_last_cat, items_rev} =
      model.components
      |> Enum.with_index()
      |> Enum.reduce({nil, []}, fn {comp, idx}, {last_cat, acc} ->
        is_current = idx == model.cursor
        marker = if is_current, do: " ▸ ", else: "   "
        item_opts = if is_current, do: [style: [:bold], fg: :green], else: []
        item = text(marker <> comp.name, item_opts)

        if comp.category != last_cat do
          hdr =
            text("  #{category_label(comp.category)}", style: [:dim], fg: :blue)

          {comp.category, [item, hdr | acc]}
        else
          {comp.category, [item | acc]}
        end
      end)

    Enum.reverse(items_rev)
  end

  defp active_filters(model) do
    parts =
      [
        if(model.category_filter, do: "#{model.category_filter}"),
        if(model.complexity_filter, do: "#{model.complexity_filter}")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> []
      _ -> [text(" [#{Enum.join(parts, " | ")}]", style: [:dim], fg: :yellow)]
    end
  end

  defp demo_panel(model) do
    case model.selected do
      nil ->
        text("  Select a component from the sidebar.", style: [:dim])

      comp ->
        badge_fg = complexity_color(comp.complexity)

        info =
          text(
            " #{comp.name} [#{comp.complexity}] #{comp.description}",
            style: [:dim],
            fg: badge_fg
          )

        children = [info, demo_content(model)]

        children =
          if model.show_code,
            do: Enum.concat(children, [code_panel(comp)]),
            else: children

        column style: %{gap: 0} do
          children
        end
    end
  end

  defp complexity_color(:basic), do: :green
  defp complexity_color(:intermediate), do: :yellow
  defp complexity_color(:advanced), do: :magenta

  defp demo_content(model) do
    case model.demo_model do
      nil -> text(" (no demo loaded)", style: [:dim])
      demo_model -> model.selected.module.view(demo_model)
    end
  end

  defp code_panel(comp) do
    column style: %{gap: 0} do
      [
        text(" Code", style: [:bold], fg: :yellow),
        text(" " <> String.trim(comp.code_snippet), fg: :yellow)
      ]
    end
  end

  defp help_overlay(model) do
    column style: %{gap: 0} do
      [
        header_bar(),
        text(""),
        box style: %{border: :double, fg: :cyan} do
          column style: %{gap: 0} do
            [
              text(""),
              text("  KEYBINDINGS", style: [:bold, :underline], fg: :cyan),
              text(""),
              help_line("j / k / arrows", "Navigate sidebar"),
              help_line("Enter", "Select component"),
              help_line("Tab", "Cycle focus (sidebar / demo)"),
              help_line("Escape", "Return to sidebar from demo"),
              help_line("/", "Search components"),
              help_line("f", "Cycle category filter"),
              help_line("x", "Cycle complexity filter"),
              help_line("c", "Toggle code snippet"),
              help_line("?", "Toggle this help"),
              help_line("q / Ctrl+C", "Quit"),
              text(""),
              filter_status(model),
              text(""),
              text("  Press ? or Escape to close.", style: [:dim])
            ]
          end
        end
      ]
    end
  end

  defp help_line(key, desc) do
    padded = String.pad_trailing(key, @help_key_pad)

    row style: %{gap: 0} do
      [
        text("  " <> padded, style: [:bold], fg: :yellow),
        text(desc)
      ]
    end
  end

  defp filter_status(model) do
    cat = if model.category_filter, do: "#{model.category_filter}", else: "all"

    cplx =
      if model.complexity_filter, do: "#{model.complexity_filter}", else: "all"

    text("  Filters: category=#{cat}  complexity=#{cplx}", style: [:dim])
  end

  defp status_bar(model) do
    focus_label =
      case model.focus do
        :sidebar -> " SIDEBAR "
        :demo -> " DEMO "
        :search -> " SEARCH "
      end

    keys =
      "j/k nav  ·  Enter select  ·  Tab demo  ·  Esc back  ·  f filter  ·  c code  ·  / search  ·  ? help  ·  q quit"

    row style: %{gap: 2} do
      [
        text(focus_label, style: [:bold, :reverse], fg: :cyan),
        text(keys, style: [:dim])
      ]
    end
  end

  defp category_label(:input), do: "INPUT"
  defp category_label(:display), do: "DISPLAY"
  defp category_label(:feedback), do: "FEEDBACK"
  defp category_label(:navigation), do: "NAVIGATION"
  defp category_label(:overlay), do: "OVERLAY"
  defp category_label(:layout), do: "LAYOUT"
  defp category_label(:visualization), do: "CHARTS"
  defp category_label(:effects), do: "EFFECTS"
  defp category_label(cat), do: cat |> to_string() |> String.upcase()

  # -- State helpers --

  defp sort_by_category(components) do
    Enum.sort_by(components, fn c ->
      Map.get(@category_order, c.category, @unknown_category_order)
    end)
  end

  defp init_demo(model) do
    case model.selected do
      nil ->
        %{model | demo_model: nil}

      comp ->
        demo_model = comp.module.init(nil)

        %{
          model
          | demo_model:
              Map.put(demo_model, :available_width, model.available_width)
        }
    end
  end

  defp move_cursor(model, delta) do
    max_idx = length(model.components) - 1
    new_cursor = Raxol.Core.Utils.Math.clamp(model.cursor + delta, 0, max_idx)
    %{model | cursor: new_cursor}
  end

  defp select_current(model) do
    case Enum.at(model.components, model.cursor) do
      nil ->
        model

      comp ->
        demo_model = comp.module.init(nil)

        %{
          model
          | selected: comp,
            demo_model:
              Map.put(demo_model, :available_width, model.available_width)
        }
    end
  end

  defp cycle_focus(%{focus: :sidebar} = model), do: %{model | focus: :demo}
  defp cycle_focus(%{focus: :demo} = model), do: %{model | focus: :sidebar}
  defp cycle_focus(%{focus: :search} = model), do: %{model | focus: :sidebar}

  defp cycle_filter(model, field, values) do
    current = Map.get(model, field)
    idx = Enum.find_index(values, &(&1 == current)) || 0
    next = Enum.at(values, rem(idx + 1, length(values)))
    refilter(%{model | field => next})
  end

  defp refilter(model) do
    search = if model.search == "", do: nil, else: model.search

    components =
      Catalog.filter(
        category: model.category_filter,
        complexity: model.complexity_filter,
        search: search
      )
      |> sort_by_category()

    %{model | components: components, cursor: 0}
  end

  defp forward_to_demo(model, event) do
    {new_demo_model, demo_commands} =
      model.selected.module.update(event, model.demo_model)

    {%{model | demo_model: new_demo_model}, demo_commands}
  end

  defp forward_tick_to_demo(%{selected: nil} = model), do: {model, []}
  defp forward_tick_to_demo(%{demo_model: nil} = model), do: {model, []}

  defp forward_tick_to_demo(model) do
    {new_demo_model, _cmds} =
      model.selected.module.update(:tick, model.demo_model)

    {%{model | demo_model: new_demo_model}, []}
  end

  defp detect_terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> @default_terminal_width
    end
  end

  defp demo_available_width(terminal_width) do
    max(terminal_width - @sidebar_width - @sidebar_border_overhead, 1)
  end

  defp inject_width_into_demo(%{demo_model: nil} = model), do: model

  defp inject_width_into_demo(model) do
    %{
      model
      | demo_model:
          Map.put(model.demo_model, :available_width, model.available_width)
    }
  end
end
