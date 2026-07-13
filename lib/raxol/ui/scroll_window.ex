defmodule Raxol.UI.ScrollWindow do
  @moduledoc """
  Pure cursor-follow scroll windowing for vertical selection lists.

  Keeps the cursor inside a fixed-height visible window: when the cursor
  would step outside the window, `scroll_top` moves by exactly the amount
  needed to bring it back in, so the item under the cursor lands on the
  same screen row it approached the edge from (edge-anchored scrolling,
  not page-jump scrolling). Also derives a proportional scrollbar thumb
  position/size for the windowed content, `nil` when everything fits.

  Consumers own `scroll_top` as persistent state (e.g. in a TEA model)
  and thread it back in as `prev_scroll_top` on the next call -- this
  function never mutates anything, it only computes the next frame.
  """

  alias Raxol.Core.Utils.Math

  @type thumb :: {start_row :: non_neg_integer(), size :: pos_integer()}

  @type t :: %{
          visible: list(),
          scroll_top: non_neg_integer(),
          cursor_row: non_neg_integer(),
          overflown?: boolean(),
          thumb: thumb() | nil
        }

  @doc """
  Windows `items` around `cursor`, given a `visible_height` row budget and
  the previous `scroll_top` (for edge-anchored continuity).

  `cursor` is clamped to `items`' bounds. `scroll_top` is clamped so the
  window never runs past either end of `items`, regardless of what
  `prev_scroll_top` was (stale or out-of-range inputs self-heal).

  ## Examples

      iex> w = Raxol.UI.ScrollWindow.window(Enum.to_list(1..20), 0, 10, 0)
      iex> w.scroll_top
      0
      iex> w.cursor_row
      0

      iex> # cursor steps onto the last visible row -> window scrolls by 1,
      iex> # cursor stays pinned to the same screen row
      iex> w = Raxol.UI.ScrollWindow.window(Enum.to_list(1..20), 10, 10, 0)
      iex> {w.scroll_top, w.cursor_row}
      {1, 9}
  """
  @spec window(list(), integer(), pos_integer(), integer()) :: t()
  def window(items, cursor, visible_height, prev_scroll_top) do
    total = length(items)
    visible_height = max(visible_height, 1)
    max_index = max(total - 1, 0)
    cursor = Math.clamp(cursor, 0, max_index)
    max_scroll = max(total - visible_height, 0)

    scroll_top =
      cursor
      |> Math.scroll_into_view(prev_scroll_top, visible_height)
      |> Math.clamp(0, max_scroll)

    %{
      visible: Enum.slice(items, scroll_top, visible_height),
      scroll_top: scroll_top,
      cursor_row: cursor - scroll_top,
      overflown?: total > visible_height,
      thumb: thumb(scroll_top, visible_height, total)
    }
  end

  @doc """
  Proportional scrollbar thumb `{start_row, size}` for `total` rows of
  content in a `visible_height`-row track scrolled to `scroll_top`.
  `nil` when content fits without scrolling (nothing to indicate).
  """
  @spec thumb(non_neg_integer(), pos_integer(), non_neg_integer()) ::
          thumb() | nil
  def thumb(_scroll_top, visible_height, total) when total <= visible_height,
    do: nil

  def thumb(scroll_top, visible_height, total) do
    thumb_size = max(1, div(visible_height * visible_height, total))
    max_scroll = max(total - visible_height, 0)

    thumb_start =
      if max_scroll > 0 do
        div(scroll_top * (visible_height - thumb_size), max_scroll)
      else
        0
      end

    {thumb_start, thumb_size}
  end
end
