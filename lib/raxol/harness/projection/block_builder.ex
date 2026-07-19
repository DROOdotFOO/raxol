defmodule Raxol.Harness.Projection.BlockBuilder do
  @moduledoc """
  Folds one turn's `family: :loop` events into `%Block{}`s.

  Two-pass per turn:

    1. `fold_items/1` -- a single streaming pass over the turn's events
       (already id-recovered by `Raxol.Harness.Projection.Recovery`)
       that groups events by `item_id` (an "item-group"), detects
       orphan `item_completed` records (no matching `item_started`,
       §4.1), drops late `item_delta`s arriving after their item
       sealed (N-SEAL), and accumulates the live tail for items that
       never completed.
    2. `build_blocks/2` -- walks the completed item-groups in order
       with 1-item lookahead: a well-formed `tool_use` immediately
       followed by a well-formed `tool_result` merges into ONE
       `:tool_call` block (Block has no separate `:tool_result` kind --
       the merge is how a tool round-trip becomes a single renderable
       unit). Everything else becomes its own block.

  `approval_requested` events carry their own complete payload (no
  item lifecycle) and are folded as singleton groups, always
  well-formed, never eligible for the tool-call merge.

  ## The duration fix (STATE note)

  `Block.from_events/3`'s own `duration_from_timestamps/1` finds the
  FIRST `item_started` and FIRST `item_completed` in whatever event
  list it's given -- correct for a single item, wrong for a merged
  tool_use+tool_result pair (it reports the tool_use's own start/complete
  span, not the full call-to-result span). This module owns the fix:
  every `:tool_call` block's `outcome.duration_ms` is recomputed here
  from the min/max timestamp across ALL of its source events, overriding
  Block's narrower calculation post-construction.

  ## Recovered-block provenance

  `Block` has no `provenance` field (frozen struct, T4's write-set).
  Orphan/opaque-kind recovered blocks are flagged via two extra keys
  merged into `block.content` -- `:recovered` (boolean) and
  `:recovered_reasons` (a list, since orphan-ness and unknown-kind are
  independent and a block can be both at once) -- which is safe: every
  `Block.render/2` content pattern match binds only the specific keys
  it needs, so extra keys are inert. Both keys come from
  `Raxol.Harness.Projection.Recovery.recovery_meta_keys/0`, the same
  source `Projection.transcript_identity/1` strips back out.

  ## Live-tail keys are per-turn, not global

  `build_tail/2` keys the live tail by `{turn_id, item_id}`, not raw
  `item_id`. Item ids are only guaranteed unique WITHIN a turn; a
  producer reusing `"i1"` in a later turn (while an earlier turn's
  `"i1"` is still unsealed) would otherwise collide when
  `Raxol.Harness.Projection.project_turn/3` merges each turn's tail
  into the session-wide accumulator, silently dropping the earlier
  turn's live entry.

  ## Live-tail delta buffer is bounded

  An item that never completes (`item_started` with no matching
  `item_completed`) accumulates its `item_delta` chunks forever unless
  capped. `fold_event(:item_delta, ...)` keeps a sliding window of the
  most recent `@max_tail_delta_chunks` chunks per item, diagnosing
  `:delta_buffer_capped` once per item the first time a chunk is
  dropped (not on every subsequent delta).

  ## Completion evidence (the honesty row)

  After a turn's blocks are built, `build_turn/3` scans the turn's raw
  events for the LAST `turn_completed` whose payload `final` is `true`
  (string or atom key -- the wire is string-keyed JSON, live producer
  events are atom-keyed, see `Raxol.Agent.Contract.gated_done_payload/4`,
  read-only ground truth in `packages/raxol_agent`). A non-final turn
  (no such event) is untouched -- byte-identical output, no `:completion`
  key anywhere.

  When a final `turn_completed` IS found and the turn produced at least
  one block, `content.completion` is merged into the turn's LAST block
  only (the one a "done" claim attaches to):

    * `refs` missing, not a list, or an empty list -> `%{evidence: :none}`
      -- the design creed's mandatory absence row (never blank, never a
      checkmark).
    * otherwise -> `%{evidence: entries, total: n, type_counts: counts}`,
      `entries` capped at `@max_completion_entries` (`Block.render/2`'s
      completion row shows "+N more" for the rest), `n` the FULL ref
      count, and `counts` a `[%{type:, count:}]` list (descending count,
      ties broken by first-appearance order among `refs`) covering
      EVERY ref, not just the capped entries -- the summary line's
      breakdown must be accurate even when most refs are never
      individually rendered. Maps, not `{type, count}` tuples: this
      content rides through `Jason.encode!/1` at bless time, which has
      no `Encoder` for tuples.

  ## Refs are SESSION-scoped journal offsets, not turn-scoped -- and why

  Per the frozen offset law (a `ref` is a journal event id, and ids are
  session-wide), resolution is against the WHOLE session's id-recovered
  event stream, not just the owning turn's own events. `Projection.
  project/2` builds one `id -> event` index over the id-recovered
  stream (before family partition or turn bucketing) and threads it
  into every turn's `build_turn/3` call; this module never re-derives
  it and never assumes a ref lives in the events it was handed.

  This is a DISPLAY-side decision, not a re-implementation of the
  producer's evidence gate: the honest producer
  (`Raxol.Agent.Contract.gated_done_payload/4` / the evidence gate it
  consults) only ever emits gate-accepted, SAME-turn refs -- the gate is
  the sole acceptance authority. A direct call back into the gate is
  impossible (`raxol_agent` depends on main `raxol`, never the reverse),
  but that only rules out CALLING it -- WHICH of its predicates to
  re-derive locally is a decision, made on predicate stability:

    * **Closed predicates are mirrored.** Index existence (a rejected
      `missing_ref` renders `"unresolvable evidence ref"`), item_type
      (a rejected `not_evidence` is disclosed by the type breakdown --
      renders "1 message", never "1 tool result"), and turn_id equality
      (a rejected `foreign_turn` renders marked `cross_turn: true`, see
      below) are decidable from frozen wire facts and can never diverge
      from the gate's own reading of them.
    * **Open predicates are knowingly NOT mirrored** -- see "Knowingly
      unmarked" below.

  Session-scope resolution here is a deliberate display-side SUPERSET of
  what an honest producer emits -- a claim citing a ref the gate would
  have rejected as foreign-turn is SHOWN, marked, rather than hidden or
  silently resolved as if unremarkable. `type` carries the "what kind"
  signal, `cross_turn` the orthogonal "which turn" signal.

  ## Knowingly unmarked: stale and mutation-echo

  A same-turn ref the gate would reject as `stale_evidence` (the cited
  result predates a later mutation in the claiming turn) or as
  `mutation_echo` (the last mutation's own result echo, verifying
  nothing) renders as ordinary, UNMARKED evidence. This is a conscious
  decision, pinned by tests, not an oversight. Both predicates consume
  the gate's mutation predicate, which is an OPEN predicate: today it is
  fail-safe ("every completed `tool_use` is a mutation ... and not
  `classified_effect_free?`", where `classified_effect_free?/1` is
  constantly false), but that private function is an explicit, designed
  refinement seam -- a structural effect classification is planned to
  remove effect-free tools from the mutation set. Mirroring today's
  everything-mutates reading into this renderer would freeze it here:
  once the seam is filled, gate-ACCEPTED evidence (accepted precisely
  because the intervening tools were classified effect-free) would
  render with false stale/echo marks -- the display would accuse honest
  evidence, which burns trust in the marks that ARE reliable. The
  closed-predicate marks above never have that failure mode.

  Bound on the residual: the current gate is fail-closed on journals
  without effect classification, and the producer attaches `refs` ONLY
  on gate-accept -- so today's honest wire never carries refs at all,
  and an unmarked stale/echo render is reachable only through a
  tampered or synthetic journal. Even there, the closed-predicate marks
  and the projection's `damaged` flag still catch most tampering
  shapes; what remains unmarked is exactly a same-turn, evidence-class,
  index-resolvable ref whose only defect is ordering relative to
  mutations -- a defect only the gate's evolving mutation predicate can
  judge without false accusations.

  This bound is ENFORCED, not merely documented:
  `Raxol.Agent.DoneGateHonestyBoundTest` (in `raxol_agent`, the one tree
  where both this renderer and the gate are loadable) pins that the
  honest producer emits no `refs` on a fail-closed journal and that this
  builder therefore renders the absence row -- so a future fail-open gate
  change breaks a pin LOUDLY rather than silently laundering evidence
  here.

  ## Cross-turn disclosure

  Every resolved entry, and a session-wide tally alongside `type_counts`,
  compares the resolved event's OWN `turn_id` against the CLAIMING
  turn's `turn_id` (the final `turn_completed` event's own `turn_id` --
  not a turn a same-turn `:tool_call` block happens to belong to):

    * a mismatch adds `cross_turn: true` to that entry's map
      (`put_present` style -- a same-turn entry's map shape is
      UNCHANGED, so an all-same-turn completion churns nothing that
      wasn't already there before this fix).
    * `cross_turn_count` (tallied over ALL refs, not just the capped
      entries -- the identical "every ref, not just the shown ones"
      discipline `type_counts` already follows) is added to the
      completion map ONLY when it is greater than zero, for the same
      no-churn reason.

  Per-ref resolution never raises (defensive, bounded, always returns
  `%{ref:, type:, label:}`, plus `cross_turn: true` when applicable):

    * ref missing from the session index -> `type: :unresolvable`,
      `label: "unresolvable evidence ref"` (literal, rendered verbatim
      -- an unresolvable ref is information, never silently dropped,
      and it still counts toward the summary line's breakdown). Never
      marked cross-turn: there is no resolved event to compare a
      turn_id against, and cross-turn is a "which turn did this
      citation come from" signal, not a synonym for "unresolvable".
    * otherwise -> `type` is the resolved event's `item_type` when it is
      an `item_completed` (`:tool_result`, `:message`, ...), else
      `:unknown`. `label` prefers a same-turn `:tool_call` block's own
      `content.name` (nicer, already-extracted display name) when the
      ref lands in THIS turn's own blocks -- naturally absent for a
      cross-turn ref, since a different turn's own built blocks were
      never searched -- falling back to the raw event's own `"name"`
      payload field; that name is joined with the resolved event's
      content's first non-blank line via `" — "` when both are present,
      either alone when only one is, and the type name itself when
      neither resolves to anything displayable.

  Every resolved label is sanitized (control-byte strip, mirroring
  `Raxol.Harness.Surface.ViewText.sanitize/1`'s byte-wise technique
  verbatim, but with NO `\\t` exception -- a completion label is a single
  inline cell, never a multi-line body) and clamped to 32 display
  columns (`Raxol.UI.TextLayout.truncate/3`, never `String.length`/
  `String.slice` -- see that module's own width-safety contract) before
  it ever reaches a block's content: labels originate from the LLM/agent
  side and are untrusted exactly like any other tool-call/tool-result
  payload this module already folds.

  ## Known conflation (fail-open wire) -- and where V's ruling lives

  The producer emits `final: true` with NO `refs` key for at least THREE
  indistinguishable states: gate-rejected evidence, a "done" citing
  nothing at all, and a trivial tool-free turn with nothing to cite. The
  wire carries no rejection marker distinguishing them, so at THIS layer
  the absence marker (`%{evidence: :none}`) stays UNCONDITIONAL -- the
  projection is governed by the frozen offset/assembly law (P-ASM,
  P-DET-04: two surfaces attaching at different offsets must converge to
  one transcript identity), and any window-dependent attach decision
  (e.g. "did this turn carry tool events?") diverges under a mid-turn
  attach that cannot see the turn's earlier events. V's field ruling
  (2026-07-17: "no evidence provided" on a pure chat turn is noise --
  no tool ran, so no evidence could ever have existed) is therefore
  implemented one layer up, at RENDER time: the Surface derives
  `turn_has_tools?` from its own window and threads it into
  `Block.completion_rows/3`, which suppresses the absence ROW (never
  the attached marker) for tool-free turns. Identity untouched, display
  de-noised; the row remains fail-safe-visible for any renderer that
  does not pass the flag. The remaining conflated states (gate-rejected
  vs cited-nothing on a tool-bearing turn) stay pending the
  producer-side wire change (tracked cross-lane, not this module's
  concern).

  ## Staleness under compaction

  Refs are stable, counter-derived journal ids -- a reattach at a later
  offset does not shift them. But an event compacted or dropped upstream
  (before this projection ever sees it) leaves the session index without
  that key, and the ref renders `"unresolvable evidence ref"` exactly as
  if the ref had never existed at all -- this module cannot tell the two
  apart BY ITSELF. A consumer CAN, though, one level up: an interior
  drop produces a forward id gap, which sets the whole projection's
  `damaged: true` flag (`Raxol.Harness.Projection.Recovery.filter_ids/1`).
  Unresolvable-in-a-damaged-stream (a possible compaction victim) is
  therefore distinguishable from unresolvable-in-an-intact-stream (the
  ref never existed) by checking `projection.damaged`, not by anything
  this module's own output carries.

  A final `turn_completed` with ZERO blocks in the turn (nothing to
  attach honesty to) synthesizes no block -- `turn_completed` stays
  structural/never block-producing (the frozen P-TIER-01 tier law) --
  and instead diagnoses `:final_completion_without_blocks` via
  `Recovery.emit/2`, same as every other recovered condition this module
  reports.
  """

  alias Raxol.Harness.Projection.Recovery
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.TextLayout

  # Bounds how many resolved evidence entries a completion row shows
  # inline -- `Block.completion_rows/2` renders "+N more" for the
  # remainder using `total` (the FULL ref count, always kept regardless
  # of this cap).
  @max_completion_entries 3

  # The display-column budget a single completion label is clamped to
  # (`TextLayout.truncate/3`, :ellipsis mode) -- a label is one inline
  # cell in the completion row, never a wrapped multi-line body.
  @completion_label_width 32

  # Sliding-window cap on the live-tail delta buffer for a single
  # unsealed item: an item_started with no item_completed and an
  # unbounded stream of item_delta events would otherwise grow
  # acc.deltas[item_id] forever. Keeps the most recent N chunks (drops
  # the oldest), diagnosing once per item the first time a chunk is
  # dropped -- not on every subsequent delta, which would flood
  # diagnostics/telemetry for a long-running stream.
  @max_tail_delta_chunks 200

  @known_item_types %{
    "message" => :message,
    "reasoning" => :reasoning,
    "tool_use" => :tool_use,
    "tool_result" => :tool_result
  }

  @block_kind_by_item_type %{
    message: :message,
    reasoning: :reasoning,
    tool_use: :tool_call,
    tool_result: :tool_call
  }

  @doc """
  Folds one turn's events into `{blocks, tail, diagnostics}`.
  `fold_defaults` maps a `Block.kind()` to its initial fold state.
  `session_index` is the whole session's `id -> event` map (built by
  `Raxol.Harness.Projection.project/2` over the id-recovered stream,
  BEFORE turn bucketing) -- completion-evidence refs are session-scoped
  journal offsets, not turn-scoped, so resolution reaches beyond this
  turn's own `events` (see the moduledoc's "Refs are SESSION-scoped").
  Defaults to `%{}` so a ref genuinely absent from the session resolves
  as unresolvable rather than raising.
  """
  @spec build_turn([map()], map(), map()) ::
          {[Block.t()], map(), [Recovery.diagnostic()]}
  def build_turn(events, fold_defaults, session_index \\ %{}) do
    {ordered_keys, groups, tail, item_diags} = fold_items(events)

    # A live approval holds the seal frontier until it is answered. Its
    # seal is a pure function of events: SEALED once a matching
    # `approval_decided` folded into it, LIVE while the question is still
    # open, and SEALED-as-canceled if the turn ended (completed or
    # canceled) with the question never answered -- a live approval must
    # never survive its own turn unresolved, or it would wedge the frontier
    # forever (see `Raxol.Harness.SealFrontier`, G3). The turn-ended check
    # only ever reaches an approval that carries NO decision; a real answer
    # always wins.
    turn_ended? = Enum.any?(events, &turn_terminal?/1)

    completed_groups =
      ordered_keys
      |> Enum.map(&Map.fetch!(groups, &1))
      |> Enum.filter(& &1.completed)
      |> Enum.map(&resolve_approval_seal(&1, turn_ended?))

    {completed_groups, empty_msg_diags} =
      drop_empty_assistant_messages(completed_groups)

    {blocks, block_diags} = build_blocks(completed_groups, fold_defaults)

    blocks =
      blocks
      |> suppress_approval_covered_tool_calls()
      |> suppress_allowed_approval_result_diffs()

    {blocks, completion_diags} =
      attach_final_completion(blocks, events, session_index)

    {blocks, tail,
     item_diags ++ empty_msg_diags ++ block_diags ++ completion_diags}
  end

  # An assistant `:message` item whose sealed content is empty or
  # whitespace-only builds NO block: an empty message is not information
  # — nothing was said, so there is nothing to render, and building it
  # seals a blank ❮ line into the transcript (the live defect: an
  # OpenAI/Anthropic-shaped provider round carrying tool_calls ships its
  # assistant message with content "" — or a bare "\n\n" — next to the
  # real calls). The honest producer now suppresses the item at emission
  # (`Raxol.Agent.Contract.pump/3`'s lazy message open, mirroring its
  # "empty thinking → no ∴ block" rule); this is the projection-side
  # guard for journals recorded before that fix and for producers that
  # lack it. Deliberately NARROW: ONLY assistant messages — an empty USER
  # echo is a producer bug worth seeing, an empty tool_result is a real
  # receipt ("the tool returned nothing" IS information), and reasoning /
  # approval / error / diff groups are untouched. Never fully silent:
  # each suppression emits an `:empty_message_suppressed` diagnostic.
  # Dropping the group BEFORE the lookahead walk also means a
  # tool_use / empty-message / tool_result sandwich merges back into the
  # ONE `:tool_call` block it would have been had the empty item never
  # existed.
  defp drop_empty_assistant_messages(groups) do
    {kept, diags} =
      Enum.reduce(groups, {[], []}, fn group, {kept, diags} ->
        if empty_assistant_message?(group) do
          diag =
            Recovery.emit(
              :empty_message_suppressed,
              Map.get(group.completed, :id)
            )

          {kept, [diag | diags]}
        else
          {[group | kept], diags}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(diags)}
  end

  defp empty_assistant_message?(%{
         singleton: false,
         kind_override: nil,
         item_type: :message,
         completed: %{} = completed
       }) do
    blank_text?(payload_fetch(completed, "content", :content)) and
      not user_role?(payload_fetch(completed, "role", :role))
  end

  defp empty_assistant_message?(_group), do: false

  # A message item_completed with NO content key at all extracts to the
  # same empty text a `content: ""` does, so nil counts as blank; any
  # non-binary shape does NOT (an unexpected term stays fail-visible).
  defp blank_text?(nil), do: true
  defp blank_text?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_text?(_other), do: false

  # Mirrors `Raxol.UI.Components.Harness.Block`'s role normalization:
  # ONLY the exact user marker counts; everything else (including absent)
  # resolves assistant.
  defp user_role?(:user), do: true
  defp user_role?("user"), do: true
  defp user_role?(_other), do: false

  # A RESULTLESS tool_call whose referent a diff-carrying approval block
  # (same turn — this builder is per-turn) already renders: the approval
  # shows the exact proposed change as the ± Pierre image, so the raw
  # `⊘ name args…` line is a duplicate saying the same thing worse (V's
  # ruling). Only resultless calls are covered — a call that DID produce
  # a non-diff result carries information the approval does not (and a
  # failed one is an alarm, which stays regardless).
  defp suppress_approval_covered_tool_calls(blocks) do
    covered =
      for %{kind: :approval, content: %{old: old, new: new} = content} <-
            blocks,
          is_binary(old) and is_binary(new),
          name = Map.get(content, :tool_name) || Map.get(content, :action),
          is_binary(name),
          into: MapSet.new(),
          do: name

    if MapSet.size(covered) == 0 do
      blocks
    else
      Enum.reject(blocks, fn block ->
        block.kind == :tool_call and resultless_tool_call?(block) and
          MapSet.member?(covered, Map.get(block.content, :name))
      end)
    end
  end

  defp resultless_tool_call?(%{content: content}),
    do: Map.get(content, :result) in [nil, ""]

  # Happy path: the thing that appeared is the thing that stays (V's
  # ruling). An ALLOWED diff approval already showed the exact image the
  # apply then wrote — the tool_result's own `:diff` block (`± path ·
  # +N -M`) restates it and is suppressed. A denied/canceled approval
  # covers nothing (no apply happened), and a diff with no covering
  # approval (--yolo) stays — it is the only record of the change.
  defp suppress_allowed_approval_result_diffs(blocks) do
    covered_paths =
      for %{kind: :approval, content: %{old: old, new: new} = content} <-
            blocks,
          is_binary(old) and is_binary(new),
          allowed_decision?(Map.get(content, :decision)),
          path = Map.get(content, :path),
          is_binary(path) and path != "",
          into: MapSet.new(),
          do: path

    if MapSet.size(covered_paths) == 0 do
      blocks
    else
      Enum.reject(blocks, fn block ->
        block.kind == :diff and
          MapSet.member?(covered_paths, Map.get(block.content, :path))
      end)
    end
  end

  defp allowed_decision?(d) when d in [:allow, "allow", :approved, "approved"],
    do: true

  defp allowed_decision?(_d), do: false

  # -- pass 1: item/turn streaming fold -------------------------------------

  defp fold_items(events) do
    init = %{
      order: [],
      groups: %{},
      completed: MapSet.new(),
      deltas: %{},
      delta_cap_hit: MapSet.new(),
      diags: []
    }

    final =
      Enum.reduce(events, init, fn event, acc ->
        fold_event(Map.get(event, :type), event, acc)
      end)

    tail = build_tail(final.groups, final.deltas)

    {Enum.reverse(final.order), final.groups, tail, Enum.reverse(final.diags)}
  end

  # Keyed by `{turn_id, item_id}`, NOT raw `item_id` alone -- item ids
  # are only unique WITHIN a turn (a producer is free to reuse "i1" in
  # turn B after turn A also had an "i1"). Projection.project_turn/3
  # `Map.merge/2`s each turn's tail into a session-wide accumulator; a
  # raw-item_id key would let turn B's unsealed "i1" silently clobber
  # turn A's still-live "i1" in that merge. turn_id comes from the
  # item's own `item_started` event, which always agrees with the outer
  # turn bucket (Recovery.bucket_by_turn/1 groups by that same field).
  defp build_tail(groups, deltas) do
    for {{:item, item_id}, group} <- groups,
        not group.singleton,
        is_nil(group.completed),
        into: %{} do
      turn_id = group.started && Map.get(group.started, :turn_id)

      {{turn_id, item_id},
       %{
         item_type: group.item_type,
         turn_id: turn_id,
         chunks: deltas |> Map.get(item_id, []) |> Enum.reverse()
       }}
    end
  end

  defp fold_event(:item_started, event, acc) do
    item_id = payload_fetch(event, "item_id", :item_id)
    k = item_key(item_id)

    if Map.has_key?(acc.groups, k) do
      acc
    else
      item_type = item_type_atom(payload_fetch(event, "item_type", :item_type))
      group = new_group(item_type: item_type, started: event)
      %{acc | order: [k | acc.order], groups: Map.put(acc.groups, k, group)}
    end
  end

  defp fold_event(:item_delta, event, acc) do
    item_id = payload_fetch(event, "item_id", :item_id)

    if MapSet.member?(acc.completed, item_id) do
      diag = Recovery.emit(:late_delta_after_seal, Map.get(event, :id))
      %{acc | diags: [diag | acc.diags]}
    else
      chunk = payload_fetch(event, "chunk", :chunk) || ""
      existing = Map.get(acc.deltas, item_id, [])
      # prepended; build_tail/2 reverses back to arrival order on read.
      # Sliding window: Enum.take/2 after prepending keeps the newest
      # @max_tail_delta_chunks (head = newest) and drops the oldest.
      updated = Enum.take([chunk | existing], @max_tail_delta_chunks)

      acc =
        if length(existing) >= @max_tail_delta_chunks do
          note_delta_cap_hit(acc, item_id, Map.get(event, :id))
        else
          acc
        end

      %{acc | deltas: Map.put(acc.deltas, item_id, updated)}
    end
  end

  defp fold_event(:item_completed, event, acc) do
    item_id = payload_fetch(event, "item_id", :item_id)
    item_type = item_type_atom(payload_fetch(event, "item_type", :item_type))
    k = item_key(item_id)

    case Map.get(acc.groups, k) do
      nil ->
        diag = Recovery.emit(:orphan_item_completed, Map.get(event, :id))

        group =
          [item_type: item_type, completed: event]
          |> new_group()
          |> maybe_diff_override(event)

        %{
          acc
          | order: [k | acc.order],
            groups: Map.put(acc.groups, k, group),
            completed: MapSet.put(acc.completed, item_id),
            diags: [diag | acc.diags]
        }

      %{completed: nil} = group ->
        updated =
          %{group | item_type: item_type, completed: event}
          |> maybe_diff_override(event)

        %{
          acc
          | groups: Map.put(acc.groups, k, updated),
            completed: MapSet.put(acc.completed, item_id)
        }

      %{completed: %{}} ->
        # Already completed once. The global id-monotonic pass normally
        # prevents a true duplicate id from reaching here; a second,
        # DIFFERENT-id completion for the same item_id is out of scope
        # for the documented policy table -- idempotent, first wins.
        acc
    end
  end

  # Keyed by `request_id` (NOT the event id), so the later
  # `approval_decided` answer folds into THIS group rather than opening a
  # second one. A request with no `request_id` falls back to its own event
  # id -- it stays a unique, rendrable question, it just can never be
  # correlated with a decision (it resolves live, then via the turn-ended
  # safety net).
  defp fold_event(:approval_requested, event, acc) do
    k = approval_key(event)

    group =
      new_group(singleton: true, kind_override: :approval, completed: event)

    %{acc | order: [k | acc.order], groups: Map.put(acc.groups, k, group)}
  end

  # The answer. Folds into the matching request's group as `:decided` (the
  # receipt -- decision/option/scope/who/when), which seals the block and
  # releases the frontier. A decision with no matching request in this turn
  # has no question to render, so it becomes a diagnostic, never a block
  # (fail-loud, never a silent phantom).
  defp fold_event(:approval_decided, event, acc) do
    k = approval_key(event)

    case Map.get(acc.groups, k) do
      %{kind_override: :approval} = group ->
        %{acc | groups: Map.put(acc.groups, k, Map.put(group, :decided, event))}

      _no_matching_request ->
        diag = Recovery.emit(:orphan_approval_decision, Map.get(event, :id))
        %{acc | diags: [diag | acc.diags]}
    end
  end

  defp fold_event(:error, event, acc) do
    k = singleton_key(event)
    group = new_group(singleton: true, kind_override: :error, completed: event)
    %{acc | order: [k | acc.order], groups: Map.put(acc.groups, k, group)}
  end

  # turn_started / turn_completed / state_change / idle: structural,
  # never block-producing on their own (P-TIER-01 ties block-producing
  # kinds to item_completed counts) -- silently not folded into a group.
  defp fold_event(_other, _event, acc), do: acc

  defp new_group(fields) do
    Map.merge(
      %{
        singleton: false,
        kind_override: nil,
        item_type: nil,
        started: nil,
        completed: nil
      },
      Map.new(fields)
    )
  end

  defp item_key(item_id), do: {:item, item_id}
  defp singleton_key(event), do: {:singleton, Map.get(event, :id)}

  # The correlation key shared by an `approval_requested` and its
  # `approval_decided` answer. Prefers the payload `request_id`; a request
  # without one falls back to its own event id (unique, but uncorrelatable
  # with a later decision -- see `fold_event(:approval_requested, ...)`).
  defp approval_key(event) do
    case payload_fetch(event, "request_id", :request_id) do
      nil -> {:approval, {:id, Map.get(event, :id)}}
      request_id -> {:approval, {:req, request_id}}
    end
  end

  # A turn-terminal loop event -- the boundary past which a still-live
  # approval must be resolved (canceled) rather than left holding the
  # frontier. A `turn_completed` counts ONLY when it is FINAL: the tool
  # loop emits an inter-round `turn_completed{final: false}` after every
  # tool round, and a consequential tool in a later round parks on its
  # approval WHILE such inter-round completions have already landed in the
  # turn -- so treating those as terminal would seal a genuinely live
  # question as "canceled." `final` absent defaults to final (fixtures and
  # single-pump turns carry no inter-round markers). `turn_canceled` is
  # always terminal (and defensive: not in the fixture vocabulary, but the
  # live interrupt lane emits it -- a pending approval must resolve, not be
  # ignored).
  defp turn_terminal?(event) do
    case Map.get(event, :type) do
      :turn_canceled -> true
      :turn_completed -> final_completion?(event)
      _other -> false
    end
  end

  defp final_completion?(event) do
    case Map.get(event, :payload) do
      %{} = payload ->
        Map.get(payload, :final, Map.get(payload, "final", true)) == true

      _no_payload ->
        true
    end
  end

  # Stamps an approval group's seal state. SEALED once answered
  # (`:decided` present) or once its turn ended without an answer; LIVE
  # otherwise. Non-approval groups are untouched -- they carry no `:seal`
  # key and `build_block/2` defaults them to `:sealed`, exactly as before.
  #
  # Tool blocks are DELIBERATELY not stamped `:live` here (seal-on-result-
  # only, the parity-safe rendering choice -- see this module's "Tool
  # running state" note below): a tool's `running…` state lives in the
  # footer live-tail preview (driven by render context, not seal state),
  # never as a held block, so a sealed tool line is always its final form
  # and the live/fixture byte-parity guard holds regardless of reveal
  # cadence or compaction.
  defp resolve_approval_seal(%{kind_override: :approval} = group, turn_ended?) do
    sealed? = not is_nil(Map.get(group, :decided)) or turn_ended?
    Map.put(group, :seal, if(sealed?, do: :sealed, else: :live))
  end

  defp resolve_approval_seal(group, _turn_ended?), do: group

  # Emits :delta_buffer_capped exactly once per item_id -- every
  # subsequent delta for the same over-cap item is a silent drop from
  # the buffer's perspective (the window just slides), not a new
  # diagnosable event.
  defp note_delta_cap_hit(acc, item_id, event_id) do
    if MapSet.member?(acc.delta_cap_hit, item_id) do
      acc
    else
      diag = Recovery.emit(:delta_buffer_capped, event_id)

      %{
        acc
        | diags: [diag | acc.diags],
          delta_cap_hit: MapSet.put(acc.delta_cap_hit, item_id)
      }
    end
  end

  # -- pass 2: lookahead merge + Block construction -------------------------

  defp build_blocks([], _fold_defaults), do: {[], []}

  defp build_blocks([g1, g2 | rest], fold_defaults) do
    cond do
      mergeable_pair?(g1, g2) ->
        {block, diag} = build_block([g1, g2], fold_defaults)
        {more_blocks, more_diags} = build_blocks(rest, fold_defaults)
        {[block | more_blocks], diag ++ more_diags}

      diff_covered_pair?(g1, g2) ->
        # The tool_use whose result IS the ± diff: the diff block is the
        # complete render of that action (path-first identity, before/
        # after image) — a separate `⊘ name args…` raw line would say the
        # same thing worse (V's no-raw-output-next-to-the-nice-diff
        # ruling). Only the diff block is built; the tool_use group's
        # events still ride the projection (turn_has_tools?/evidence scan
        # events, never blocks).
        {block, diag} = build_block([g2], fold_defaults)
        {more_blocks, more_diags} = build_blocks(rest, fold_defaults)
        {[block | more_blocks], diag ++ more_diags}

      true ->
        {block, diag} = build_block([g1], fold_defaults)
        {more_blocks, more_diags} = build_blocks([g2 | rest], fold_defaults)
        {[block | more_blocks], diag ++ more_diags}
    end
  end

  defp build_blocks([g], fold_defaults) do
    {block, diag} = build_block([g], fold_defaults)
    {[block], diag}
  end

  # A tool_use + its tool_result merge into ONE :tool_call block -- UNLESS
  # the result is a DIFF (write_file / edit_file): a ± diff is its own block
  # kind (`:diff`, carrying the before/after image), distinct from the tool
  # call that produced it, so it stands alone rather than collapsing into a
  # generic tool row and losing its diff shape (`resolve_kind/1` reads the
  # head group, which for a merged pair is the tool_use -- always `:tool_call`).
  defp mergeable_pair?(g1, g2) do
    well_formed?(g1) and well_formed?(g2) and g1.item_type == :tool_use and
      g2.item_type == :tool_result and Map.get(g2, :kind_override) != :diff
  end

  # The un-mergeable half of the same adjacency: a well-formed tool_use
  # whose well-formed result carries the diff override. The diff block
  # covers the referent, so the tool_use builds no block of its own.
  defp diff_covered_pair?(g1, g2) do
    well_formed?(g1) and well_formed?(g2) and g1.item_type == :tool_use and
      g2.item_type == :tool_result and Map.get(g2, :kind_override) == :diff
  end

  # Stamp a completed tool_result group as a `:diff` block when its event
  # carries the diff marker (`Raxol.Agent.Contract.pump/3` sets it for a
  # before/after file image). Every other completion is untouched.
  defp maybe_diff_override(%{item_type: :tool_result} = group, event) do
    if truthy?(payload_fetch(event, "diff", :diff)) do
      %{group | kind_override: :diff}
    else
      group
    end
  end

  defp maybe_diff_override(group, _event), do: group

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp well_formed?(%{singleton: true}), do: true

  defp well_formed?(%{started: started, completed: completed}),
    do: not is_nil(started) and not is_nil(completed)

  defp build_block(groups, fold_defaults) do
    # `kind` is handed to Block.from_events/3 AS-IS when it falls outside
    # our known vocabulary (the original item_type string/atom, not a
    # pre-resolved :opaque) -- Block's own normalize_kind/1 does that
    # resolution itself and keeps the original in `raw_kind`, which is
    # what makes the opaque render show a real label (contract-only-grows,
    # N-FWD-03) instead of a useless "[opaque]".
    kind = resolve_kind(groups)
    unknown_type? = kind not in Block.known_kinds()
    orphan? = any_orphan?(groups)
    reasons = recovered_reasons(orphan?, unknown_type?)
    events = source_events(groups)
    fold = resolve_fold(fold_defaults, kind, unknown_type?)
    # Every non-approval block seals immediately (there is nothing to wait
    # on). An approval carries its own `:seal` stamp from
    # `resolve_approval_seal/2` -- live until answered or its turn ends.
    seal = block_seal(groups)

    block =
      kind
      |> Block.from_events(events, fold: fold, seal: seal)
      |> fix_duration(kind, events)
      |> stamp_completed_at(events)
      |> flag_recovered(reasons)

    {block, unknown_type_diagnostics(unknown_type?, groups)}
  end

  # A block can be BOTH orphan (no matching item_started) AND
  # unknown-kind (e.g. the adversarial fixture's "custom_widget" item is
  # both at once) -- both are recorded rather than one masking the
  # other, so `content.recovered_reasons` is a complete, honest account
  # of every anomaly this block survived.
  defp any_orphan?(groups),
    do: Enum.any?(groups, &(not &1.singleton and is_nil(&1.started)))

  defp source_events(groups) do
    groups
    |> Enum.flat_map(&[&1.started, &1.completed, Map.get(&1, :decided)])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, :id))
    |> Enum.map(&adapt_event/1)
  end

  # The seal an approval group resolved to (`resolve_approval_seal/2`);
  # every other block defaults to `:sealed`. The merge case passes a
  # 2-group list, but only single-group approval blocks ever carry a
  # `:seal` stamp, so reading the head is exact.
  defp block_seal([%{seal: seal} | _]), do: seal
  defp block_seal(_groups), do: :sealed

  defp resolve_fold(fold_defaults, kind, unknown_type?) do
    lookup_kind = if unknown_type?, do: :opaque, else: kind
    Map.get(fold_defaults, lookup_kind, Block.default_fold(kind))
  end

  defp unknown_type_diagnostics(false, _groups), do: []

  defp unknown_type_diagnostics(true, groups),
    do: [Recovery.emit(:unknown_item_type, block_event_id(groups))]

  defp recovered_reasons(orphan?, unknown_type?) do
    []
    |> maybe_reason(unknown_type?, :unknown_item_type)
    |> maybe_reason(orphan?, :orphan_item_completed)
  end

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp resolve_kind([%{kind_override: kind_override} | _])
       when not is_nil(kind_override),
       do: kind_override

  defp resolve_kind([%{item_type: item_type} | _]),
    do: Map.get(@block_kind_by_item_type, item_type, item_type)

  defp block_event_id([%{completed: completed} | _]),
    do: Map.get(completed, :id)

  # The STATE-note fix, but only when there IS a span to compute: a
  # merged tool_use+tool_result pair spans first-started to
  # last-completed across ≥2 events. A single-event orphan tool_call
  # (recovered from a lone item_completed) has no span -- one timestamp
  # -- so we leave Block's own calculation intact, which yields
  # `duration_ms: nil` ("unknown", the honest value), rather than
  # collapsing max==min to a misleading 0.
  defp fix_duration(block, :tool_call, events) do
    timestamps =
      events |> Enum.map(&Map.get(&1, :ts)) |> Enum.filter(&is_integer/1)

    case timestamps do
      [_first, _second | _rest] = ts ->
        duration_ms = div(Enum.max(ts) - Enum.min(ts), 1000)
        %{block | outcome: %{block.outcome | duration_ms: duration_ms}}

      _no_span ->
        block
    end
  end

  defp fix_duration(block, _kind, _events), do: block

  # The block's wall-clock completion instant (max source-event ts, µs) —
  # the sealed reasoning header's right-edge clock (V's "05:10 AM"
  # ruling) reads it. Absent timestamps stamp nothing (the clock simply
  # does not render — never a fabricated time).
  defp stamp_completed_at(block, events) do
    case events |> Enum.map(&Map.get(&1, :ts)) |> Enum.filter(&is_integer/1) do
      [] ->
        block

      ts ->
        %{
          block
          | outcome: Map.put(block.outcome, :completed_at_us, Enum.max(ts))
        }
    end
  end

  defp flag_recovered(block, []), do: block

  defp flag_recovered(block, reasons) do
    # The two keys here are the SAME [:recovered, :recovered_reasons]
    # pair `Projection.transcript_identity/1` strips back out --
    # `Recovery.recovery_meta_keys/0` is the one shared source so
    # flagging and stripping can never drift out of sync.
    [recovered_key, recovered_reasons_key] = Recovery.recovery_meta_keys()

    %{
      block
      | content:
          Map.merge(block.content, %{
            recovered_key => true,
            recovered_reasons_key => reasons
          })
    }
  end

  # -- completion evidence (the honesty row) ---------------------------------

  # The literal, rendered-verbatim label for a ref the session index has
  # no event for at all -- an unresolvable ref is information, never
  # silently dropped (design creed). Shared by resolution AND the
  # honesty-pin tests, so the two can never drift apart.
  @unresolvable_evidence_label "unresolvable evidence ref"

  defp attach_final_completion(blocks, events, session_index) do
    case find_final_turn_completed(events) do
      nil -> {blocks, []}
      final_event -> apply_final_completion(blocks, final_event, session_index)
    end
  end

  # A `turn_completed{final: true}` whose payload carries an atom OR
  # string "final" key; the LAST one wins if a turn somehow carried more
  # than one (defensive -- real producers emit exactly one per turn).
  defp find_final_turn_completed(events) do
    events
    |> Enum.filter(fn event ->
      Map.get(event, :type) == :turn_completed and
        payload_fetch(event, "final", :final) == true
    end)
    |> List.last()
  end

  # No blocks in a turn that DID close with a final claim: nothing to
  # attach honesty to, and `turn_completed` never synthesizes a block on
  # its own (the frozen P-TIER-01 tier law) -- diagnose instead.
  defp apply_final_completion([], final_event, _session_index) do
    diag =
      Recovery.emit(:final_completion_without_blocks, Map.get(final_event, :id))

    {[], [diag]}
  end

  defp apply_final_completion(blocks, final_event, session_index) do
    claiming_turn_id = Map.get(final_event, :turn_id)

    completion =
      final_event
      |> final_refs()
      |> build_completion(blocks, session_index, claiming_turn_id)

    {merge_completion_into_last(blocks, completion), []}
  end

  defp final_refs(event), do: payload_fetch(event, "refs", :refs)

  defp build_completion(refs, _blocks, _session_index, _claiming_turn_id)
       when not is_list(refs),
       do: %{evidence: :none}

  defp build_completion([], _blocks, _session_index, _claiming_turn_id),
    do: %{evidence: :none}

  defp build_completion(refs, blocks, session_index, claiming_turn_id) do
    total = length(refs)

    # Every ref's TYPE feeds the summary line's breakdown (accurate even
    # for refs beyond the cap); only the first @max_completion_entries
    # get a full resolved label -- both are single, cheap session-index
    # lookups, so computing type for all refs costs nothing extra.
    type_counts =
      refs
      |> Enum.map(&ref_type(&1, session_index))
      |> compute_type_counts()

    # Same discipline as type_counts: tallied over ALL refs, not just the
    # capped entries -- a cross-turn ref pushed past the cap must still
    # be disclosed in the summary line (see the moduledoc's "Cross-turn
    # disclosure").
    cross_turn_total =
      Enum.count(refs, &cross_turn_ref?(&1, session_index, claiming_turn_id))

    entries =
      refs
      |> Enum.take(@max_completion_entries)
      |> Enum.map(
        &resolve_completion_entry(&1, blocks, session_index, claiming_turn_id)
      )

    base = %{evidence: entries, total: total, type_counts: type_counts}

    # Added ONLY when > 0 (put_present style): an all-same-turn
    # completion's map shape is byte-identical to before this fix --
    # the no-churn pin.
    if cross_turn_total > 0 do
      Map.put(base, :cross_turn_count, cross_turn_total)
    else
      base
    end
  end

  defp merge_completion_into_last(blocks, completion) do
    List.update_at(blocks, -1, fn block ->
      %{block | content: Map.put(block.content, :completion, completion)}
    end)
  end

  # -- session-scoped ref resolution ------------------------------------------
  #
  # A ref is a session-wide journal offset (the frozen offset law), not a
  # turn-scoped one -- `session_index` (built once by `Projection.project/2`
  # over the WHOLE id-recovered stream) is the base resolution for both
  # type and label. `blocks` (this turn's own built blocks) is consulted
  # ONLY as a same-turn label enrichment (a nicer, already-extracted tool
  # name) and is naturally a no-op for a ref pointing at an earlier turn.
  # `claiming_turn_id` is the CLAIMING turn's own turn_id (the final
  # turn_completed event's `turn_id`) -- the reference point every
  # resolved event's own `turn_id` is compared against for cross-turn
  # disclosure (see the moduledoc).

  defp ref_type(ref, session_index) do
    case Map.get(session_index, ref) do
      nil -> :unresolvable
      event -> entry_type(event)
    end
  end

  # An unresolvable ref (no event in the session index at all) is never
  # cross-turn -- there is no resolved event to compare a turn_id
  # against, and "cross-turn" is a disclosure about WHICH turn a real
  # citation came from, not a synonym for "unresolvable".
  defp cross_turn_ref?(ref, session_index, claiming_turn_id) do
    case Map.get(session_index, ref) do
      nil -> false
      event -> cross_turn_event?(event, claiming_turn_id)
    end
  end

  defp cross_turn_event?(event, claiming_turn_id),
    do: Map.get(event, :turn_id) != claiming_turn_id

  defp resolve_completion_entry(ref, blocks, session_index, claiming_turn_id) do
    case Map.get(session_index, ref) do
      nil ->
        %{ref: ref, type: :unresolvable, label: @unresolvable_evidence_label}

      event ->
        type = entry_type(event)

        base = %{
          ref: ref,
          type: type,
          label: entry_label(ref, event, type, blocks)
        }

        if cross_turn_event?(event, claiming_turn_id) do
          Map.put(base, :cross_turn, true)
        else
          base
        end
    end
  end

  # `type` is the resolved event's own `item_type` when it is an
  # `item_completed` (`:tool_result`, `:message`, `:reasoning`,
  # `:tool_use`); anything else -- a different event type, a missing or
  # unrecognised `item_type` -- is `:unknown` (never raises, never
  # invents a vocabulary this module doesn't already know).
  defp entry_type(event) do
    if Map.get(event, :type) == :item_completed do
      case item_type_atom(payload_fetch(event, "item_type", :item_type)) do
        known when known in [:message, :reasoning, :tool_use, :tool_result] ->
          known

        _unrecognised ->
          :unknown
      end
    else
      :unknown
    end
  end

  # Prefer a same-turn :tool_call block's own name (already extracted and
  # display-ready by `extract_tool_call_content/1`) -- naturally absent
  # for a cross-turn ref, since `blocks` here is only THIS turn's own
  # built blocks -- falling back to the raw event's own `"name"` payload
  # field. That name, when present, is joined via `" — "` with the
  # event's content's first non-blank line; either alone stands on its
  # own; the type name itself is the last-resort fallback when neither
  # resolves to anything displayable. Never raises.
  defp entry_label(ref, event, type, blocks) do
    name =
      find_tool_call_name(ref, blocks) ||
        present(payload_fetch(event, "name", :name))

    content_line =
      event |> payload_fetch("content", :content) |> first_nonblank_line()

    candidate =
      case {present(name), present(content_line)} do
        {nil, nil} -> Atom.to_string(type)
        {name, nil} -> name
        {nil, content} -> content
        {name, content} -> name <> " — " <> content
      end

    candidate
    |> to_string()
    |> sanitize_completion_label()
    |> finalize_completion_label(Atom.to_string(type))
  end

  defp find_tool_call_name(ref, blocks) do
    Enum.find_value(blocks, fn block ->
      with :tool_call <- block.kind,
           true <- ref in block.event_refs,
           name when is_binary(name) and name != "" <-
             Map.get(block.content, :name) do
        name
      else
        _no_match -> nil
      end
    end)
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_other), do: nil

  defp first_nonblank_line(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.find(&(String.trim(&1) != ""))
  end

  defp first_nonblank_line(_other), do: nil

  # Descending count, ties broken by first-appearance order among the
  # refs list -- deterministic (pure function of `types`, no ambient
  # state) so the summary line never varies run to run for the same
  # input, matching this module's overall P-DET discipline. Returned as
  # `%{type:, count:}` maps, NOT `{type, count}` tuples -- this list
  # rides inside `Block.content`, which the T7/TF bless tasks round-trip
  # through `Jason.encode!/1`; Jason has no `Encoder` for tuples, so a
  # tuple here would crash every snapshot bless, not just render.
  defp compute_type_counts(types) do
    types
    |> Enum.with_index()
    |> Enum.group_by(fn {type, _idx} -> type end)
    |> Enum.map(fn {type, occurrences} ->
      first_idx = occurrences |> Enum.map(&elem(&1, 1)) |> Enum.min()
      {type, length(occurrences), first_idx}
    end)
    |> Enum.sort_by(fn {_type, count, first_idx} -> {-count, first_idx} end)
    |> Enum.map(fn {type, count, _first_idx} -> %{type: type, count: count} end)
  end

  # Strips every C0 control byte (0x00-0x1F, which includes ESC/0x1B) and
  # DEL (0x7F), byte-wise -- mirrors `Raxol.Harness.Surface.ViewText.
  # sanitize/1`'s technique and safety argument verbatim: multi-byte
  # UTF-8 lead (0xC2-0xF4) and continuation (0x80-0xBF) bytes are both
  # `>= 0x20`, so stripping byte-by-byte never splits a valid codepoint.
  # UNLIKE that sanitizer, `\t` gets NO exception here: a completion
  # label is a single inline cell, never a multi-column layout, so a
  # stray tab has no legitimate rendering role and is stripped like every
  # other C0 byte (so is the `\n` that sanitizer also has no reason to
  # exempt for a one-line label).
  defp sanitize_completion_label(text) do
    for <<byte <- text>>, byte >= 0x20 and byte != 0x7F,
      into: <<>>,
      do: <<byte>>
  end

  # `fallback` (the resolved event's own type name) covers the rare case
  # where a REAL event resolved but its name/content sanitized down to
  # nothing (e.g. a tool result that was pure control bytes) -- distinct
  # from `@unresolvable_evidence_label`, which is reserved for a ref the
  # session index has no event for at all (see `resolve_completion_entry/3`).
  defp finalize_completion_label("", fallback), do: fallback

  defp finalize_completion_label(label, _fallback),
    do: TextLayout.truncate(label, @completion_label_width, :ellipsis)

  # -- event/payload adapter -------------------------------------------------
  #
  # Fixture payloads are string-keyed JSON maps (Raxol.Harness.Fixture.Event);
  # Block.from_events/3's path-based extraction (block.ex @*_paths) expects
  # atom keys, and its `:args` name doesn't match the wire's `"arguments"`.
  # This adapter is the deliberate translation layer -- it builds a fresh
  # atom-keyed payload from a small, fixed vocabulary (no String.to_atom on
  # untrusted input: every atom below is a literal already compiled into
  # this module).

  defp adapt_event(event) do
    %{
      id: Map.get(event, :id),
      turn_id: Map.get(event, :turn_id),
      ts: Map.get(event, :ts),
      type: Map.get(event, :type),
      tier: Map.get(event, :tier),
      provenance: Map.get(event, :provenance),
      payload: adapt_payload(Map.get(event, :payload))
    }
  end

  # Direct passthrough fields: same string key on the wire as the atom
  # key Block's path-based extraction (block.ex @*_paths) looks up. The
  # `tool_name`/`decision`/`option_id`/`scope`/`decided_by`/`decided_at`
  # keys carry the approval referent + decision receipt through to
  # `Block.extract_approval_content/1` (`request_id` is consumed earlier,
  # for correlation, and is not needed in the rendered payload).
  @direct_payload_keys ~w(content name action blast_radius options exit_code cost duration_ms where reason tool_name request_id decision option_id scope decided_by decided_at path old new language preview_match)a

  defp adapt_payload(payload) when is_map(payload) do
    base =
      Enum.reduce(@direct_payload_keys, %{}, fn key, acc ->
        put_present(acc, key, fetch(payload, Atom.to_string(key), key))
      end)

    base
    |> put_present(
      :item_type,
      item_type_atom(fetch(payload, "item_type", :item_type))
    )
    |> put_present(
      :args,
      fetch(payload, "arguments", :arguments) || fetch(payload, "args", :args)
    )
    # Speaker attribution rides the wire as `role` on message items --
    # passed through RAW: Block.extract_content/2 owns the normalization
    # (only an exact user marker becomes :user; anything else, including
    # hostile strings, resolves :assistant), so this seam adds no second
    # vocabulary of its own.
    |> put_present(:role, fetch(payload, "role", :role))
  end

  defp adapt_payload(_payload), do: %{}

  defp payload_fetch(event, string_key, atom_key) do
    case Map.get(event, :payload) do
      %{} = payload -> fetch(payload, string_key, atom_key)
      _other -> nil
    end
  end

  defp fetch(payload, string_key, atom_key),
    do: Map.get(payload, string_key, Map.get(payload, atom_key))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp item_type_atom(nil), do: nil

  defp item_type_atom(atom)
       when atom in [:message, :reasoning, :tool_use, :tool_result], do: atom

  defp item_type_atom(str) when is_binary(str),
    do: Map.get(@known_item_types, str, str)

  defp item_type_atom(other), do: other
end
