defmodule Raxol.Effects.BorderBeam.CellApplier do
  @moduledoc """
  Dispatches BorderBeam animation hints to the effect implementation
  selected by `opts[:type]` and applies the result to a flat cell list.

  Effects share the contract in `Raxol.Effects.BorderBeam.Effect` and
  live under `Raxol.Effects.BorderBeam.Effects.*`. Built-in types:

      :stroke   (default) -- comet sweeping the perimeter
      :pulse              -- whole border breathing in unison
      :flames             -- flickering chars climbing the bottom edge
      :electric           -- random sparks at perimeter positions
      :clouds             -- soft slow drift of low-contrast color

  Animation progress is derived from monotonic time so frames stay smooth
  regardless of tick cadence. Activated by the rendering engine when a
  positioned element carries an animation hint of `type: :border_beam`.
  Last-write-wins on cells when multiple hints overlap.
  """

  alias Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.Effects.{
    Clouds,
    Electric,
    Flames,
    Pulse,
    Stroke
  }

  @type cell ::
          {non_neg_integer(), non_neg_integer(), String.t(), any(), any(),
           list()}
  @type bounds :: Effect.bounds()
  @type hint :: %{required(:type) => :border_beam, optional(atom()) => any()}

  @doc """
  Applies a list of `{hint, bounds}` to the cell list. No-op for empty list.
  """
  @spec apply_hints([cell()], [{hint(), bounds()}]) :: [cell()]
  def apply_hints(cells, []), do: cells

  def apply_hints(cells, hints_with_bounds) do
    case Enum.filter(hints_with_bounds, &active?/1) do
      [] ->
        cells

      active ->
        cell_index =
          Map.new(cells, fn {x, y, _, _, _, _} = c -> {{x, y}, c} end)

        active
        |> Enum.reduce(cell_index, fn {hint, bounds}, acc ->
          apply_one(acc, hint, bounds)
        end)
        |> Map.values()
    end
  end

  defp active?({hint, %{width: w, height: h}}) when w >= 4 and h >= 4 do
    Map.get(hint, :active, true)
  end

  defp active?(_), do: false

  defp apply_one(cells, hint, bounds) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(hint, :effect, :stroke) do
      :stroke -> Stroke.apply(cells, bounds, hint, now_ms)
      :pulse -> Pulse.apply(cells, bounds, hint, now_ms)
      :flames -> Flames.apply(cells, bounds, hint, now_ms)
      :electric -> Electric.apply(cells, bounds, hint, now_ms)
      :clouds -> Clouds.apply(cells, bounds, hint, now_ms)
      _ -> cells
    end
  end
end
