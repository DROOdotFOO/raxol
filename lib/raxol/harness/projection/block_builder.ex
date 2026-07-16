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
  """

  alias Raxol.Harness.Projection.Recovery
  alias Raxol.UI.Components.Harness.Block

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
  """
  @spec build_turn([map()], map()) ::
          {[Block.t()], map(), [Recovery.diagnostic()]}
  def build_turn(events, fold_defaults) do
    {ordered_keys, groups, tail, item_diags} = fold_items(events)

    completed_groups =
      ordered_keys
      |> Enum.map(&Map.fetch!(groups, &1))
      |> Enum.filter(& &1.completed)

    {blocks, block_diags} = build_blocks(completed_groups, fold_defaults)

    {blocks, tail, item_diags ++ block_diags}
  end

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
        group = new_group(item_type: item_type, completed: event)

        %{
          acc
          | order: [k | acc.order],
            groups: Map.put(acc.groups, k, group),
            completed: MapSet.put(acc.completed, item_id),
            diags: [diag | acc.diags]
        }

      %{completed: nil} = group ->
        updated = %{group | item_type: item_type, completed: event}

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

  defp fold_event(:approval_requested, event, acc) do
    k = singleton_key(event)

    group =
      new_group(singleton: true, kind_override: :approval, completed: event)

    %{acc | order: [k | acc.order], groups: Map.put(acc.groups, k, group)}
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
    if mergeable_pair?(g1, g2) do
      {block, diag} = build_block([g1, g2], fold_defaults)
      {more_blocks, more_diags} = build_blocks(rest, fold_defaults)
      {[block | more_blocks], diag ++ more_diags}
    else
      {block, diag} = build_block([g1], fold_defaults)
      {more_blocks, more_diags} = build_blocks([g2 | rest], fold_defaults)
      {[block | more_blocks], diag ++ more_diags}
    end
  end

  defp build_blocks([g], fold_defaults) do
    {block, diag} = build_block([g], fold_defaults)
    {[block], diag}
  end

  defp mergeable_pair?(g1, g2) do
    well_formed?(g1) and well_formed?(g2) and g1.item_type == :tool_use and
      g2.item_type == :tool_result
  end

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

    block =
      kind
      |> Block.from_events(events, fold: fold, seal: :sealed)
      |> fix_duration(kind, events)
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
    |> Enum.flat_map(&[&1.started, &1.completed])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, :id))
    |> Enum.map(&adapt_event/1)
  end

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
  # key Block's path-based extraction (block.ex @*_paths) looks up.
  @direct_payload_keys ~w(content name action blast_radius options exit_code cost duration_ms where reason)a

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
