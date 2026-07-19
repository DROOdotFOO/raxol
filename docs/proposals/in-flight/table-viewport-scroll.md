# Table viewport scroll — windowed body + selection autoscroll

Status: **draft / design** · Date: 2026-07-19 · Owner: design agent  
Parent: Table UX parity with playground sidebar / SelectList  
Depends on: `Raxol.UI.ScrollWindow` (shipped), concurrent Table border work (`border: :grid | :inner | :none`, `header_separator`) — **compose, do not re-implement**  
Non-goals of this doc: implementing `lib/raxol/ui/components/table.ex` (follow-up PR)

Spine decision: **activate the dead `scroll_top` field with `ScrollWindow.window/4`, keep pagination as an outer data slice, and fix `selected_row` to mean “index into the effective (filtered+sorted) list.”** Do not nest `Display.Viewport` inside Table.

---

## 1. Problem / current state

### What Table already has

[`lib/raxol/ui/components/table.ex`](../../../lib/raxol/ui/components/table.ex):

| Capability | State / options | Behavior today |
|---|---|---|
| Columns / rows | `columns`, `data` | Full render of the post-pipeline slice |
| Filter | `filter_term`, `options.searchable` | Resets `current_page` and `scroll_top` |
| Sort | `sort_by`, `sort_direction`, `options.sortable` | Reorders full list |
| Pagination | `options.paginate`, `page_size`, `current_page` | `paginate_data/3` slices before paint |
| Selection | `selected_row` | Arrow / home / end / page keys; `nil` initial |
| Dead scroll | `scroll_top: 0` | Set on filter / page change **only**; never read in render or selection |
| MCP | `select_row`, `get_rows`, `sort` | No scroll tools |
| Demo | [`lib/raxol/playground/demos/table_demo.ex`](../../../lib/raxol/playground/demos/table_demo.ex) | Seeds `selected_row: 0` to avoid nil crash |

Render pipeline today:

```
data → filter → sort → paginate_data(page, page_size) → create_header + create_rows(all of slice)
```

There is no body height budget. A 10k-row table with `paginate: false` paints 10k flex rows and hopes the terminal scrollback is enough. That is wrong for a focused component inside a fixed terminal frame.

### Known warts (in scope to fix or formalize)

1. **`selected_row` nil + arithmetic.**  
   `handle_event({:key, {:arrow_down, _}}, …)` does `state.selected_row + 1` with no nil guard. Demo seeds `0`. Design: first navigation from `nil` selects `0` (or last for up/end).

2. **Index domain is inconsistent.**  
   - Movement uses `length(state.data)` (raw, unfiltered).  
   - Highlight compares `index` from `Enum.with_index(paginated_data)` (page-local, 0…page_size−1) to `selected_row`.  
   - MCP `select_row` documents “row index (0-based)” without saying which list.  
   So selection under filter + pagination is already wrong. Viewport work must pick one law.

3. **`scroll_top` is a landmine name.**  
   Exists in struct/init/filter/set_page, unused in paint. Perfect hook; do not invent `scroll_offset` unless migrating SelectList too.

### Reference implementations already in tree

| Module | Path | Law |
|---|---|---|
| `Raxol.UI.ScrollWindow` | [`lib/raxol/ui/scroll_window.ex`](../../../lib/raxol/ui/scroll_window.ex) | Pure cursor-follow window; edge-anchored; thumb |
| `Raxol.Core.Utils.Math.scroll_into_view/3` | [`packages/raxol_core/lib/raxol/core/utils/math.ex`](../../../packages/raxol_core/lib/raxol/core/utils/math.ex) | Minimal “keep index visible” |
| Playground sidebar | [`lib/raxol/playground/app.ex`](../../../lib/raxol/playground/app.ex) (`move_cursor/2`, `sidebar_window/1`) | Own `cursor` + `scroll_top`; recompute window after every move/resize |
| `SelectList.Navigation` + `Utils.ensure_visible` | [`…/select_list/navigation.ex`](../../../lib/raxol/ui/components/input/select_list/navigation.ex), [`utils.ex`](../../../lib/raxol/ui/components/input/select_list/utils.ex) | Move focus then `scroll_into_view` |
| `Display.Viewport` | [`lib/raxol/ui/components/display/viewport.ex`](../../../lib/raxol/ui/components/display/viewport.ex) | Pure scroll container, **no selection**; keys move `scroll_top` only; `overflow_anchor` for growing logs |
| Sidebar tests | [`test/raxol/playground/sidebar_scroll_test.exs`](../../../test/raxol/playground/sidebar_scroll_test.exs) | “scroll_top advances by ≤1 per step”; property partner in `scroll_window_test.exs` |

Table should follow the **sidebar / SelectList selection law**, not Viewport’s log-tail law. Viewport remains the right tool for free-scroll content without a row cursor.

### Concurrent border work (compose)

A concurrent change is adding Table render modes roughly:

- `border: :grid | :inner | :none` (and existing outer box border)
- `header_separator` (line between header and body)

Those change **chrome row cost** (extra separator lines between body rows in `:grid`, optional header rule) but not selection semantics. Viewport design must:

- Count chrome rows when deriving `visible_rows` from `available_height`
- Window **data rows only** (never virtualize the header)
- Keep scrollbar on the body track height (= number of painted body rows), matching playground’s “one cell per visible item” thumb

---

## 2. Goals & non-goals

### Goals

1. **Windowed body** — paint only the visible slice of body rows for a known row budget.
2. **Selection-follows-window (autoscroll)** — j/k, arrows, home/end, page-select keys keep the selected row on screen by moving `scroll_top` (ScrollWindow / sidebar law: edge-anchored, ±1 for step moves).
3. **Explicit scroll without changing selection** — wheel (and optional half-page keys) adjust `scroll_top` only; selection may leave the window until the next selection move re-anchors.
4. **Orthogonal pagination** — page slice remains a data-pipeline stage; windowing applies to the post-pipeline list (full list when `paginate: false`, current page when `paginate: true`).
5. **Small surface** — reuse `ScrollWindow`; no new GenServer, no nested Viewport component, no virtual DOM framework.
6. **Fix selection nil + index domain** as part of making windowing correct.

### Non-goals

- Horizontal column virtualization / sticky first column (later).
- Multi-select, range select, cell-level selection.
- Wrapping multi-line cells (body row height ≠ 1); this design assumes **1 terminal row per data row**.
- Streaming / infinite backends (`ScrollContent` adapter for Table) — can layer later via the same slice API.
- Replacing SelectList’s hand-rolled `scroll_offset` with ScrollWindow (related cleanup, separate PR).
- LiveView/CSS overflow mapping for Table (terminal-first; LV can clip via existing overflow styles later).
- Mouse drag on scrollbar thumb (thumb is paint-only, like sidebar).

---

## 3. Proposed model (state fields, invariants)

### Effective list (single source of truth for indices)

```elixir
defp effective_rows(state) do
  state.data
  |> filter_data(state.filter_term)
  |> sort_data(state.sort_by, state.sort_direction)
  |> maybe_page(state)   # identity when not paginating
end

defp maybe_page(rows, %{options: %{paginate: true}} = state) do
  paginate_data(rows, state.current_page, state.page_size)
end

defp maybe_page(rows, _state), do: rows
```

Call the result **`E`** (effective body list). Length `n = length(E)`.

### State fields

Keep / activate:

| Field | Type | Meaning |
|---|---|---|
| `scroll_top` | `non_neg_integer()` | First **body** row of `E` painted (already present) |
| `selected_row` | `nil \| non_neg_integer()` | Index into **`E`**, not raw `data`, not “global across pages when paginating” |

Add:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `visible_rows` | `pos_integer() \| nil` | `nil` | Explicit body row budget. `nil` = derive or paint-all (see below) |
| `show_scrollbar` | `boolean()` | `true` | When windowed and overflown, paint proportional thumb (ScrollWindow.thumb) |

Options (under `state.options` or top-level props — match existing style: top-level `page_size` is duplicated from options today; prefer reading **options** for new keys and mirroring into state only if needed for hot path):

```elixir
# options additions
%{
  # existing...
  paginate: boolean(),
  page_size: pos_integer(),
  # new
  visible_rows: pos_integer() | nil,   # nil → auto / paint-all
  show_scrollbar: boolean(),           # default true
  scrollbar_style: :subtle | :glyph    # default :subtle (playground parity)
}
```

Init mirrors:

```elixir
visible_rows: Map.get(props, :visible_rows) || options[:visible_rows],
show_scrollbar: Map.get(options, :show_scrollbar, true),
scrollbar_style: Map.get(options, :scrollbar_style, :subtle),
scroll_top: 0,
selected_row: Map.get(props, :selected_row, nil)
```

Do **not** add `viewport: :paginate | :scroll` as a mode enum. Pagination and windowing are orthogonal pipeline stages; a mode enum forces false mutual exclusion and fights the concurrent border work’s options map.

### When windowing is active

```text
windowed? =
  body_budget(state, context) != nil
  and length(E) > body_budget(...)
```

`body_budget/2` resolution order:

1. `state.visible_rows` if positive integer  
2. Else if `context.available_height` is a positive integer:  
   `max(1, available_height - chrome_rows(state))`  
3. Else `nil` → **paint all of `E`** (backward compatible; same as today for unscoped tests)

`chrome_rows/1` (compose with border PR):

```text
chrome =
  1                                          # header row (if shown)
  + (header_separator? && 1 || 0)
  + (paginate? && 1 || 0)                    # footer "Page x of y"
  + grid_separator_rows(visible_body, border)
```

For v1, **prefer fixed `visible_rows` in options** and treat available_height derivation as optional polish. Grid inter-row separators complicate “N data rows fit in H terminal rows”; v1 can document `visible_rows` as **data-row count**, with separators consuming extra terminal rows *outside* the budget (or reduce budget by separator count when border is `:grid`). Implementation PR must pick one and test it; recommendation:

> **Budget is terminal body lines for data cells only.**  
> Separators, if any, are paid from remaining height by shrinking the data budget at render time:  
> `data_budget = max(1, terminal_body_lines - separator_lines_for(data_budget_candidate))`  
> or, simpler for v1: **windowing + `:grid` border is supported only with explicit `visible_rows`**, and chrome math assumes 1 line per data row + optional single header separator.

### Invariants

**I1. Selection domain.**  
If `selected_row != nil` and `n > 0`, then `0 <= selected_row < n` after every update/event (clamp). If `n == 0`, `selected_row == nil`.

**I2. Scroll domain.**  
`0 <= scroll_top <= max(0, n - V)` where `V = body_budget` (or `n` if not windowed). Always true after window recompute.

**I3. Selection visibility after selection moves.**  
After any event that **changes** `selected_row` (including first selection from nil), if windowed:

```elixir
scroll_top' = ScrollWindow.window(E, selected_row, V, scroll_top).scroll_top
```

Selected row is always in the painted slice after selection moves.

**I4. Pure scroll does not move selection.**  
`scroll_by` / wheel leave `selected_row` unchanged. Selection may leave the window. Next selection-changing event re-applies I3 (jump-into-view, possibly moving `scroll_top` by more than 1 — acceptable; only ±1 is required for adjacent steps).

**I5. Filter / sort / page reset.**  
- Filter: `current_page = 1`, `scroll_top = 0`, clamp or clear `selected_row` (see edge cases).  
- Sort: keep `selected_row` as index into new `E` is wrong (row identity shifts). **v1: clamp index only** (same as today); optional later: track selected row by stable id.  
- Page change: `scroll_top = 0`; clamp `selected_row` into new page’s `E` (page-local domain — see I1: `E` is the page slice when paginating).

**I6. Header is never windowed.** Always paint full header for all columns.

**I7. Pagination and windowing compose.**

```text
E = page_slice(sorted_filtered)     # or full list
paint = window(E, selected_or_scroll, V, scroll_top).visible
```

Large datasets that need both “server-style pages” and a short terminal: set `paginate: true, page_size: 100, visible_rows: 12`. Continuous browser-like scroll: `paginate: false, visible_rows: 12`.

---

## 4. ScrollWindow integration (or why not Viewport)

### Use ScrollWindow (yes)

```elixir
alias Raxol.UI.ScrollWindow

# After building E and resolving V:
window =
  case state.selected_row do
    nil ->
      # no cursor-follow: clamp scroll_top only
      max_scroll = max(length(E) - V, 0)
      scroll_top = Math.clamp(state.scroll_top, 0, max_scroll)
      %{
        visible: Enum.slice(E, scroll_top, V),
        scroll_top: scroll_top,
        cursor_row: nil,
        overflown?: length(E) > V,
        thumb: ScrollWindow.thumb(scroll_top, V, length(E))
      }

    cursor ->
      ScrollWindow.window(E, cursor, V, state.scroll_top)
  end
```

**When to call:**

| Path | Call shape |
|---|---|
| Selection move (↑↓, j/k, home/end, page-select, select_row, click row) | `ScrollWindow.window(E, new_selected, V, prev_scroll_top)` → write back `scroll_top` |
| Pure scroll (`scroll_by`, wheel) | clamp `scroll_top + delta`; **do not** pass through cursor-follow (or pass a synthetic cursor outside window — simpler: manual clamp) |
| Render only | recompute window from current state for slice + thumb (idempotent if state already consistent) |
| Resize / `set_visible_rows` | re-window with same cursor to satisfy I2–I3 |

Playground pattern (`app.ex` `move_cursor/2`):

```elixir
model = %{model | cursor: new_cursor}
%{model | scroll_top: sidebar_window(model).scroll_top}
```

Table equivalent: private `reanchor/1` after selection changes.

### Do not nest `Display.Viewport`

Reasons:

1. **Key conflict.** Viewport eats ↑↓/PgUp/PgDn/Home/End as pure scroll; Table needs those for selection (and left/right for pages).
2. **Double state.** Viewport owns its own `scroll_top`; Table already has one.
3. **Row model mismatch.** Viewport windows arbitrary children; Table needs column flex per row + selection styling + header outside the window.
4. **overflow_anchor** is for growing logs, not selection lists.

Viewport remains correct for demos of free scroll; Table remains a selection list with optional windowing — same family as sidebar / SelectList.

### SelectList note

SelectList already implements the same law via `Math.scroll_into_view` in `Utils.ensure_visible/1`. Table should call **`ScrollWindow.window/4`** (gets thumb + slice + cursor_row in one shot) rather than only `scroll_into_view`, matching the newer playground substrate called out in `tui-steal-list.md` (#1 finder windowing DONE).

---

## 5. Event vocabulary (keys, mouse, MCP)

### Selection moves (I3 — reanchor)

| Input | Table event (existing vocabulary) | Behavior |
|---|---|---|
| ↓ / `j` | `{:key, {:arrow_down, mods}}` | `selected_row = next(selected)`; reanchor |
| ↑ / `k` | `{:key, {:arrow_up, mods}}` | previous; reanchor |
| Home | `{:key, {:home, mods}}` | `0`; reanchor |
| End | `{:key, {:end, mods}}` | `n-1`; reanchor |
| PgDn | `{:key, {:page_down, mods}}` | `selected_row += step`; reanchor |
| PgUp | `{:key, {:page_up, mods}}` | `selected_row -= step`; reanchor |
| Enter | `{:key, {:enter, mods}}` | no-op for state (app may observe selection) |
| Esc | `{:key, {:escape, mods}}` | `selected_row = nil` (scroll_top unchanged) |
| Click body row | `{:mouse, {:click, {x,y}}}` | map y → index in window → absolute in `E`; reanchor (usually no-op) |

**Nil selection:** first ↓/PgDn/Home selects `0`; first ↑/End selects `n-1` if `n > 0`; otherwise no-op.

**`step` for page keys when windowed:** `V` (visible body rows), not `page_size`. When not windowed but paginating, keep today’s `page_size` step (or `length(E)`). When both, prefer `V` for within-page jumps; left/right still change `current_page`.

### Pure scroll (I4 — no selection change)

| Input | Suggested event | Behavior |
|---|---|---|
| Mouse wheel | `{:mouse, {:scroll, direction, _mods}}` or `{:mouse, {:wheel, delta}}` — **normalize in handle_event to one internal form** | `scroll_top = clamp(scroll_top ± lines)`; default `lines = 3` |
| Optional Ctrl+U / Ctrl+D | `{:key, {:char, "u", [:ctrl]}}` etc. if the event layer exposes mods that way | half-window: `± max(1, div(V, 2))` |
| Programmatic | `update({:scroll_by, delta}, state)` | same clamp |
| Programmatic | `update({:scroll_to, row}, state)` | `scroll_top = clamp(row, 0, max_scroll)` — **does not** change selection (Viewport parity) |

**Justification for “selection may leave the window” on pure scroll:**

- Matches Viewport and classic TUI tables (scroll the view, keep the mark).  
- Selection navigation remains the path that guarantees on-screen selection (I3).  
- Pinning selection to the window on wheel would either (a) move selection (surprising) or (b) fight the user’s scroll (rubber-band). Reject both.

**PgUp/PgDn decision:** **page-selection**, not pure scroll. Rationale: Table already uses them for selection; SelectList does too; left/right own pagination. Pure scroll is wheel + `{:scroll_by, _}`. Document in demo help line.

### Pagination keys (unchanged)

| Input | Behavior |
|---|---|
| ← / → when `paginate: true` | `current_page ± 1`; `scroll_top = 0`; clamp `selected_row` into new `E` |
| next/prev buttons | same |

### Update messages

```elixir
# existing
{:filter, term}
{:sort, column}
{:set_page, page}
{:select_row, row_index}          # index into E; reanchor

# new
{:scroll_by, delta :: integer()}
{:scroll_to, row :: non_neg_integer()}   # scroll_top target, not selection
{:set_visible_rows, V :: pos_integer() | nil}
{:set_data, data :: list()}              # optional: clamp selection/scroll (nice-to-have)
```

### MCP (`ToolProvider`)

Keep:

- `select_row` — index into **E**; document as “index into the currently displayed list (filtered/sorted/current page)”
- `get_rows` — return `E` (or full data? today returns `state.data`; prefer documenting raw `data` vs add `get_effective_rows`)
- `sort`

Add (mirror Viewport):

```elixir
%{
  name: "scroll_to",
  description: "Scroll the table body so this row of the effective list is the first visible row (does not change selection)",
  inputSchema: %{type: "object", properties: %{row: %{type: "integer"}}, required: ["row"]}
},
%{
  name: "get_visible_range",
  description: "Return {top, bottom, total, selected_row} for the effective list",
  inputSchema: %{type: "object", properties: %{}}
}
```

`select_row` implementation path must call reanchor (I3), not only set the field.

### A11y

`a11y_node/1` currently builds a full grid of all data. When windowed, either:

- expose full logical grid (expensive, accurate for AT), or  
- expose visible rows + `aria-rowcount` / position  

v1: keep full logical rows from `E` (or raw data) in a11y tree; windowing is a paint optimization. Note as follow-up if large tables become a11y-hot.

---

## 6. Interaction with border modes, sort, filter, selection, pagination

### Border modes / header_separator

| Concern | Rule |
|---|---|
| Header | Always fully painted above the body window |
| `header_separator` | 0–1 line between header and first visible body row; not part of `E` |
| `:grid` horizontal rules | Between painted body rows only (visible slice), not for off-screen rows |
| `:inner` / `:none` | No change to window math beyond chrome_rows |
| Outer box | Existing `View.box`; available_height is interior if layout passes it correctly |
| Scrollbar | Extra column on the **body** (not header), playground-style subtle bg wash; optional `:glyph` |

Scrollbar must not steal column width from data without accounting: either overlay in the last cell padding or reserve 1 col from table width (playground reserves 1). Prefer **reserve 1 col when `overflown? and show_scrollbar`**.

### Sort

- Re-run pipeline → new `E`.  
- v1: clamp `selected_row` to new `n`; reanchor. Row identity may change under the cursor (acceptable; documented).  
- Header sort buttons unchanged (`_sort_<col>`).

### Filter

- Reset `current_page` to 1, `scroll_top` to 0 (already).  
- If previous `selected_row` out of range → clamp; if `n == 0` → `nil`.  
- Optionally clear selection on filter change — **prefer clamp** so keyboard users don’t lose place when filter still includes the row index (identity still weak without ids).

### Selection

- Domain = index in `E` (I1).  
- Highlight: when painting window slice, compare `scroll_top + local_index == selected_row` (not bare local_index). **This fixes the pagination highlight bug.**  
- Escape clears selection; pure scroll leaves it.

### Pagination

- Outer slice only.  
- Changing page resets `scroll_top` to 0.  
- `selected_row` is page-local once `E` is the page (because `E = page_slice`). Moving selection past page end does **not** auto-advance page in v1 (arrows clamp). Explicit ←/→ or buttons change page.  
  *Open alternative:* arrow past end advances page and sets selected to 0/last — nice UX, more tests; see open questions.

### `page_size` vs `visible_rows`

| | `page_size` | `visible_rows` |
|---|---|---|
| Role | Data chunk size when `paginate: true` | Paint budget for body window |
| Default | `Raxol.Core.Defaults.page_size()` (10) | `nil` (paint all of `E`) |
| PgUp/PgDn step when windowed | — | uses `visible_rows` / derived V |

---

## 7. Render algorithm (pseudocode)

```elixir
def render(state, context) do
  E = effective_rows(state)
  n = length(E)
  V = body_budget(state, context)  # nil | pos_integer

  {body_rows, scroll_top, thumb, overflown?} =
    case V do
      nil ->
        {E, 0, nil, false}

      v ->
        # Prefer state.scroll_top already reanchored by update/handle_event.
        # Recompute for safety (resize mid-frame, stale state).
        w =
          case state.selected_row do
            nil -> clamp_window(E, state.scroll_top, v)
            sel -> ScrollWindow.window(E, sel, v, state.scroll_top)
          end
        {w.visible, w.scroll_top, w.thumb, w.overflown?}
    end

  header = create_header(state.columns, state, context)
  # optional separator element from border PR
  sep = maybe_header_separator(state)

  # indices for selection: absolute in E
  row_views =
    body_rows
    |> Enum.with_index(scroll_top)
    |> Enum.map(fn {row, abs_i} ->
      create_row(row, abs_i, state, context)
    end)

  body =
    if overflown? and state.show_scrollbar do
      attach_scrollbar(row_views, thumb, V, state.scrollbar_style)
    else
      row_views
    end

  pagination = get_pagination(state.options.paginate, state, context)

  box(
    border: border_mode(state),  # concurrent PR
    children: column([header, sep, column(body), pagination_flex(pagination)])
  )
end
```

### Event path (selection)

```elixir
def handle_event({:key, {:arrow_down, _}}, state, context) do
  E = effective_rows(state)
  n = length(E)
  sel =
    case state.selected_row do
      nil when n > 0 -> 0
      nil -> nil
      i -> min(i + 1, n - 1)
    end

  {:ok, reanchor(%{state | selected_row: sel}, context)}
end

defp reanchor(state, context) do
  case {state.selected_row, body_budget(state, context)} do
    {nil, _} -> state
    {_, nil} -> state
    {sel, v} ->
      E = effective_rows(state)
      w = ScrollWindow.window(E, sel, v, state.scroll_top)
      %{state | scroll_top: w.scroll_top}
  end
end
```

### Event path (pure scroll)

```elixir
def update({:scroll_by, delta}, state) do
  E = effective_rows(state)
  v = state.visible_rows || length(E)
  max_scroll = max(length(E) - v, 0)
  top = Math.clamp(state.scroll_top + delta, 0, max_scroll)
  {:ok, %{state | scroll_top: top}}
end
```

Note: pure scroll with `visible_rows: nil` is a no-op (nothing to window).

### Click mapping

```text
y_in_body = y - header_chrome
if 0 <= y_in_body < length(painted_body):
  selected_row = scroll_top + y_in_body
  reanchor
```

Today’s `div(y - 1, 1)` assumes header is 1 and no separator; update with `chrome_rows` once border PR lands.

---

## 8. Edge cases

| Case | Behavior |
|---|---|
| `n == 0` | No body rows; `selected_row = nil`; `scroll_top = 0`; no scrollbar |
| `n == 1` | Selection 0 or nil; window shows one row; no overflow |
| `selected_row == nil` | No highlight; pure scroll free; first nav selects edge |
| `selected_row` out of range after filter | Clamp to `n-1` or nil if n=0 |
| Resize shrinks V | `reanchor` / clamp `scroll_top`; if selection was visible, ScrollWindow keeps it visible |
| Resize grows V | `scroll_top` may shrink via clamp; more rows appear |
| Filter shrinks set past selection | Clamp selection; `scroll_top = 0` on filter (existing) |
| Filter expands set | Keep selection index if still valid; `scroll_top = 0` |
| Page change | `scroll_top = 0`; selection domain is new page `E` — if old index was 5 and new page has 3 rows, clamp to 2 |
| `paginate: true` and `visible_rows > page_size` | No overflow; paint whole page; scrollbar nil |
| `paginate: true` and `visible_rows < page_size` | Window within page (primary “both” story) |
| `visible_rows: nil`, no available_height | Paint all of `E` (compat) |
| Escape clears selection while scrolled | Leave `scroll_top`; user sees same window without highlight |
| Pure scroll then j | I3 reanchors; may jump scroll_top by >1 to bring selection in — OK |
| MCP select_row far below window | Set selection + reanchor (may jump) |
| Concurrent border `:grid` | Separators only between painted rows; budget semantics per §3 |

---

## 9. API surface (init options, update messages)

### Init props (additive)

```elixir
Table.init(%{
  id: :jobs,
  columns: columns,
  data: rows,
  selected_row: 0,              # optional; demo/default for interactive tables
  options: %{
    paginate: false,
    searchable: true,
    sortable: true,
    page_size: 50,              # ignored when paginate: false
    visible_rows: 12,           # NEW — enable windowing
    show_scrollbar: true,       # NEW
    scrollbar_style: :subtle    # NEW
  },
  # border keys from concurrent PR pass through style/options unchanged
  theme: %{selected_row: %{bg: :blue, fg: :white}}
})
```

### Public helpers (optional, test-friendly)

```elixir
@spec effective_rows(map()) :: list()
@spec body_budget(map(), map()) :: pos_integer() | nil
@spec reanchor(map(), map()) :: map()   # or keep private
```

`paginate_data/3` stays public.

### Backward compatibility

| Old behavior | Preserved? |
|---|---|
| No `visible_rows`, no height in context | Yes — paints all of `E` |
| Pagination keys/buttons | Yes |
| `scroll_top` field present | Yes — now meaningful |
| `selected_row` page-local vs global bug | **Fixed** to index-in-`E` (behavior change for anyone relying on the bug) |
| nil + arrow crash | **Fixed** |
| MCP tool names | Additive tools only |

Document the selection index fix in CHANGELOG as a bugfix, not a feature flag.

---

## 10. Test plan

### Unit — pure state (no terminal)

File: `test/raxol/components/table_viewport_test.exs` (or extend `table_test.exs`).

1. **Nil selection:** arrow_down from nil → 0; arrow_up from nil → last.  
2. **Window slice:** `visible_rows: 5`, 20 rows → render body child count == 5.  
3. **Cursor-follow step:** selected 0… walk down; `scroll_top` increases by at most 1 per step (sidebar test clone).  
4. **Edge anchor:** selected at bottom of window → down → `scroll_top += 1`, selection still last visible row (`cursor_row == V-1` via ScrollWindow).  
5. **Home/End:** jump + reanchor to 0 / max_scroll.  
6. **Page keys:** step == V when windowed.  
7. **Pure scroll:** `{:scroll_by, 3}` moves `scroll_top`, not `selected_row`; selection can be off-window; subsequent down reanchors.  
8. **Filter clamp:** select last, filter to empty → nil; filter to 1 → selected 0 or clamped.  
9. **Pagination compose:** `page_size: 10, visible_rows: 4`, page 2 → `E` length 10, window 4, indices 0..9 are page-local.  
10. **Highlight index:** selected_row 7, scroll_top 5, visible_rows 4 → local row 2 highlighted.  
11. **Scrollbar nil when fits:** n ≤ V → no thumb.  
12. **set_visible_rows:** shrink V with selection at end → scroll_top adjusts.

### Property

Reuse patterns from `test/raxol/ui/scroll_window_test.exs`:

- ∀ steps: after selection move, `scroll_top <= selected_row <= scroll_top + V - 1` (when n > 0 and windowed).  
- `scroll_top` always in `0..max_scroll`.

### Integration / playground

- Extend `table_demo.ex`: large dataset (e.g. 50 rows), `paginate: false, visible_rows: 8`, help text for wheel + j/k.  
- Optional Headless screenshot test (pattern: `sidebar_scroll_test.exs`) asserting only V body lines and thumb column when overflown.

### Regression

Existing `test/raxol/components/table_test.exs` pagination/sort/theme tests must stay green. Any test that assumed selected_row compared to page-local paint without scroll_top offset needs updating if it asserted highlight incorrectly.

### MCP

- `select_row` far index updates selection and visible range.  
- `get_visible_range` matches state.  
- `scroll_to` does not change selection.

---

## 11. Migration / demo plan

### Phase A — correctness substrate (one PR, small)

1. Fix nil selection in arrow/page/home/end.  
2. Define `effective_rows/1`; all movement/highlight/MCP indices use `E`.  
3. Activate `scroll_top` + `ScrollWindow` when `visible_rows` set.  
4. `{:scroll_by, _}`, `{:scroll_to, _}`, `{:set_visible_rows, _}`.  
5. Unit tests §10.1–10.12.  
6. MCP scroll tools.  
7. Update moduledoc + table_demo (large list path).

### Phase B — layout-aware budget (optional follow-up)

1. Derive V from `context.available_height - chrome_rows`.  
2. Compose `chrome_rows` with border/header_separator PR.  
3. Click y-mapping uses chrome.  
4. Headless playground-style visual test.

### Phase C — polish

1. Mouse wheel event wiring end-to-end (depends on driver/event normalization).  
2. Ctrl+U/D half-page scroll.  
3. Stable selection by row id on sort/filter.  
4. Arrow past page boundary → auto page flip (if desired).

### Demo plan

[`table_demo.ex`](../../../lib/raxol/playground/demos/table_demo.ex):

- Keep current paginated 7-row demo **or** add a toggle `[v]` between:
  - **Paged:** current (`paginate: true, page_size: 4`)
  - **Windowed:** 40 synthetic rows, `paginate: false, visible_rows: 8, show_scrollbar: true`
- Status line: `selected=… scroll=… visible=a-b/n`  
- Help: `[j/k] select  [PgUp/Dn] select page  [wheel] scroll  [h/l] page when paged`

No default behavior change for apps that never set `visible_rows`.

---

## 12. Open questions

1. **Auto page-flip on arrow past end?**  
   Nice for paginated tables; complicates I1 (selection domain stays page-local only if page changes with selection). Defer to Phase C unless product wants it in v1.

2. **Derive `visible_rows` from available_height in v1?**  
   Recommended: **no** — require explicit `visible_rows` for windowing in Phase A so border/chrome PR can land without thrash. Phase B adds derivation.

3. **Wheel event shape in the global event model?**  
   Table can accept a private normalized form once the driver emits something stable. Until then, `update({:scroll_by, delta})` is the supported API; demo can map keys (e.g. `]/`/`]`) as stand-ins.

4. **Should `get_rows` MCP return raw `data` or `E`?**  
   Today: raw `data`. Prefer keep raw; add `get_effective_rows` or include both in one payload to avoid breaking agents.

5. **Selection tracking by row identity on sort?**  
   Right fix for “sort under me”; needs stable `:id` in row maps. Out of scope unless rows already have ids in common apps.

6. **Multi-line cells / variable row height?**  
   ScrollWindow is index-based with height 1. Variable height needs `ScrollContent.item_height/2` (exists on the behaviour). Explicit non-goal until a consumer needs it.

7. **Does `a11y_node` window?**  
   v1 full `E`; revisit if agents/AT load megatables.

8. **Border PR merge order?**  
   Phase A should not depend on border modes (assume current single outer border + header). Phase B integrates `chrome_rows` with whatever API the border PR ships (`options.border`, `style.border`, etc.). Implementors: read that PR’s field names before writing chrome math — **do not invent a parallel border option**.

---

## Appendix A — Decision summary

| Decision | Choice | Rejected alternative |
|---|---|---|
| Window substrate | `ScrollWindow.window/4` | Nest `Display.Viewport`; hand-roll only `scroll_into_view` without thumb |
| Pagination vs scroll | **Orthogonal** (page then window) | Exclusive modes `:paginate \| :scroll` |
| Selection index | Index into effective list `E` | Raw `data` index; dual global+local |
| PgUp/PgDn | Move **selection** by V | Pure scroll page |
| Wheel / scroll_by | Move **window** only; selection may leave | Pin selection; move selection with wheel |
| Default windowing | Off unless `visible_rows` (or later height) | Always window |
| Nil selection | First nav selects edge | Leave broken; force non-nil always |
| Scrollbar | Optional subtle body thumb via `ScrollWindow.thumb` | No indicator; always glyph |

## Appendix B — Critical call sites (implementation map)

| Concern | File |
|---|---|
| Table state / events / render | `lib/raxol/ui/components/table.ex` |
| Pure window math | `lib/raxol/ui/scroll_window.ex` |
| scroll_into_view primitive | `packages/raxol_core/lib/raxol/core/utils/math.ex` |
| Reference UX | `lib/raxol/playground/app.ex` |
| Demo | `lib/raxol/playground/demos/table_demo.ex` |
| Existing table tests | `test/raxol/components/table_test.exs` |
| ScrollWindow properties | `test/raxol/ui/scroll_window_test.exs` |
| Viewport contrast (do not copy keys) | `lib/raxol/ui/components/display/viewport.ex` |
| SelectList same law | `lib/raxol/ui/components/input/select_list/navigation.ex` |

---

*End of design. Implementation should land as a focused PR against `table.ex` + tests + demo only; border composition is a second PR if the border work is not merged yet.*
