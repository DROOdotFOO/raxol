defmodule Raxol.UI.Components.Harness.FooterStack do
  @moduledoc """
  The harness footer as a layout Component: an ordered stack of line-groups
  clamped to a row budget by the honest-notice / fit-priority law (harness
  TEA migration §5 law 3, unit U2).

  ## Why a Component owns the fit (and not the LayoutEngine)

  The LayoutEngine has flex shrink/min/max + clip, but no *priority-drop*
  primitive: it cannot be told "when the footer overflows, drop the
  above-composer blank first, then the preview, then the divider, ... and
  NEVER the honest report channels." That policy is the load-bearing law of
  the harness footer, so this Component computes the fit itself, in
  view-time, over measured child heights.

  Heights are model-known (harness-tea-migration §5 law 3): every footer
  group is handed in as an already-split list of one-row line elements
  (`[{key, [line]}]`), so a group's height is exactly `length(lines)` -- no
  wrap measurement, no `ViewText` (retired on the TEA path). Each line
  element is one physical row (a `Raxol.View.Components.text/1`-shaped map or
  any single-line node the child produced); the caller -- a demo or the
  endgame `HarnessApp` -- renders the child Components (StatusStrip,
  LaneNotice, Composer, Notice) to their line lists and hands the ordered
  keyword list in.

  ## The fit law (ported verbatim from the retired `Raxol.Harness.Surface`)

  `fit/3` and `shed_overflow/3` are the byte-for-byte port of
  `Surface.fit_footer_groups/3` + `Surface.shed_overflow/3` (the map-machine
  substrate retired; this is the one seat now). The contract:

    * **Display order is preserved.** The group list is rendered top to
      bottom in the order given; the fit only ever *removes* rows, never
      reorders.
    * **`drop_order` names the discretionary groups**, most-droppable
      first. Each is trimmed from its **TAIL** (`Enum.take/2`), so a
      partially-trimmed group keeps its leading line (the composer's prompt
      row, an expansion's position header).
    * **Protected groups are those absent from `drop_order`** -- they are
      never shed. In the harness footer these are the honest report
      channels `lane` / `submitting` / `notice`: a dropped lane/refusal
      notice would read as "nothing happened", the exact fail-safe
      inversion the notice channel exists to rule out.
    * **The head-take is the last resort.** After shedding, `lines/3`
      flattens the kept groups and takes the first `budget` rows, so if the
      protected channels alone still exceed the budget the EARLIEST rows
      survive (the notice-wins-at-budget-1 pin) rather than a crash or a
      position-blind tail drop.

  The `drop_order` and the protected set (its complement) are the caller's
  contract, exactly as `Surface.footer_frame/1` names them; this Component
  is policy-agnostic about *which* groups are droppable. The harness inline
  footer passes `[:composer_sep, :preview, :divider, :composer, :overlay,
  :status]`; the diff-expansion footer passes `[:expansion, :status]`.

  ## Controlled (§2 doctrine)

  State in via props (`groups` / `drop_order` / `budget`), a pure fitted
  view out; no `ComponentManager`, no local mutation, no interaction (the
  footer is a container -- its children own their own events, and this node
  advertises no MCP action of its own: the honest absence).
  """

  use Raxol.UI.Components.Base.Component

  @type key :: atom()
  @type line :: map() | String.t()
  @type group :: {key(), [line()]}

  @type t :: %{
          id: String.t() | atom(),
          groups: [group()],
          drop_order: [key()],
          budget: non_neg_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    state = %{
      id:
        Map.get(
          props,
          :id,
          "harness-footer-stack-#{:erlang.unique_integer([:positive])}"
        ),
      groups: Map.get(props, :groups, []),
      drop_order: Map.get(props, :drop_order, []),
      budget: normalize_budget(Map.get(props, :budget, 0)),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # A container has no events of its own; its children own theirs (the host
  # forwards to the focused child, §2 doctrine).
  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, _context) do
    %{
      type: :column,
      id: state.id,
      attrs: %{
        kind: :footer_stack,
        component_module: __MODULE__
      },
      style: state.style,
      gap: 0,
      children: lines(state.groups, state.drop_order, state.budget)
    }
  end

  # -- the fit law (verbatim port of Surface.fit_footer_groups/3) ----------

  @doc """
  The fitted keyword groups: sheds overflow per `drop_order` (each named
  group trimmed from its tail), leaving protected groups (absent from
  `drop_order`) untouched. Group-preserving -- the keyword structure
  survives so callers can read a group's post-fit line count (e.g. the
  composer offset for the cursor park). Byte-for-byte
  `Surface.fit_footer_groups/3`.
  """
  @spec fit([group()], [key()], integer()) :: [group()]
  def fit(groups, drop_order, budget) do
    total =
      groups |> Enum.map(fn {_key, lines} -> length(lines) end) |> Enum.sum()

    shed_overflow(groups, drop_order, total - budget)
  end

  @doc """
  The flat list of kept line elements: the fitted groups flattened in
  display order, then head-taken to `budget` (the last-resort clamp -- if
  the protected channels alone exceed the budget the EARLIEST rows survive,
  the notice-wins-at-budget-1 pin). This is what `render/2` emits as the
  footer column's children.
  """
  @spec lines([group()], [key()], integer()) :: [line()]
  def lines(groups, drop_order, budget) do
    groups
    |> fit(drop_order, budget)
    |> Enum.flat_map(fn {_key, lines} -> lines end)
    |> Enum.take(max(budget, 0))
  end

  @doc """
  Rows above `key` in the FITTED footer (the sum of the line counts of the
  groups displayed before it), or `nil` when `key` was shed to nothing /
  is absent. This is the offset half of the composer cursor park
  (harness-tea-migration §5 law 6): the host adds it to the footer's
  absolute top row and the composer's own `edit_point/2` row to place the
  caret. Mirrors `Surface.composer_cursor/3`'s offset computation.
  """
  @spec group_offset([group()], [key()], integer(), key()) ::
          non_neg_integer() | nil
  def group_offset(groups, drop_order, budget, key) do
    fitted = fit(groups, drop_order, budget)

    case Keyword.get(fitted, key) do
      nil ->
        nil

      [] ->
        nil

      _kept ->
        fitted
        |> Enum.take_while(fn {k, _lines} -> k != key end)
        |> Enum.map(fn {_k, lines} -> length(lines) end)
        |> Enum.sum()
    end
  end

  @doc """
  The total line count across all groups before any fit -- the natural
  footer height. Handy for a host deciding a budget or a test asserting
  overflow pressure.
  """
  @spec total_height([group()]) :: non_neg_integer()
  def total_height(groups) do
    groups |> Enum.map(fn {_key, lines} -> length(lines) end) |> Enum.sum()
  end

  # -- shed engine (verbatim port of Surface.shed_overflow/3) --------------

  defp shed_overflow(groups, _drop_order, overflow) when overflow <= 0,
    do: groups

  defp shed_overflow(groups, [], _overflow), do: groups

  # `Keyword.get(_, _, [])`, not the surface's `fetch!`: the surface's
  # `fit_footer_groups/3` fetches because its footer ALWAYS builds every
  # group (empty `[]` when nothing to show), so a drop_order key is never
  # missing. As a reusable component, `FooterStack` accepts partial group
  # sets (a fixed policy drop_order over a state-varying group list), so an
  # absent key is a clean no-op (shed 0, `List.keyreplace` leaves an absent
  # key absent), never a crash. Behavior is byte-identical when the key is
  # present -- the algorithm (tail-trim in drop order, protected never shed,
  # head-take last resort in `lines/3`) is the verbatim port.
  defp shed_overflow(groups, [key | rest], overflow) do
    lines = Keyword.get(groups, key, [])
    shed = min(length(lines), overflow)
    kept = Enum.take(lines, length(lines) - shed)

    groups
    |> List.keyreplace(key, 0, {key, kept})
    |> shed_overflow(rest, overflow - shed)
  end

  defp normalize_budget(budget) when is_integer(budget) and budget >= 0,
    do: budget

  defp normalize_budget(_budget), do: 0
end
