defmodule Raxol.UI.Harness.OverlayPicker do
  @moduledoc """
  Pure footer-region overlay picker primitive: a filterable list rendered
  as a fixed-height block of `Raxol.Harness.Surface.ViewText`-shaped view
  maps, driven entirely by `Raxol.UI.Harness.InputEvent`-normalized
  events. No process, no I/O, no device -- state is a plain map (matching
  `Raxol.Harness.Surface`'s own plain-map style, not a struct), and every
  function here is `(t(), ...) -> t() | result`.

  This is the host-agnostic core the harness's footer viewport grows to
  accommodate (see `Raxol.Harness.Surface.open_overlay/3` and
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority.set_footer_rows/2`):
  a query row plus a scrollable window of matches, anchored above the
  composer, never a centered modal over history.

  ## `Raxol.UI.Components.Harness.Picker` vs. this module

  `Raxol.UI.Components.Harness.Picker` is the Component-tree variant:
  fuzzy-ranked matching with an inline preview, mounted through the
  normal `Preparer -> LayoutEngine -> UIRenderer` pipeline, awaiting a
  Component host. This module is the answer for the OTHER substrate --
  the byte-level, pinned-footer-viewport rendering path
  (`InlineAuthority`/`FlatAuthority`) that has no Component tree to mount
  anything into at all. The two are siblings serving different hosts,
  not a migration of one into the other.

  ## `filter_fn` is the fuzzy seam

  `filter_fn` (arity 3: `(query, items, label_fn) -> [item]`) is exactly
  where a future fuzzy ranker -- the same kind of scorer
  `Raxol.UI.Components.Harness.Picker` already uses for its own matching
  -- drops in without touching `handle_key/2`'s dispatch at all: swap the
  option, keep every keystroke/selection/render mechanism unchanged. The
  default is deliberately simple and honest about it: case-insensitive
  substring matching (`label_fn.(item)` downcased, `query` downcased,
  `String.contains?/2`), substring-first rather than fuzzy-first, because
  a wrong ranking in a filterable list is a worse failure than a merely
  literal one.

  ## Fixed claimed height -- no per-keystroke footer re-pin

  `height/1` is computed from the FULL `items` list, never the current
  `matches/1` result: `1 + min(max(length(items), 1), max_visible)`. This
  is deliberate -- the footer viewport this picker is hosted inside
  (`Surface.open_overlay/3`) grows the DECSTBM split ONCE, at open, to
  fit this claimed height. If height instead tracked the live match
  count, every keystroke that narrowed (or widened) the result set would
  have to re-pin the terminal's scroll region mid-interaction -- a
  visible flicker, and a much harder invariant to keep honest under
  `InlineAuthority`'s seal-time-only history contract. A picker that
  claims its full potential height up front, then pads unused rows with
  blank lines, costs a few empty footer rows in exchange for zero
  re-pinning churn.

  ## State shape

      %{
        items: [term()],
        label_fn: (term() -> String.t()),
        filter_fn: (String.t(), [term()], (term() -> String.t()) -> [term()]),
        query: String.t(),
        selected: non_neg_integer(),
        offset: non_neg_integer(),
        max_visible: pos_integer(),
        title: String.t() | nil
      }

  ## Rendering: text leaves only, exactly `height/1` of them

  `render/1` returns a `%{type: :column, children: [...]}` view map whose
  children are ALWAYS exactly `height(t)` `%{type: :text}` leaves: one
  query row, then `height(t) - 1` item rows (padded with blank leaves
  when there are fewer matches than that). This is the row-accounting
  contract `Raxol.Harness.Surface`'s footer budget depends on --
  `ViewText.lines/3` never needs to guess how many physical rows this
  picker's view map produces, because it is fixed by construction. No
  width truncation happens here: `ViewText.lines/3` is the one trust
  boundary that owns display-width truncation and control-byte
  sanitization (see that module's moduledoc), so this module hands it
  full, untruncated content.

  Every item label passes through a newline-flatten
  (`String.replace(label, ["\\r\\n", "\\n", "\\r"], " ")`) before
  rendering: `ViewText.lines/3` splits a `:text` leaf's content on
  embedded newlines into MULTIPLE collected lines (its own trust-boundary
  contract, "one row-accounting bug turned into the multiple rows it
  actually is") -- correct for arbitrary content, but wrong for a picker
  row, where one item must always be one footer row or the fixed
  `height/1` budget silently overflows into padding rows nobody asked
  for. Flattening here, before that split ever runs, keeps one item ==
  one row true regardless of what a label contains.
  """

  alias Raxol.UI.Harness.InputEvent

  @type item :: term()
  @type label_fn :: (item() -> String.t())
  @type filter_fn :: (String.t(), [item()], label_fn() -> [item()])

  @type t :: %{
          items: [item()],
          label_fn: label_fn(),
          filter_fn: filter_fn(),
          query: String.t(),
          selected: non_neg_integer(),
          offset: non_neg_integer(),
          max_visible: pos_integer(),
          title: String.t() | nil
        }

  @default_max_visible 8

  @doc """
  The default `:max_visible` item-row cap `new/2` uses. Exposed so hosts
  (`Raxol.Harness.Surface.open_overlay/3`) clamp against THIS value
  rather than re-encoding the literal -- one source of truth.
  """
  @spec default_max_visible() :: pos_integer()
  def default_max_visible, do: @default_max_visible

  @doc """
  Builds a fresh picker over `items`.

  ## Options

    * `:label_fn` (default `&to_string/1`) -- derives the search key (and
      the rendered label) for a non-string item.
    * `:max_visible` (default #{@default_max_visible}) -- the cap on item
      rows (excluding the query row) `height/1` claims.
    * `:title` (default `nil`) -- prefixed to the query row when present.
    * `:filter_fn` (default case-insensitive substring, see moduledoc) --
      the fuzzy seam.
  """
  @spec new([item()], keyword()) :: t()
  def new(items, opts \\ []) when is_list(items) do
    %{
      items: items,
      label_fn: Keyword.get(opts, :label_fn, &to_string/1),
      filter_fn: Keyword.get(opts, :filter_fn, &default_filter/3),
      query: "",
      selected: 0,
      offset: 0,
      max_visible: Keyword.get(opts, :max_visible, @default_max_visible),
      title: Keyword.get(opts, :title)
    }
  end

  @doc "The current query's matches -- `filter_fn` applied to `items`."
  @spec matches(t()) :: [item()]
  def matches(%{
        filter_fn: filter_fn,
        query: query,
        items: items,
        label_fn: label_fn
      }),
      do: filter_fn.(query, items, label_fn)

  @doc """
  The rows this overlay claims -- fixed at construction over the FULL
  item list, never the current filtered match count (see moduledoc, "no
  per-keystroke footer re-pin").
  """
  @spec height(t()) :: pos_integer()
  def height(%{items: items, max_visible: max_visible}) do
    1 + min(max(length(items), 1), max_visible)
  end

  @doc """
  Handles one normalized `InputEvent.t()`. Returns `{:continue, t()}` to
  keep the overlay open with updated state, `{:picked, item}` when Enter
  committed a selection, or `:dismissed` when ESC was handled directly
  (host-agnostic -- in the assembled harness surface, the Keymap's
  `:overlay` guard captures ESC before it ever reaches this function; see
  `Raxol.UI.Harness.Keymap`).
  """
  @spec handle_key(t(), InputEvent.t()) ::
          {:continue, t()} | {:picked, item()} | :dismissed
  def handle_key(t, norm) do
    case InputEvent.printable_char(norm) do
      char when is_binary(char) -> {:continue, insert_char(t, char)}
      nil -> handle_special_key(t, norm)
    end
  end

  defp handle_special_key(t, norm) do
    case InputEvent.key(norm) do
      :backspace -> {:continue, backspace(t)}
      :up -> {:continue, move_selection(t, -1)}
      :down -> {:continue, move_selection(t, 1)}
      :enter -> commit(t)
      :escape -> :dismissed
      _other -> handle_paste_or_noop(t, norm)
    end
  end

  defp handle_paste_or_noop(t, %{kind: :paste, text: text})
       when is_binary(text) and text != "" do
    {:continue, append_paste(t, text)}
  end

  defp handle_paste_or_noop(t, _norm), do: {:continue, t}

  defp insert_char(t, char) do
    %{t | query: t.query <> char, selected: 0, offset: 0}
  end

  defp backspace(t) do
    new_query =
      t.query
      |> String.graphemes()
      |> Enum.drop(-1)
      |> Enum.join("")

    %{t | query: new_query, selected: 0, offset: 0}
  end

  defp append_paste(t, text) do
    cleaned = flatten_newlines(text)
    %{t | query: t.query <> cleaned, selected: 0, offset: 0}
  end

  defp move_selection(t, delta) do
    match_count = t |> matches() |> length()
    max_index = max(match_count - 1, 0)
    new_selected = (t.selected + delta) |> max(0) |> min(max_index)

    win = max(height(t) - 1, 0)

    new_offset =
      t.offset
      |> min(new_selected)
      |> max(new_selected - win + 1)
      |> max(0)

    %{t | selected: new_selected, offset: new_offset}
  end

  defp commit(t) do
    case matches(t) do
      [] -> {:continue, t}
      matches -> {:picked, Enum.at(matches, t.selected)}
    end
  end

  @doc """
  Renders the fixed-height view map (see moduledoc, "Rendering"): one
  query-row leaf followed by exactly `height(t) - 1` item-row leaves.
  """
  @spec render(t()) :: map()
  def render(t) do
    item_row_count = max(height(t) - 1, 0)

    item_pairs =
      t
      |> matches()
      |> item_content_pairs(t, item_row_count)
      |> pad_pairs(item_row_count)

    query_row = %{
      type: :text,
      content: query_content(t),
      style: %{bold: true}
    }

    item_rows =
      Enum.map(item_pairs, fn {content, style} ->
        %{type: :text, content: content, style: style}
      end)

    %{type: :column, children: [query_row | item_rows]}
  end

  defp item_content_pairs([], _t, _item_row_count) do
    [{"  (no matches)", %{dim: true}}]
  end

  defp item_content_pairs(matches, t, item_row_count) do
    matches
    |> Enum.slice(t.offset, item_row_count)
    |> Enum.with_index(t.offset)
    |> Enum.map(fn {item, index} ->
      label = flatten_newlines(t.label_fn.(item))

      if index == t.selected do
        {"▸ " <> label, %{bold: true}}
      else
        {"  " <> label, %{}}
      end
    end)
  end

  defp pad_pairs(pairs, count) do
    kept = Enum.take(pairs, count)
    kept ++ List.duplicate({"", %{}}, max(count - length(kept), 0))
  end

  defp query_content(%{title: nil, query: query}), do: "› " <> query

  defp query_content(%{title: title, query: query}),
    do: title <> " › " <> query

  defp flatten_newlines(text),
    do: String.replace(text, ["\r\n", "\n", "\r"], " ")

  defp default_filter(query, items, label_fn) do
    if query == "" do
      items
    else
      downcased_query = String.downcase(query)

      Enum.filter(items, fn item ->
        item
        |> label_fn.()
        |> String.downcase()
        |> String.contains?(downcased_query)
      end)
    end
  end
end
