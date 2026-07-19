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

  ### Why these values (the ladder's provenance)

  The four tiers are not new: they are the shipped salience ladder
  already pinned by `Raxol.UI.Harness.Prominence` -- `0.6` is the
  ordinary-context tier (`Prominence.needs_input_floor/0` floors
  awaiting-input content exactly there), the `1.0`/`0.6` pair is pinned
  by regression to survive 256-color quantization as distinct palette
  indices, and `0.4` is that ladder's own floor. This policy was
  ratified with an explicit "no new tiers" fence: it maps recency onto
  the EXISTING ladder, one uniform `0.2` step per turn behind, and any
  retuning of the tier values themselves belongs to the solver-side
  ladder (and its pending human-eye ratification pass, see the
  `Prominence` moduledoc), never to this mapping.

  ## Seal-time grading (the substrate law)

  Prominence for a block is decided **exactly once, at the moment the
  block is painted/sealed**, and is never re-graded afterward -- the
  print-once history substrate this framework paints through cannot
  repaint scrollback (see the retired `Raxol.Harness.Surface`'s "seal /
  seal-once" glossary entry). A block sealed during its own turn seals at
  `1.0` and
  does NOT fade when the next turn starts; it is not re-visited once
  painted.

  The fade ladder is therefore visible wherever MULTIPLE turns are
  painted in one pass -- a full re-render, a reattach rebuild, the live
  region -- while incrementally sealed inline history keeps its
  seal-time grade forever, unchanged by anything that happens
  afterward. This is the honest, substrate-constrained reading of the
  ratified "scoped by policy" clause: the policy grades a block once,
  when it is painted; there is no retroactive re-grading, and no
  mechanism in this module (or its callers — the retired
  `Raxol.Harness.Surface.render_block_lines/3`, now
  `Raxol.Harness.HarnessApp.Model.block_prominence/2`) ever asks "what
  would this block's prominence be now?" for an already-sealed block.

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

  Scope note: on today's sole wiring point (the fixture-replay
  surface's seal path) this composition is dormant -- the block builder
  constructs every block already `:sealed`, and the seal frontier holds
  a live approval back from painting at all, so a live approval never
  reaches the graded path there; it lives in the repaintable footer
  instead. The floor composition is real and tested at the `Prominence`
  layer, and engages the moment a live-rendering surface grades live
  blocks.

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

  **Caller contract (load-bearing): `turn_ids` must be in transcript
  order.** Positional recency is meaningless on a reordered list -- a
  turn that appears first IS oldest to this function, whatever its id
  looks like. This is a documented precondition, not something this
  pure function can validate (turn ids are opaque; there is no
  order-independent notion of "older" to check against).

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
  skipped, never raised on; the whole derivation is a SINGLE pass over
  `events`, so grading one block costs one walk, never three):

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

  **Input contract (load-bearing, guaranteed upstream for the intended
  feed):** `events` must be journal/ingest-ordered and complete for the
  blocks being graded. Both hold for `projection.source_events` by
  construction: `Raxol.Harness.Projection.Recovery.filter_ids/1` drops
  duplicate/out-of-order ids BEFORE retention (so the retained list is
  id-monotonic), and `source_events` retains EVERY durable event for
  the session un-windowed (only `:ephemeral` tier -- `item_delta`
  traffic, which never enters a block's `event_refs` -- is excluded),
  so every block built by the projection resolves its turn here. A
  caller feeding a reordered or windowed list violates the contract;
  each violation degrades toward `1.0` (never darker), per the same
  uncertainty rule as everything else in this module.
  """
  @spec grade_block(map(), [map()]) :: prominence()
  def grade_block(%{event_refs: refs}, events) when is_list(events) do
    {rev_order, current_turn, block_turn} = scan_events(events, refs)
    order = Enum.reverse(rev_order)
    current_position = position(order, current_turn)

    grade_one(order, current_position, block_turn, current_turn)
  end

  def grade_block(_block, _events), do: 1.0

  @doc """
  Batch form of `grade_block/2`: grades EVERY block in `blocks` against
  `events` with a SINGLE walk over the event list -- `O(events +
  total_refs)` for the whole batch, where the per-block form re-derives
  the (identical) turn order and current turn from the full event list
  on every call.

  Equivalence law (tested): `grade_blocks(blocks, events)` is exactly
  `Enum.map(blocks, &grade_block(&1, events))` -- same input contract,
  same defensive fallbacks, only the cost differs. This is the entry
  point a bulk paint should use: a full re-render, a reattach rebuild,
  or any pass that grades a whole projection at once. The incremental
  seal path (the retired `Raxol.Harness.Surface.render_block_lines/3`)
  kept the per-block form because its hold-back-one design seals a
  bounded number of blocks per advance.
  """
  @spec grade_blocks([map()], [map()]) :: [prominence()]
  def grade_blocks(blocks, events) when is_list(blocks) and is_list(events) do
    {rev_order, current_turn, turn_by_id} = index_events(events)
    order = Enum.reverse(rev_order)
    current_position = position(order, current_turn)

    Enum.map(blocks, fn
      %{event_refs: refs} ->
        block_turn = first_ref_turn(refs, turn_by_id)
        grade_one(order, current_position, block_turn, current_turn)

      _other ->
        1.0
    end)
  end

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

  # One pass over `events` deriving all three of grade_block/2's inputs
  # at once (the doc's "one walk, never three"): the distinct non-nil
  # turn order (accumulated REVERSED, with a MapSet for O(1) seen
  # checks -- the caller reverses back to first-seen order), the current
  # turn (last non-nil turn_id wins by overwrite), and the block's own
  # turn (the FIRST event whose id is in `refs`; latched with a
  # `{:found, turn}` tuple rather than a bare sentinel atom so an
  # opaque turn id can never collide with "not found yet"). Non-map
  # entries fall through the guard and are skipped, never raised on.
  defp scan_events(events, refs) do
    ref_set = MapSet.new(refs)

    {_seen, rev_order, current_turn, block_turn} =
      Enum.reduce(events, {MapSet.new(), [], nil, :none}, fn
        event, {seen, rev_order, current, found} when is_map(event) ->
          turn = Map.get(event, :turn_id)
          {seen, rev_order} = note_turn(seen, rev_order, turn)
          current = if is_nil(turn), do: current, else: turn

          found =
            if found == :none and
                 MapSet.member?(ref_set, Map.get(event, :id)) do
              {:found, turn}
            else
              found
            end

          {seen, rev_order, current, found}

        _non_map, acc ->
          acc
      end)

    {rev_order, current_turn, unwrap_block_turn(block_turn)}
  end

  defp unwrap_block_turn({:found, turn}), do: turn
  defp unwrap_block_turn(:none), do: nil

  # First-seen turn-order accumulation, shared by both event walks:
  # skip nil and already-seen turns, otherwise prepend (the caller
  # reverses back to first-seen order once, at the end).
  defp note_turn(seen, rev_order, turn) do
    if is_nil(turn) or MapSet.member?(seen, turn) do
      {seen, rev_order}
    else
      {MapSet.put(seen, turn), [turn | rev_order]}
    end
  end

  # -- grade_blocks/2 batch helpers ----------------------------------------

  # The batch counterpart of scan_events/2: ONE walk over `events`
  # deriving the turn order, the current turn, AND an id -> {position,
  # turn} index -- so each block afterwards resolves its own turn in
  # O(its refs) instead of re-walking the event list. `Map.put_new/3`
  # keeps the FIRST occurrence per id (filter_ids guarantees unique ids
  # on the intended feed; first-wins preserves grade_block/2's
  # first-matching-event semantics on a contract-violating one).
  defp index_events(events) do
    {_seen, rev_order, current_turn, turn_by_id, _pos} =
      Enum.reduce(events, {MapSet.new(), [], nil, %{}, 0}, fn
        event, {seen, rev_order, current, by_id, pos} when is_map(event) ->
          turn = Map.get(event, :turn_id)
          {seen, rev_order} = note_turn(seen, rev_order, turn)
          current = if is_nil(turn), do: current, else: turn
          by_id = Map.put_new(by_id, Map.get(event, :id), {pos, turn})
          {seen, rev_order, current, by_id, pos + 1}

        _non_map, acc ->
          acc
      end)

    {rev_order, current_turn, turn_by_id}
  end

  # The turn of the FIRST event (by event position, not ref position)
  # whose id appears in `refs` -- exactly grade_block/2's derivation,
  # answered from the prebuilt index. `nil` when nothing resolves.
  defp first_ref_turn(refs, turn_by_id) when is_list(refs) do
    refs
    |> Enum.flat_map(fn ref ->
      case Map.fetch(turn_by_id, ref) do
        {:ok, {pos, turn}} -> [{pos, turn}]
        :error -> []
      end
    end)
    |> case do
      [] -> nil
      found -> found |> Enum.min_by(&elem(&1, 0)) |> elem(1)
    end
  end

  defp first_ref_turn(_refs, _turn_by_id), do: nil
end
