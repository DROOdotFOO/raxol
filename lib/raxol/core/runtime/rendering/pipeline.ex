defmodule Raxol.Core.Runtime.Rendering.Pipeline do
  @moduledoc """
  Pure frame stages shared by `Raxol.Core.Runtime.Rendering.Engine` and
  `Raxol.Scoreboard`, so the scoreboard measures the stages the engine runs
  rather than a copy of them.

  The engine's remaining per-frame steps are either runtime plumbing (fetching
  the model and view from the dispatcher, plugin transforms supplied by the
  dispatcher's plugin manager) or the backend write, whose terminal half is
  `Raxol.Core.Runtime.Rendering.Backends.terminal_frame/2`.
  """

  alias Raxol.UI.Theming.Theme

  @doc """
  The theme a frame renders with. The dispatcher's theme id is the default
  unless the app (a model `:current_theme_id`) or the user's preferences chose
  another. The default renders `Theme.current/0`, the theme
  `Raxol.set_theme/1` sets; a chosen id renders the theme registered under it,
  or `Theme.current/0` if none is.
  """
  @spec theme(atom() | String.t() | nil) :: map()
  def theme(theme_id) do
    if theme_id in [nil, Theme.default_theme_id()] do
      Theme.current()
    else
      Enum.find(Theme.list_themes(), Theme.current(), &(&1.id == theme_id))
    end
  end

  @doc """
  Applies the border-beam animation hints carried by positioned elements to
  the rendered cells. Returns the cells unchanged when no element carries a
  `:border_beam` hint, or when applying them fails: a decorative effect must
  not cost the frame.
  """
  @spec apply_border_beam(list(), list()) :: list()
  def apply_border_beam(cells, positioned_elements) do
    case collect_border_beam_hints(positioned_elements) do
      [] ->
        cells

      hints ->
        Raxol.Core.ErrorHandling.safe_call(fn ->
          Raxol.Effects.BorderBeam.CellApplier.apply_hints(cells, hints)
        end)
        |> case do
          {:ok, beamed} -> beamed
          {:error, _reason} -> cells
        end
    end
  end

  defp collect_border_beam_hints(elements) when is_list(elements) do
    Enum.flat_map(elements, &border_beam_hints_for/1)
  end

  defp border_beam_hints_for(%{
         animation_hints: hints,
         x: x,
         y: y,
         width: w,
         height: h
       })
       when is_list(hints) and is_integer(x) and is_integer(y) and w > 0 and
              h > 0 do
    bounds = %{x: x, y: y, width: w, height: h}

    hints
    |> Enum.filter(&match?(%{type: :border_beam}, &1))
    |> Enum.map(&{&1, bounds})
  end

  defp border_beam_hints_for(_), do: []
end
