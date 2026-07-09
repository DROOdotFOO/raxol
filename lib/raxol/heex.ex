defmodule Raxol.HEEx do
  @moduledoc """
  **EXPERIMENTAL** -- HEEx template integration for Raxol.

  Allows using Phoenix HEEx templates directly in terminal applications,
  with terminal-specific components and styling.

  `Raxol.HEEx.Components` provides real Phoenix Component implementations
  that emit HTML with `data-terminal-component` attributes.
  `compile_heex_for_terminal/2` parses this HTML and builds Raxol widget
  trees compatible with the rendering pipeline.

  ## Example

      defmodule MyHEExApp do
        use Raxol.HEEx

        def render(assigns) do
          ~H\"\"\"
          <.terminal_box padding={2} border="single">
            <.terminal_text color="green" bold>
              Hello, <%= @name %>!
            </.terminal_text>

            <.terminal_button phx-click="click_me" class="primary">
              Click me!
            </.terminal_button>
          </.terminal_box>
          \"\"\"
        end
      end
  """

  defmacro __using__(_opts) do
    if Code.ensure_loaded?(Phoenix.Component) do
      quote do
        import Phoenix.Component
        import Raxol.HEEx
        import Raxol.HEEx.Components
      end
    else
      quote do
        import Raxol.HEEx
      end
    end
  end

  @doc """
  Compile HEEx templates for terminal rendering.

  Takes rendered HEEx HTML (a string with `data-terminal-component` attributes)
  and converts it to Raxol widget tree maps compatible with the rendering pipeline.

  ## Parameters

  - `template` - Raw HEEx template string (before Phoenix rendering)
  - `assigns` - Map of template assigns for variable interpolation

  ## Returns

  A widget tree map: `%{type: atom, children: list, style: map, ...}`
  """
  def compile_heex_for_terminal(template, assigns) do
    template
    |> interpolate_assigns(assigns)
    |> parse_html_to_widget_tree()
  end

  # Variable interpolation for raw template strings
  defp interpolate_assigns(template, assigns) do
    Enum.reduce(assigns, template, fn {key, value}, acc ->
      pattern = "<%= @#{key} %>"
      String.replace(acc, pattern, to_string(value))
    end)
  end

  @doc """
  Convert rendered HTML (from Phoenix Components) to a Raxol widget tree.

  Parses HTML with `data-terminal-component` attributes and builds the
  corresponding widget tree structure that the rendering pipeline expects.
  """
  def parse_html_to_widget_tree(html) when is_binary(html) do
    html
    |> tokenize()
    |> build_tree()
    |> convert_nodes()
  end

  # Tokenizer: convert HTML string to a flat list of tokens
  defp tokenize(html) do
    tokenize(html, [])
  end

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(html, acc) do
    html
    |> try_self_closing(acc)
    |> try_open_tag(acc)
    |> try_close_tag(acc)
    |> try_text(acc)
    |> skip_char(acc)
  end

  defp try_self_closing(html, acc) do
    case Regex.run(~r/\A<(\w+)((?:\s+[^>]*?)?)\/>/s, html) do
      [full, tag, attrs_str] ->
        rest = String.slice(html, String.length(full)..-1//1)

        tokenize(rest, [{:self_closing, tag, parse_attributes(attrs_str)} | acc])

      nil ->
        {:continue, html}
    end
  end

  defp try_open_tag({:continue, html}, acc) do
    case Regex.run(~r/\A<(\w+)((?:\s+[^>]*?)?)>/s, html) do
      [full, tag, attrs_str] ->
        rest = String.slice(html, String.length(full)..-1//1)
        tokenize(rest, [{:open, tag, parse_attributes(attrs_str)} | acc])

      nil ->
        {:continue, html}
    end
  end

  defp try_open_tag(result, _acc), do: result

  defp try_close_tag({:continue, html}, acc) do
    case Regex.run(~r/\A<\/(\w+)\s*>/s, html) do
      [full, tag] ->
        rest = String.slice(html, String.length(full)..-1//1)
        tokenize(rest, [{:close, tag} | acc])

      nil ->
        {:continue, html}
    end
  end

  defp try_close_tag(result, _acc), do: result

  defp try_text({:continue, html}, acc) do
    case Regex.run(~r/\A([^<]+)/s, html) do
      [full, text] ->
        rest = String.slice(html, String.length(full)..-1//1)
        trimmed = String.trim(text)

        if trimmed == "" do
          tokenize(rest, acc)
        else
          tokenize(rest, [{:text, trimmed} | acc])
        end

      nil ->
        {:continue, html}
    end
  end

  defp try_text(result, _acc), do: result

  defp skip_char({:continue, html}, acc) do
    tokenize(String.slice(html, 1..-1//1), acc)
  end

  defp skip_char(result, _acc), do: result

  # Parse HTML attributes from a string
  defp parse_attributes(attrs_str) do
    # Match key="value" and key={value} and standalone boolean attrs
    Regex.scan(
      ~r/([\w\-]+)(?:=(?:"([^"]*)"|'([^']*)'|\{([^}]*)\}))?/,
      attrs_str
    )
    |> Enum.map(fn
      [_, key, value, "", ""] -> {key, value}
      [_, key, "", value, ""] -> {key, value}
      [_, key, "", "", value] -> {key, value}
      [_, key] -> {key, "true"}
      [_, key, value] -> {key, value}
    end)
    |> Map.new()
  end

  # Build a tree from flat tokens
  defp build_tree(tokens) do
    {nodes, _rest} = build_children(tokens, nil)
    nodes
  end

  defp build_children([], _stop_tag), do: {[], []}

  defp build_children([{:close, tag} | rest], stop_tag) when tag == stop_tag do
    {[], rest}
  end

  defp build_children([{:close, _tag} | rest], stop_tag) do
    # Mismatched close tag, skip it
    build_children(rest, stop_tag)
  end

  defp build_children([{:text, text} | rest], stop_tag) do
    {siblings, remaining} = build_children(rest, stop_tag)
    {[{:text_node, text} | siblings], remaining}
  end

  defp build_children([{:self_closing, tag, attrs} | rest], stop_tag) do
    node = {:element, tag, attrs, []}
    {siblings, remaining} = build_children(rest, stop_tag)
    {[node | siblings], remaining}
  end

  defp build_children([{:open, tag, attrs} | rest], stop_tag) do
    {children, after_close} = build_children(rest, tag)
    node = {:element, tag, attrs, children}
    {siblings, remaining} = build_children(after_close, stop_tag)
    {[node | siblings], remaining}
  end

  # Convert parsed tree nodes to Raxol widget tree maps
  defp convert_nodes(nodes) when is_list(nodes) do
    widgets =
      Enum.map(nodes, &convert_node/1)
      |> Enum.reject(&is_nil/1)

    case widgets do
      [single] -> single
      multiple -> %{type: :column, children: multiple, style: %{}}
    end
  end

  defp convert_node({:text_node, text}) do
    %{type: :text, content: text, style: %{}, id: nil}
  end

  defp convert_node({:element, _tag, attrs, children}) do
    component_type = Map.get(attrs, "data-terminal-component")
    convert_component(component_type, attrs, children)
  end

  defp convert_component("box", attrs, children) do
    style = decode_style(Map.get(attrs, "data-style", "{}"))

    %{
      type: :box,
      children: convert_children(children),
      style: style,
      id: Map.get(attrs, "id"),
      padding: Map.get(style, "padding", 0),
      border: Map.get(style, "border", :none)
    }
  end

  defp convert_component("row", attrs, children) do
    %{
      type: :flex,
      direction: :row,
      children: convert_children(children),
      gap: parse_int(Map.get(attrs, "data-gap", "0")),
      justify: parse_justify(Map.get(attrs, "data-justify", "start")),
      align: parse_align(Map.get(attrs, "data-align", "start")),
      style: %{},
      id: Map.get(attrs, "id")
    }
  end

  defp convert_component("column", attrs, children) do
    %{
      type: :flex,
      direction: :column,
      children: convert_children(children),
      gap: parse_int(Map.get(attrs, "data-gap", "0")),
      align: parse_align(Map.get(attrs, "data-align", "start")),
      style: %{},
      id: Map.get(attrs, "id")
    }
  end

  defp convert_component("text", attrs, children) do
    style = decode_style(Map.get(attrs, "data-style", "{}"))
    content = extract_text_content(children)

    %{
      type: :text,
      content: content,
      style: style,
      id: Map.get(attrs, "id")
    }
  end

  defp convert_component("button", attrs, children) do
    content = extract_text_content(children)

    %{
      type: :button,
      text: content,
      style: %{},
      id: Map.get(attrs, "id"),
      on_click: Map.get(attrs, "phx-click"),
      disabled: Map.get(attrs, "disabled") == "true"
    }
  end

  defp convert_component("input", attrs, _children) do
    %{
      type: :text_input,
      value: Map.get(attrs, "value", ""),
      placeholder: Map.get(attrs, "placeholder", ""),
      style: %{},
      id: Map.get(attrs, "id"),
      on_change: Map.get(attrs, "phx-change")
    }
  end

  defp convert_component("progress", attrs, children) do
    content = extract_text_content(children)

    %{
      type: :text,
      content: content,
      style: %{},
      id: Map.get(attrs, "id")
    }
  end

  defp convert_component("divider", attrs, children) do
    content = extract_text_content(children)

    %{
      type: :text,
      content: content,
      style: %{fg: parse_color_attr(Map.get(attrs, "data-color"))},
      id: Map.get(attrs, "id")
    }
  end

  # Unknown component type -- render children as a generic container,
  # or extract text content if it's a leaf element
  defp convert_component(nil, _attrs, children) do
    converted = convert_children(children)

    case converted do
      [] -> nil
      [single] -> single
      multiple -> %{type: :column, children: multiple, style: %{}}
    end
  end

  defp convert_component(_unknown, _attrs, children) do
    convert_component(nil, %{}, children)
  end

  defp convert_children(children) do
    children
    |> Enum.map(&convert_node/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_text_content(children) do
    children
    |> Enum.map_join(" ", fn
      {:text_node, text} -> text
      {:element, _, _, nested} -> extract_text_content(nested)
    end)
    |> String.trim()
  end

  defp decode_style(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp decode_style(_), do: %{}

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: 0

  defp parse_justify("start"), do: :start
  defp parse_justify("center"), do: :center
  defp parse_justify("end"), do: :end_
  defp parse_justify("between"), do: :space_between
  defp parse_justify(_), do: :start

  defp parse_align("start"), do: :start
  defp parse_align("center"), do: :center
  defp parse_align("end"), do: :end_
  defp parse_align(_), do: :start

  defp parse_color_attr(nil), do: :default

  defp parse_color_attr(color) when is_binary(color) do
    String.to_existing_atom(color)
  rescue
    ArgumentError -> :default
  end

  defp parse_color_attr(_), do: :default
end
