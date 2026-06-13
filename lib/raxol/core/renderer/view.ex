defmodule Raxol.Core.Renderer.View do
  @moduledoc """
  Provides view-related functionality for rendering UI components.
  """

  alias Raxol.Core.Renderer.Layout, as: LayoutEngine
  alias Raxol.Core.Renderer.View.Components.{Box, Scroll, Text}
  alias Raxol.Core.Renderer.View.Layout.Flex
  alias Raxol.Core.Renderer.View.Style.Border
  alias Raxol.Core.Renderer.View.Types

  alias Raxol.Core.Renderer.View.{
    Borders,
    Components,
    LayoutHelpers,
    Validation
  }

  @typedoc "Style options for a view."
  @type style :: Types.style()

  @doc """
  Creates a new view with the specified type and options.

  ## Options
    * `:type` - The type of view to create
    * `:position` - Position of the view {x, y}
    * `:z_index` - Z-index for layering
    * `:size` - Size of the view {width, height}
    * `:style` - Style options for the view
    * `:fg` / `:bg` - Foreground / background color
    * `:border` - Border style
    * `:padding` / `:margin` - Spacing
    * `:children` - Child views
    * `:content` - Content for the view
  """
  def new(type, opts \\ []) do
    Validation.validate_view_type(type)
    Validation.validate_view_options(opts)

    defaults = %{
      type: type,
      position: {0, 0},
      z_index: 0,
      size: {0, 0},
      style: %{},
      fg: nil,
      bg: nil,
      border: nil,
      padding: {0, 0, 0, 0},
      margin: {0, 0, 0, 0},
      children: [],
      content: nil
    }

    view = Map.merge(defaults, Map.new(opts))
    Validation.normalize_spacing(view)
  end

  @doc "Creates a new text view."
  def text(content, opts \\ []) do
    Text.new(content, opts)
  end

  @doc "Creates a new box view with padding and optional border."
  def box(opts \\ []) do
    validate_keyword_opts(opts, "View.box")
    Box.new(promote_do_to_children(opts))
  end

  defmacro box(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.box macro"
      )

      children = unquote(block)

      Raxol.Core.Renderer.View.Components.Box.new(
        Keyword.merge(unquote(opts), children: children)
      )
    end
  end

  @doc "Creates a new row layout."
  def row(opts \\ []) do
    validate_keyword_opts(opts, "View.row")
    Flex.row(promote_do_to_children(opts))
  end

  defmacro row(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.row macro"
      )

      Raxol.Core.Renderer.View.Layout.Flex.row(
        Keyword.merge(
          Raxol.Core.Renderer.View.ensure_keyword(unquote(opts)),
          Raxol.Core.Renderer.View.ensure_keyword(children: unquote(block))
        )
      )
    end
  end

  @doc "Creates a new flex container."
  defmacro flex(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.flex macro"
      )

      children = unquote(block)

      Raxol.Core.Renderer.View.Layout.Flex.container(
        Keyword.merge(unquote(opts), children: children)
      )
    end
  end

  @doc "Creates a grid layout."
  defmacro grid(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.grid macro"
      )

      children = unquote(block)

      Raxol.Core.Renderer.View.Layout.Grid.new(
        Keyword.merge(
          Raxol.Core.Renderer.View.ensure_keyword(unquote(opts)),
          Raxol.Core.Renderer.View.ensure_keyword(children: children)
        )
      )
    end
  end

  defmacro grid(opts) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.grid macro"
      )

      Raxol.Core.Renderer.View.Layout.Grid.new(unquote(opts))
    end
  end

  @doc "Creates a new border around a view."
  def border(view, opts \\ []) do
    validate_keyword_opts(opts, "View.border")
    Border.wrap(view, opts)
  end

  @doc "Creates a new scrollable view."
  def scroll(view, opts \\ []) do
    validate_keyword_opts(opts, "View.scroll")
    Scroll.new(view, opts)
  end

  @doc "Creates a table view."
  def table(opts \\ []) do
    validate_keyword_opts(opts, "View.table")
    Components.table(opts)
  end

  @doc """
  Applies layout to a view, calculating absolute positions for all elements.
  Delegates to Raxol.Renderer.Layout.apply_layout/2.
  """
  def layout(view, dimensions) do
    Validation.validate_layout_dimensions(dimensions)
    LayoutEngine.apply_layout(view, Map.new(dimensions))
  end

  defmacro border_wrap(style, do: block) do
    quote do
      opts = [style: unquote(style)]

      Raxol.Core.Renderer.View.validate_keyword_opts(
        opts,
        "View.border_wrap macro"
      )

      Raxol.Core.Renderer.View.Style.Border.wrap(unquote(block), opts)
    end
  end

  defmacro border(style, opts, do: block) do
    quote do
      all_opts =
        Keyword.merge(
          Raxol.Core.Renderer.View.ensure_keyword(unquote(opts)),
          Raxol.Core.Renderer.View.ensure_keyword(style: unquote(style))
        )

      Raxol.Core.Renderer.View.Style.Border.wrap(unquote(block), all_opts)
    end
  end

  defmacro scroll_wrap(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.scroll_wrap macro"
      )

      Raxol.Core.Renderer.View.Components.Scroll.new(
        unquote(block),
        unquote(opts)
      )
    end
  end

  @doc "Wraps a view with a border, optionally with a title and style."
  def wrap_with_border(view, opts \\ []) do
    Borders.wrap_with_border(view, opts)
  end

  @doc "Wraps a view with a block-style border."
  def block_border(view, opts \\ []), do: Borders.block_border(view, opts)

  @doc "Wraps a view with a double-line border."
  def double_border(view, opts \\ []), do: Borders.double_border(view, opts)

  @doc "Wraps a view with a rounded border."
  def rounded_border(view, opts \\ []), do: Borders.rounded_border(view, opts)

  @doc "Wraps a view with a bold border."
  def bold_border(view, opts \\ []), do: Borders.bold_border(view, opts)

  @doc "Wraps a view with a simple border."
  def simple_border(view, opts \\ []), do: Borders.simple_border(view, opts)

  @doc "Creates a new panel view (box with border and children)."
  def panel(opts \\ []) do
    LayoutHelpers.panel(opts)
  end

  @doc "Creates a new column layout."
  def column(opts) do
    Raxol.Core.Renderer.View.Layout.Flex.column(promote_do_to_children(opts))
  end

  @doc """
  Routes an inline `do:` keyword to `:children` so that callers can write
  `column(style: ..., do: child_list)` and have the children flow through
  the runtime function path the same way `column do ... end` flows through
  the macro path.

  Without this, Elixir parses `column(style: ..., do: child_list)` as a
  single-arg call with a kwlist, matches `def column/1`, and the
  downstream layout function never sees the children — silently rendering
  an empty container. The dynamic-children bug that broke 10+ playground
  demos at once.
  """
  def promote_do_to_children(opts) when is_list(opts) do
    case Keyword.pop(opts, :do) do
      {nil, opts} -> opts
      {block, opts} -> Keyword.put_new(opts, :children, List.wrap(block))
    end
  end

  def promote_do_to_children(opts), do: opts

  defmacro column(opts, do: block) do
    quote do
      Raxol.Core.Renderer.View.validate_keyword_opts(
        unquote(opts),
        "View.column macro"
      )

      Raxol.Core.Renderer.View.Layout.Flex.column(
        Keyword.merge(
          Raxol.Core.Renderer.View.ensure_keyword(unquote(opts)),
          Raxol.Core.Renderer.View.ensure_keyword(children: unquote(block))
        )
      )
    end
  end

  @doc "Creates a split pane layout."
  defmacro split(direction, opts, do: block) do
    quote do
      Raxol.UI.Layout.SplitPane.new(
        direction: unquote(direction),
        ratio: Keyword.get(unquote(opts), :ratio, {1, 1}),
        min_size: Keyword.get(unquote(opts), :min_size, 5),
        id: Keyword.get(unquote(opts), :id),
        children: unquote(block)
      )
    end
  end

  defmacro split(direction, do: block) do
    quote do
      Raxol.UI.Layout.SplitPane.new(
        direction: unquote(direction),
        children: unquote(block)
      )
    end
  end

  @doc "Creates a split pane from a named preset."
  defmacro split_layout(preset, do: block) do
    quote do
      Raxol.UI.Layout.SplitPane.from_preset(unquote(preset), unquote(block))
    end
  end

  defdelegate split_pane(opts \\ []), to: Raxol.UI.Layout.SplitPane, as: :new

  @doc "Creates a button element."
  def button(text, opts \\ []) do
    Components.button(text, opts)
  end

  @doc "Creates a checkbox element."
  def checkbox(label, opts \\ []) do
    Components.checkbox(label, opts)
  end

  @doc "Creates a text input element."
  def text_input(opts \\ []) do
    Components.text_input(opts)
  end

  @doc "Renders a view with the given options."
  defmacro view(opts, do: block) do
    quote do
      rendered_view = unquote(block)

      rendered_view
      |> Map.merge(Map.new(unquote(opts)))
      |> Raxol.Core.Renderer.View.do_normalize_spacing()
    end
  end

  @doc false
  def do_normalize_spacing(view) do
    Validation.normalize_spacing(view)
  end

  @doc "Creates a simple box element with the given options."
  def box_element(opts \\ []) do
    Components.box_element(opts)
  end

  @doc "Calculates flex layout dimensions based on the given constraints."
  @spec flex(map()) :: %{width: integer(), height: integer()}
  def flex(constraints) do
    LayoutHelpers.flex(constraints)
  end

  @doc "Creates a shadow effect for a view."
  def shadow(opts \\ []) do
    Components.shadow(opts)
  end

  @doc "Creates a process-isolated component node."
  def process_component(module, props \\ %{}) do
    Components.process_component(module, props)
  end

  # Delegate unique Components functions so View is the single complete DSL.
  defdelegate label(opts \\ []), to: Raxol.View.Components
  defdelegate input(opts \\ []), to: Raxol.View.Components
  defdelegate list(opts \\ []), to: Raxol.View.Components
  defdelegate spacer(opts \\ []), to: Raxol.View.Components
  defdelegate divider(opts \\ []), to: Raxol.View.Components
  defdelegate image(opts \\ []), to: Raxol.View.Components
  defdelegate progress(opts \\ []), to: Raxol.View.Components
  defdelegate modal(opts \\ []), to: Raxol.View.Components
  defdelegate select(opts \\ []), to: Raxol.View.Components
  defdelegate radio_group(opts \\ []), to: Raxol.View.Components
  defdelegate textarea(opts \\ []), to: Raxol.View.Components
  defdelegate container(opts \\ []), to: Raxol.View.Components
  defdelegate tabs(opts \\ []), to: Raxol.View.Components
  defdelegate span(content, opts \\ []), to: Raxol.View.Components

  # Chart components
  defdelegate line_chart(opts \\ []), to: Raxol.View.Components
  defdelegate bar_chart(opts \\ []), to: Raxol.View.Components
  defdelegate scatter_chart(opts \\ []), to: Raxol.View.Components
  defdelegate heatmap(opts \\ []), to: Raxol.View.Components
  defdelegate sparkline(opts \\ []), to: Raxol.View.Components

  # Helper functions for keyword validation (public for macro usage)

  def validate_keyword_opts(opts, function_name) do
    Validation.validate_keyword_opts(opts, function_name)
  end

  def ensure_keyword_list(opts), do: Validation.ensure_keyword_list(opts)

  defmacro ensure_keyword(opts) do
    quote do
      case unquote(opts) do
        opts when is_list(opts) and opts != [] ->
          Raxol.Core.Renderer.View.ensure_keyword_list(opts)

        _opts ->
          []
      end
    end
  end
end
