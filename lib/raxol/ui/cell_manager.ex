defmodule Raxol.UI.CellManager do
  @moduledoc """
  Handles cell operations, clipping, merging, and coordinate management.
  """

  @doc """
  Filters out cells with invalid coordinates.
  """
  def filter_valid_cells(cells) do
    Enum.filter(cells, fn {x, y, _char, _fg, _bg, _attrs} ->
      # Filter out cells with negative or invalid coordinates
      x >= 0 and y >= 0
    end)
  end

  @doc """
  Clips cells to specified bounds.
  """
  def clip_cells_to_bounds(cells, nil), do: cells

  def clip_cells_to_bounds(cells, {min_x, min_y, max_x, max_y}) do
    Enum.filter(cells, fn {x, y, _char, _fg, _bg, _attrs} ->
      x >= min_x and x <= max_x and y >= min_y and y <= max_y
    end)
  end

  @doc """
  Merges two cell lists, with the second list taking precedence at overlapping coordinates.
  """
  def merge_cells(base_cells, overlay_cells) do
    base_cells
    |> build_cell_map()
    |> overlay_cells(overlay_cells)
    |> Map.values()
  end

  @doc """
  Clips coordinates to valid bounds.
  """
  def clip_coordinates(x, y, width, height) do
    {max(0, x), max(0, y), max(0, width), max(0, height)}
  end

  defdelegate ensure_list(value), to: Raxol.Core.Utils.List

  # Helper to build a map of cells by coordinate
  defp build_cell_map(cells) do
    Enum.reduce(cells, %{}, &put_cell/2)
  end

  # Helper to overlay cells onto a cell map
  defp overlay_cells(cell_map, overlay_cells) do
    Enum.reduce(overlay_cells, cell_map, &put_cell/2)
  end

  # Cells do not composite -- the last writer wins -- so a cell written with an
  # unpainted background would ERASE the background already beneath it, punching
  # a hole through a filled parent (a button on a modal showing the desktop). An
  # unpainted background means "show what is beneath", so it inherits the
  # background already at that coordinate rather than clearing it. At the top
  # there is nothing beneath, so it stays nil and the terminal shows through.
  defp put_cell({x, y, c, fg, bg, attrs}, acc) do
    bg = if is_nil(bg), do: background_at(acc, {x, y}), else: bg
    Map.put(acc, {x, y}, {x, y, c, fg, bg, attrs})
  end

  defp background_at(acc, key) do
    case Map.get(acc, key) do
      {_x, _y, _c, _fg, bg, _attrs} -> bg
      _ -> nil
    end
  end
end
