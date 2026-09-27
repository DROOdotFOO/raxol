defmodule Raxol.Core.Renderer.View.LayoutHelpers do
  @moduledoc """
  Layout helper functions for the View module.
  Extracted from the main View module to improve maintainability.
  """

  @doc """
  Calculates flex layout dimensions based on the given constraints.
  Returns a map with calculated width and height.
  """
  @spec flex(map()) :: %{width: integer(), height: integer()}
  def flex(constraints) do
    %{
      width: calculate_flex_width(constraints),
      height: calculate_flex_height(constraints)
    }
  end

  @doc """
  Creates a new panel view (box with border and children).

  ## Options
    * `:children` - Child views
    * `:border` - Border style (default: :single)
    * `:padding` - Padding inside the panel (default: 1)
    * `:style` - Additional style options
    * `:title` - Optional title for the panel
    * `:fg` - Foreground color
    * `:bg` - Background color

  ## Examples
      LayoutHelpers.panel(children: [View.text("Hello")])
      LayoutHelpers.panel(border: :double, title: "Panel")

  NOTE: Only panel/1 (with a keyword list) is supported. Update any panel/2 usages to panel/1.
  """
  def panel(opts \\ []) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "LayoutHelpers.panel macro expects a keyword list as the first argument, got: #{inspect(opts)}"
    end

    opts
    |> build_panel_opts()
    |> Raxol.Core.Renderer.View.box()
  end

  defp build_panel_opts(opts) do
    base = [
      border: Keyword.get(opts, :border, :single),
      padding: Keyword.get(opts, :padding, 1),
      children: Keyword.get(opts, :children, []),
      fg: Keyword.get(opts, :fg),
      bg: Keyword.get(opts, :bg)
    ]

    base
    |> maybe_add_panel_opt(:title, Keyword.get(opts, :title))
    |> maybe_add_panel_opt(:style, Keyword.get(opts, :style))
    |> maybe_add_panel_opt(:border_beam, Keyword.get(opts, :border_beam))
    |> maybe_add_panel_opt(
      :border_beam_opts,
      Keyword.get(opts, :border_beam_opts)
    )
  end

  defp maybe_add_panel_opt(opts, _key, nil), do: opts
  defp maybe_add_panel_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Private helper functions

  @spec calculate_flex_width(any()) :: any()
  defp calculate_flex_width(constraints) do
    case constraints do
      %{width: :auto, flex: flex} when flex > 0 ->
        # Calculate width based on flex grow
        trunc(constraints.available_width * (flex / constraints.total_flex))

      %{width: width} when is_integer(width) ->
        # Fixed width
        width

      _ ->
        # Default to available width
        constraints.available_width
    end
  end

  @spec calculate_flex_height(any()) :: any()
  defp calculate_flex_height(constraints) do
    case constraints do
      %{height: :auto, flex: flex} when flex > 0 ->
        # Calculate height based on flex grow
        trunc(constraints.available_height * (flex / constraints.total_flex))

      %{height: height} when is_integer(height) ->
        # Fixed height
        height

      _ ->
        # Default to available height
        constraints.available_height
    end
  end
end
