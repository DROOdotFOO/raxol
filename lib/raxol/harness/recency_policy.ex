defmodule Raxol.Harness.RecencyPolicy do
  @moduledoc """
  Turn recency -> per-block prominence: the policy that decides WHICH
  `prominence` (`0.0..1.0`) a transcript block gets, based purely on how
  many turns behind the current one its own turn is. This module is pure
  turn-identity arithmetic -- no processes, no clocks, no config reads,
  no rendering. It feeds `context[:prominence]` into
  `Raxol.UI.Components.Harness.Block.render/2`
  (`Raxol.UI.Harness.Prominence.resolve/3` underneath), but never calls
  either.

  ## The ladder

  `turns_behind` steps down a fixed four-tier ladder, floored at
  `floor/0` (`#{0.4}`):

  ```
  turns_behind:   0     1     2     3+
  prominence:    1.0   0.8   0.6   0.4
  ```

  `nil` or negative `turns_behind` -- an unknown or (defensively)
  future-relative position -- always resolves to `1.0`, never something
  darker: an ungraded block is never demoted below full prominence by
  this policy's own uncertainty.

  ## Seal-time grading (the substrate law)

  Prominence for a block is decided **exactly once, at the moment the
  block is painted/sealed**, and is never re-graded afterward -- the
  print-once history substrate this framework paints through cannot
  repaint scrollback (see `Raxol.Harness.Surface`'s own "seal / seal-once"
  glossary entry). A block sealed during its own turn seals at `1.0` and
  does NOT fade when the next turn starts; it is not re-visited once
  painted.

  The fade ladder is therefore visible wherever MULTIPLE turns are
  painted in one pass -- a full re-render, a reattach rebuild, the live
  region -- while incrementally sealed inline history keeps its
  seal-time grade forever, unchanged by anything that happens
  afterward. This is the honest, substrate-constrained reading of the
  ratified "scoped by policy" clause: the policy grades a block once,
  when it is painted; there is no retroactive re-grading, and no
  mechanism in this module (or its one caller,
  `Raxol.Harness.Surface.render_block_lines/3`) ever asks "what would
  this block's prominence be now?" for an already-sealed block.

  ## Composition with the needs-input floor

  This policy only produces the RECENCY prominence -- it has no opinion
  on, and never special-cases, content that is awaiting user input.
  That promotion lives one layer below, in
  `Raxol.UI.Components.Harness.Block` and
  `Raxol.UI.Harness.Prominence`: a live `:approval` block auto-passes
  `needs_input: true` into its render context, and
  `Prominence.resolve/3` floors the EFFECTIVE prominence at
  `Prominence.needs_input_floor/0` (`#{0.6}`) before the fade runs. So a
  pending approval this policy grades at, say, `0.4` (three-plus turns
  behind) still renders no dimmer than the `0.6` ordinary-context tier --
  an approval outranks its own ladder tier automatically, with no
  needs-input branch anywhere in this module.

  ## Coverage today (an honest scope note)

  The grade is threaded through `Raxol.UI.Components.Harness.BlockBody`'s
  render context for EVERY block, but only `Block.render/2` -- the folded
  path, and every fallback -- resolves `context[:prominence]` into a fade
  today. The expanded rich body components mounted via
  `Raxol.UI.Components.Harness.BodyProvider` do not yet thread the key
  (a pre-existing gap in those components, not in this policy or its
  wiring); when they grow that support, the grade is already there in
  their context, unchanged.

  ## Turn identity is opaque

  `turn_ids`/`turn_id` are opaque terms (atoms in tests, strings on the
  wire) compared only with `==` -- this module has no notion of a turn's
  internal shape, ordering by VALUE, or timestamps. "Recency" here means
  purely POSITION in first-seen order among the turns actually present,
  never wall-clock or `ts` distance.
  """

  @typedoc "An opaque turn identifier -- compared only with `==`."
  @type turn_id :: term()

  @typedoc "A resolved prominence value, `0.0..1.0`."
  @type prominence :: float()

  # The floor of the fade ladder -- three-or-more turns behind the
  # current one renders at this level, never darker. Single source of
  # truth for both `prominence/1`'s own floor clause and any caller that
  # wants to name the floor directly (mirrors
  # `Raxol.UI.Harness.Prominence.needs_input_floor/0`'s own pattern).
  @floor 0.4

  @doc """
  The floor of the recency fade ladder (`#{@floor}`) -- the prominence a
  block three-or-more turns behind the current one renders at.
  """
  @spec floor() :: prominence()
  def floor, do: @floor

  @doc """
  Maps `turns_behind` (a non-negative integer distance from the current
  turn) onto its ladder prominence: `0 -> 1.0`, `1 -> 0.8`, `2 -> 0.6`,
  `3` or more `-> #{@floor}` (the floor). `nil` or a negative integer --
  an unknown or defensively-clamped position -- always resolves to
  `1.0`: this policy's own uncertainty never reads as "darker."
  """
  @spec prominence(integer() | nil) :: prominence()
  def prominence(nil), do: 1.0

  def prominence(turns_behind)
      when is_integer(turns_behind) and turns_behind < 0, do: 1.0

  def prominence(0), do: 1.0
  def prominence(1), do: 0.8
  def prominence(2), do: 0.6
  def prominence(turns_behind) when is_integer(turns_behind), do: @floor

  @doc """
  Grades `turn_ids` (the per-block list of turn identifiers, in
  transcript order) against `current_turn`, returning a same-length list
  of ladder prominences.

  Turn ORDER is the distinct non-nil turn ids in `turn_ids`, in
  first-seen order (never wall-clock, never a separate turn list --
  exactly the turns actually present in this transcript). A block's
  `turns_behind` is `position(current_turn) - position(block_turn)` in
  that order.

  Rules (each a documented guarantee, never darker than honest
  uncertainty warrants):

    * `current_turn` is `nil` -- no honest way to grade -- every block
      grades `1.0`.
    * `current_turn` absent from the order (a brand-new turn with no
      blocks yet in `turn_ids`) is treated as one position NEWER than
      the newest listed turn -- every existing block is graded one tier
      further behind than it would be if that new turn already had an
      entry.
    * A block's own turn id `nil` grades that block `1.0` (nothing to
      grade against).
    * A block's turn NEWER than `current_turn` (shouldn't happen in a
      well-formed transcript; handled defensively) clamps `turns_behind`
      to `0` -> `1.0`, rather than extrapolating a "prominence above
      1.0" that has no meaning.
  """
  @spec grade([turn_id() | nil], turn_id() | nil) :: [prominence()]
  def grade(turn_ids, current_turn) when is_list(turn_ids) do
    order = turn_order(turn_ids)
    current_position = position(order, current_turn)

    Enum.map(turn_ids, &grade_one(order, current_position, &1, current_turn))
  end

  @doc """
  Convenience for the render path: grades `block` (matched loosely as
  `%{event_refs: refs}` so both `Raxol.UI.Components.Harness.Block.t()`
  and a plain map with that key work) against `events` -- typically
  `projection.source_events`, the retained durable events a
  `Raxol.Harness.Projection` was built from.

  Derivation (defensive throughout -- a non-map entry in `events` is
  skipped, never raised on):

    * the block's own turn is the `:turn_id` of the FIRST event in
      `events` whose `:id` is in `block.event_refs` (`nil` if
      `event_refs` is empty or nothing matches);
    * the current turn is the `:turn_id` of the LAST event in `events`
      that carries a non-nil `:turn_id` (`nil` if none do);
    * the turn order is the distinct non-nil `:turn_id`s across
      `events`, in first-seen order.

  Empty `events`, an unresolvable block turn, or a `nil` current turn
  all fall out of the same `grade/2` core as `1.0` -- see that
  function's own rule list.
  """
  @spec grade_block(map(), [map()]) :: prominence()
  def grade_block(%{event_refs: refs}, events) when is_list(events) do
    safe_events = Enum.filter(events, &is_map/1)
    order = safe_events |> Enum.map(&Map.get(&1, :turn_id)) |> turn_order()
    current_turn = current_turn_of(safe_events)
    current_position = position(order, current_turn)
    block_turn = block_turn_of(refs, safe_events)

    grade_one(order, current_position, block_turn, current_turn)
  end

  def grade_block(_block, _events), do: 1.0

  # -- grade/2 + grade_block/2 shared core --------------------------------

  # Never darker than 1.0 when either side of the comparison is
  # unknown -- both nil-current (no honest grading possible) and
  # nil-block-turn (nothing to grade this particular block against) are
  # handled BEFORE any position lookup, so neither ever reaches
  # `position/2` with a `nil` to search for.
  defp grade_one(_order, _current_position, _turn_id, nil), do: 1.0
  defp grade_one(_order, _current_position, nil, _current_turn), do: 1.0

  defp grade_one(order, current_position, turn_id, _current_turn) do
    turns_behind = current_position - position(order, turn_id)
    prominence(max(turns_behind, 0))
  end

  defp turn_order(turn_ids) do
    turn_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # Position of `turn_id` in `order` (first-seen index). A `turn_id` NOT
  # found in `order` -- the "current turn is a brand-new turn with no
  # blocks yet" case for `current_turn`, or (defensively) an
  # inconsistent block turn -- is treated as one position NEWER than the
  # newest listed turn (`length(order)`, one past the last valid index).
  # Reused identically for both the current turn and a block's own turn:
  # an unresolvable BLOCK turn hitting this same fallback makes
  # `turns_behind` non-positive (since `current_position <= length(order)`
  # always), which `grade_one/4`'s `max(turns_behind, 0)` clamp already
  # turns into `1.0` -- so one fallback correctly serves both cases.
  defp position(order, turn_id) do
    case Enum.find_index(order, &(&1 == turn_id)) do
      nil -> length(order)
      index -> index
    end
  end

  # -- grade_block/2 event-derivation helpers ------------------------------

  defp current_turn_of(events) do
    events
    |> Enum.map(&Map.get(&1, :turn_id))
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp block_turn_of([], _events), do: nil

  defp block_turn_of(refs, events) do
    case Enum.find(events, fn event -> Map.get(event, :id) in refs end) do
      nil -> nil
      event -> Map.get(event, :turn_id)
    end
  end
end
