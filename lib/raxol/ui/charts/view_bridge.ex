defmodule Raxol.UI.Charts.ViewBridge do
  @moduledoc """
  Converts chart cell tuples to View DSL elements for use in TEA `view/1`.

  Groups consecutive same-color cells on the same row into text runs,
  then wraps them as `Raxol.View.Components` elements.
  """

  alias Raxol.View.Components

  @type cell :: Raxol.UI.Charts.ChartUtils.cell()

  @doc """
  Converts a list of cell tuples to a View DSL box element.

  Groups cells by row and color into text components, wrapped in a box.
  """
  @spec cells_to_view([cell()], keyword()) :: map()
  def cells_to_view(cells, opts \\ [])

  def cells_to_view([], opts) do
    Components.box(style: Keyword.get(opts, :style, %{}), children: [])
  end

  def cells_to_view(cells, opts) do
    children =
      cells
      |> Enum.sort_by(fn {x, y, _, _, _, _} -> {y, x} end)
      |> Enum.chunk_by(fn {_x, y, _c, fg, bg, _a} -> {y, fg, bg} end)
      |> Enum.flat_map(&split_non_adjacent/1)
      |> Enum.map(&group_to_text_element/1)

    Components.box(style: Keyword.get(opts, :style, %{}), children: children)
  end

  # a same-row same-color chunk may have gaps (bar spacing); joining across
  # one would melt separate bars into a single run
  defp split_non_adjacent(group) do
    group
    |> Enum.chunk_while(
      [],
      fn {x, _y, _c, _fg, _bg, _a} = cell, acc ->
        case acc do
          [] ->
            {:cont, [cell]}

          [{prev_x, _, _, _, _, _} | _] when x == prev_x + 1 ->
            {:cont, [cell | acc]}

          _ ->
            {:cont, Enum.reverse(acc), [cell]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp group_to_text_element(group) do
    [{_x0, y0, _c0, fg, bg, _a0} | _] = group

    x_start =
      group |> Enum.map(fn {x, _, _, _, _, _} -> x end) |> Enum.min()

    content = Enum.map_join(group, fn {_x, _y, c, _fg, _bg, _a} -> c end)

    %{content: content, fg: fg}
    |> maybe_put_bg(bg)
    |> Map.put(:style, %{position: {x_start, y0}})
    |> Components.text()
  end

  defp maybe_put_bg(opts, :default), do: opts
  defp maybe_put_bg(opts, bg), do: Map.put(opts, :bg, bg)

  @doc """
  Convenience wrapper: calls a chart function with args, then converts
  the resulting cells to a View DSL element.

  ## Example

      ViewBridge.chart_box(&LineChart.render/3, [{0, 0, 40, 10}, series, []], style: %{})
  """
  @spec chart_box(function(), [term()], keyword()) :: map()
  def chart_box(chart_fn, chart_args, box_opts \\ []) do
    cells = apply(chart_fn, chart_args)
    cells_to_view(cells, box_opts)
  end
end
