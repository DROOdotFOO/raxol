defmodule Raxol.Harness.Projection do
  @moduledoc """
  The journal-fold projection: durable events -> an ordered block list;
  ephemeral `item_delta` -> a live-tail state, never a durable block.

  Roadmap unit T7 (journal-fold projection). Test design covers P-DET/
  P-TIER/P-FOLD properties, N-ADV/N-DORM/N-SEAL/N-FWD negatives, and the
  recovery policy table documented inline across this module,
  `Raxol.Harness.Projection.Recovery`, and
  `Raxol.Harness.Projection.BlockBuilder`.

  ## Pipeline

  `project/2` accepts either a `Raxol.Harness.Fixture.Session` (loaded
  from a `.jsonl` fixture) or a plain list of event-shaped maps (the
  property-test generators build these directly, matching the fixture
  wire shape -- string-keyed payloads, atom top-level fields):

    1. `Raxol.Harness.Projection.Recovery.filter_ids/1` -- global
       id-monotonic recovery: duplicate/out-of-order (N-ADV-02/03) are
       dropped; a forward gap (a dense-id journal missing one or more
       ids, e.g. 1, 2, 5 with 3 and 4 never arriving) is accepted --
       soft-render, survivor blocks are never withheld -- but sets
       `damaged?: true` (hard-mark) on the returned tuple, threaded onto
       the `%__MODULE__{}` struct's `damaged` field. Mirrors
       `Raxol.Agent.Journal`'s own `status/1 :: :damaged` contract: the
       journal fails closed on interior corruption upstream, so a gap
       reaching this filter means events were lost somewhere between
       journal and here -- diagnose and mark, don't withhold, so a
       downstream consumer (T18) can refuse a gapped tail as canonical.
    2. `Recovery.partition_families/1` -- `:loop` vs `:meta` vs
       untyped/unrecognised (N-DORM-04, including a non-atom `:type` on
       an otherwise-loop record); only `:loop` events ever become blocks.
    3. `Recovery.bucket_by_turn/1` -- groups by `turn_id` in
       first-seen order (N-ADV-05), independent of raw arrival order.
    4. `Raxol.Harness.Projection.BlockBuilder.build_turn/2` per turn --
       folds items into blocks, drops late deltas (N-SEAL), caps the
       live-tail delta buffer for an item that never completes, flags
       orphans/unknown kinds recovered (N-ADV-04, N-FWD-01), merges
       well-formed `tool_use`+`tool_result` pairs into one `:tool_call`
       block and fixes its duration span (the STATE-note bug: Block's
       own `duration_from_timestamps/1` only sees the first
       started/completed pair in a merged list).

  Every recovered condition -- duplicate, out-of-order, forward gap,
  orphan, late delta, capped delta buffer, missing turn_started, untyped
  record, unknown item_type -- emits
  `[:raxol, :harness, :projection, :recovered]` telemetry via
  `Recovery.emit/2`. Recovery is never silent; the resulting
  `durable_block_list` is always deterministic (same input, same
  output, no ambient state).

  ## The `damaged` field

  `true` iff `Recovery.filter_ids/1` detected at least one forward id
  gap in the input. This is projection-level METADATA, not transcript
  content: it is not part of either `transcript_identity/1` or
  `identity/1` (both operate on `blocks`/`fold_defaults` only, never on
  this field), so a gap detection can never perturb either identity key
  -- exactly like `content.recovered`/`content.recovered_reasons` are
  excluded from `transcript_identity/1`. Hard mark (the struct flag),
  soft render (the survivor blocks are still returned in full).

  ## Retained raw events (STATE note)

  `source_events` holds every event that survived the id-recovery pass
  and is NOT `:ephemeral` tier -- both families, but durable-only. D-PA
  policy (B) soft-owned-history re-emission and retroactive opaque-kind
  recognition both need to re-fold from the original DURABLE events, not
  just the block structs (P-TIER-03: ephemeral deltas never affect
  identity); `refold/2` re-runs the pipeline over that retained list
  with no fixture re-read. One consequence: refolding a projection whose
  session had an item still accumulating deltas at capture time yields
  an EMPTY tail post-refold (the ephemeral chunks that fed it are gone)
  -- acceptable, since `refold/2` rebuilds durable history, not the live
  stream, and `identity/1`/`transcript_identity/1` never look at `tail`.

  ## Two identity keys — pick the one that matches the question

  There are two distinct "is this the same?" questions, and conflating
  them churns downstream diffs. Both key blocks by `event_refs` and
  exclude a block's mutable `fold` field (a UI-local toggle never
  perturbs either key — leak-guard #1).

  ### `transcript_identity/1` — the reattach-consistency key (T18)

  "Is this the same *conversation*?" The block list, each block reduced
  to `{kind, raw_kind, event_refs, seal, outcome, content}` with
  `content` **stripped of `:recovered` / `:recovered_reasons`**, and
  **`fold_defaults` excluded entirely**. Rationale:

    * `fold_defaults` is a per-*surface* display preference — two
      surfaces reattaching the same journal needn't agree on folding,
      so it is not part of "same transcript".
    * `:recovered` / `:recovered_reasons` are recovery *metadata*, not
      visible transcript content — a recovery re-annotation must not
      make "same transcript?" answer false.

  This is the key T18's restoration-diff-on-reattach uses: without the
  strips it would churn on every fold toggle or recovery re-annotation.

  ### `identity/1` — the T13a regression FREEZE key

  ```
  identity(fixture) = {transcript_identity_blocks, fold_defaults}
  ```

  The transcript block shape **plus** `fold_defaults`. Here a
  `fold_default` change is a *wanted* diff (leak-guard #2) — it's the
  reviewed tripwire the `<name>.t7blocks.json` snapshot freezes. Use
  this for the golden-snapshot regression gate, `transcript_identity/1`
  for "did the conversation change".

  Explicitly NOT in either key: UI-local fold toggles, scroll position,
  the live tail buffer, ephemeral deltas, salience/prominence (D-PA
  scoped, tested elsewhere), meta-family events.

  ## The reattach convergence invariant (load-bearing for T18)

  Two surfaces attaching at different journal offsets converge to the
  same `transcript_identity/1` **only when replay is in journal-offset
  order** — ids strictly monotonic, physical offset canonical. Replaying
  from a *peer's live tail* (whose transient, mid-stream out-of-order
  drops and late-delta discards differ from a clean journal walk) is NOT
  guaranteed to converge. The journal is the source of truth; the tail
  is a throwaway preview. T18's restoration diff must always rebuild from
  the durable journal in offset order, never from another surface's tail.
  """

  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.Projection.{BlockBuilder, Recovery}
  alias Raxol.UI.Components.Harness.Block

  @enforce_keys [
    :blocks,
    :tail,
    :fold_defaults,
    :diagnostics,
    :source_events,
    :damaged
  ]
  defstruct [
    :blocks,
    :tail,
    :fold_defaults,
    :diagnostics,
    :source_events,
    :damaged
  ]

  @type tail_entry :: %{
          item_type: term(),
          turn_id: term(),
          chunks: [String.t()]
        }

  @type t :: %__MODULE__{
          blocks: [Block.t()],
          tail: %{
            optional({turn_id :: term(), item_id :: term()}) => tail_entry()
          },
          fold_defaults: %{optional(Block.kind()) => Block.fold_state()},
          diagnostics: [Recovery.diagnostic()],
          source_events: [map()],
          damaged: boolean()
        }

  @doc """
  Projects a fixture `Session` (or a plain list of event-shaped maps)
  into a `t()`. Pure: identical input + options always produce an
  identical result (P-DET-01).

  Options:

    * `:fold_defaults` -- a `%{Block.kind() => Block.fold_state()}`
      map overriding `Block.default_fold/1` per kind. Part of
      `identity/1` -- see the moduledoc.
  """
  @spec project(Session.t() | [map()], keyword()) :: t()
  def project(session_or_events, opts \\ [])

  def project(%Session{envelopes: envelopes}, opts) do
    project(Enum.map(envelopes, & &1.body), opts)
  end

  def project(events, opts) when is_list(events) do
    fold_defaults = resolve_fold_defaults(opts)

    {id_ok, id_diags, damaged?} = Recovery.filter_ids(events)

    {loop_events, _meta_events, family_diags} =
      Recovery.partition_families(id_ok)

    {blocks, tail, fold_diags} =
      loop_events
      |> Recovery.bucket_by_turn()
      |> Enum.reduce({[], %{}, []}, &project_turn(&1, &2, fold_defaults))

    %__MODULE__{
      blocks: blocks,
      tail: tail,
      fold_defaults: fold_defaults,
      diagnostics: id_diags ++ family_diags ++ fold_diags,
      # Durable-only retention (STATE note): P-TIER-03 established that
      # ephemeral deltas never affect identity, so refold/2's re-fold
      # base need not (and per D-PA policy (B), should not) carry them.
      source_events: Enum.reject(id_ok, &(Map.get(&1, :tier) == :ephemeral)),
      damaged: damaged?
    }
  end

  defp project_turn(
         {turn_id, turn_events},
         {blocks_acc, tail_acc, diags_acc},
         fold_defaults
       ) do
    turn_diags =
      if turn_id != nil and Recovery.missing_turn_started?(turn_events) do
        [Recovery.emit(:missing_turn_started, first_event_id(turn_events))]
      else
        []
      end

    {turn_blocks, turn_tail, item_diags} =
      BlockBuilder.build_turn(turn_events, fold_defaults)

    {
      blocks_acc ++ turn_blocks,
      Map.merge(tail_acc, turn_tail),
      diags_acc ++ turn_diags ++ item_diags
    }
  end

  defp first_event_id([event | _rest]), do: Map.get(event, :id)
  defp first_event_id([]), do: nil

  defp resolve_fold_defaults(opts) do
    overrides = Keyword.get(opts, :fold_defaults, %{})

    [:opaque | Block.known_kinds()]
    |> Map.new(fn kind ->
      {kind, Map.get(overrides, kind, Block.default_fold(kind))}
    end)
  end

  @doc """
  Re-runs the projection over its own retained `source_events` -- the
  re-fold hook D-PA policy (B) and retroactive opaque-kind recognition
  need (STATE note). No fixture re-read; `opts` can supply a different
  `:fold_defaults` for the re-fold.
  """
  @spec refold(t(), keyword()) :: t()
  def refold(projection, opts \\ [])

  def refold(%__MODULE__{source_events: source_events}, opts) do
    project(source_events, opts)
  end

  @doc """
  The reattach-consistency key (T18): the block list, each block keyed
  by `event_refs` and reduced to
  `{kind, raw_kind, event_refs, seal, outcome, content}` with `content`
  stripped of `:recovered` / `:recovered_reasons`. Excludes
  `fold_defaults` (a per-surface display preference) and the mutable
  `fold` field. This is the "is this the same conversation?" key — see
  the moduledoc's convergence invariant.
  """
  @spec transcript_identity(t()) :: [map()]
  def transcript_identity(%__MODULE__{blocks: blocks}) do
    Enum.map(blocks, &transcript_block/1)
  end

  defp transcript_block(%Block{} = block) do
    %{
      kind: block.kind,
      raw_kind: block.raw_kind,
      event_refs: block.event_refs,
      seal: block.seal,
      outcome: block.outcome,
      content: Map.drop(block.content, Recovery.recovery_meta_keys())
    }
  end

  @doc """
  The T13a regression FREEZE key:
  `{transcript_identity_blocks, fold_defaults}`. Unlike
  `transcript_identity/1`, a `fold_default` change here is a wanted diff
  (leak-guard #2) — this is what the `<name>.t7blocks.json` snapshot
  freezes. See the moduledoc for both keys' contracts.
  """
  @spec identity(t()) :: {[map()], map()}
  def identity(%__MODULE__{fold_defaults: fold_defaults} = projection) do
    {transcript_identity(projection), fold_defaults}
  end

  @doc """
  The last durable block -- the tip a resumed/rebuilt view must land
  on. Since `blocks` never contains a meta or untyped record (they're
  excluded before block-building ever runs), this is always the last
  legitimately conversational block, never a non-conversational
  record (N-DORM / FI-12 mirrored).
  """
  @spec tip(t()) :: Block.t() | nil
  def tip(%__MODULE__{blocks: blocks}), do: List.last(blocks)
end
