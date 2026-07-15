defmodule Raxol.Harness.Projection.Recovery do
  @moduledoc """
  Cross-cutting recovery mechanics shared by `Raxol.Harness.Projection`:
  the global id-monotonic filter (N-ADV-02/03/forward-gap), family
  partitioning (loop vs meta vs untyped, N-DORM-04), turn bucketing in
  first-seen order (N-ADV-05), and the single diagnostic-emission seam
  every recovered condition goes through.

  Every recovery emits `[:raxol, :harness, :projection, :recovered]`
  telemetry with `%{reason, event_id}` -- the same event
  `Raxol.UI.Components.Harness.Block` uses for its own internal
  rescues. Recovery here is never silent: see `Raxol.Harness.Projection`'s
  moduledoc for the recovery policy table and the two identity keys this
  feeds.
  """

  require Logger

  @recovered_event [:raxol, :harness, :projection, :recovered]

  # The two block.content keys used to flag ("hard mark", BlockBuilder's
  # flag_recovered/2) and later strip (`Projection.transcript_identity/1`)
  # recovery provenance. Kept in ONE place so flagging and stripping can
  # never drift out of sync with each other.
  @recovery_meta_keys [:recovered, :recovered_reasons]

  @type diagnostic :: %{reason: atom(), event_id: term()}

  @doc "The block.content keys that carry recovery provenance metadata."
  @spec recovery_meta_keys() :: [atom()]
  def recovery_meta_keys, do: @recovery_meta_keys

  @doc """
  Emits one recovery diagnostic: fires the telemetry event and returns
  the diagnostic map so callers can also accumulate it in
  `t.diagnostics`.
  """
  @spec emit(atom(), term()) :: diagnostic()
  def emit(reason, event_id) do
    Logger.warning(
      "Harness.Projection recovered from #{inspect(reason)} (event #{inspect(event_id)})"
    )

    :telemetry.execute(@recovered_event, %{}, %{
      reason: reason,
      event_id: event_id
    })

    %{reason: reason, event_id: event_id}
  end

  @doc """
  Global id-monotonic recovery pass, applied across BOTH `:loop` and
  `:meta` events (a single session-wide journal offset, protocol §3):

    * a duplicate `id` (already accepted) is dropped -- idempotent,
      second application is a no-op (N-ADV-03).
    * an out-of-order `id` (lower than the highest accepted so far, and
      not itself a duplicate) is dropped loud (N-ADV-02).
    * a forward gap -- an id strictly more than one past the highest
      accepted so far (e.g. ids 1, 2, 5 with 3 and 4 never arriving) --
      is accepted (soft-render: the survivor blocks are not withheld)
      but diagnosed loud AND marks the returned `damaged?` flag `true`
      (hard-mark). Mirrors `Raxol.Agent.Journal`'s own interior-loss
      contract (`status/1` -> `:damaged`): the journal fails closed
      upstream on real corruption, so a gap reaching this filter means
      dense-id events were dropped somewhere between journal and here.
      This projection's job is diagnose + mark, not withhold, so a
      downstream consumer (T18) can refuse a gapped tail as canonical
      without losing the events that DID survive.

  The very first id accepted in a given `filter_ids/1` call is exempt
  from both the out-of-order and forward-gap checks -- there is no
  "highest accepted so far" yet, and a call may legitimately start
  mid-stream (a suffix replay from a durable block boundary, offset-based
  reattach, etc.) where the first id is not `0`/`1`.

  Events without an integer `id` (the untyped-record generator case)
  bypass this check entirely -- they have no ordering semantics to
  violate -- and are handled by `partition_families/1` instead.
  """
  @spec filter_ids([map()]) :: {[map()], [diagnostic()], boolean()}
  def filter_ids(events) do
    {accepted, _seen, _max_id, diagnostics, damaged?} =
      Enum.reduce(
        events,
        {[], MapSet.new(), nil, [], false},
        &apply_id_recovery/2
      )

    {Enum.reverse(accepted), Enum.reverse(diagnostics), damaged?}
  end

  defp apply_id_recovery(event, {acc, seen, max_id, diags, damaged?}) do
    case Map.get(event, :id) do
      id when is_integer(id) ->
        classify_id(event, id, acc, seen, max_id, diags, damaged?)

      _not_integer ->
        {[event | acc], seen, max_id, diags, damaged?}
    end
  end

  defp classify_id(event, id, acc, seen, max_id, diags, damaged?) do
    cond do
      MapSet.member?(seen, id) ->
        diag = emit(:duplicate_id, id)
        {acc, seen, max_id, [diag | diags], damaged?}

      not is_nil(max_id) and id < max_id ->
        diag = emit(:out_of_order_id, id)
        {acc, seen, max_id, [diag | diags], damaged?}

      not is_nil(max_id) and id > max_id + 1 ->
        diag = emit(:forward_id_gap, id)
        {[event | acc], MapSet.put(seen, id), id, [diag | diags], true}

      true ->
        {[event | acc], MapSet.put(seen, id), id, diags, damaged?}
    end
  end

  @doc """
  Splits already id-recovered events into `{loop_events, meta_events,
  diagnostics}`. `:meta` events are legal interleaving (no diagnostic,
  P-DET-06). Anything with neither `family: :loop` nor `family: :meta`
  (missing, `nil`, or unrecognised) is the FI-12-mirrored untyped
  record: excluded from both, diagnosed (N-DORM-04).

  A `family: :loop` record whose `:type` is not an atom (e.g. a
  string `"item_started"` surviving from a malformed/legacy producer)
  would otherwise reach `BlockBuilder.fold_event/3`'s catch-all clause
  and be dropped with NO diagnostic -- the same silent-discard failure
  mode this module exists to prevent. Guarded here instead: a non-atom
  `:type` on an otherwise-loop record is treated as untyped too.
  """
  @spec partition_families([map()]) :: {[map()], [map()], [diagnostic()]}
  def partition_families(events) do
    {loop, meta, diags} =
      Enum.reduce(events, {[], [], []}, fn event, {loop, meta, diags} ->
        case classify_family(event) do
          :loop ->
            {[event | loop], meta, diags}

          :meta ->
            {loop, [event | meta], diags}

          :untyped ->
            {loop, meta, [emit(:untyped_record, Map.get(event, :id)) | diags]}
        end
      end)

    {Enum.reverse(loop), Enum.reverse(meta), Enum.reverse(diags)}
  end

  defp classify_family(event) do
    case {Map.get(event, :family), Map.get(event, :type)} do
      {:loop, type} when is_atom(type) -> :loop
      {:meta, _type} -> :meta
      _other -> :untyped
    end
  end

  @doc """
  Groups events by `turn_id`, preserving FIRST-SEEN turn order (not
  raw id/arrival order) so interleaved turns render grouped, never
  cross-bled (N-ADV-05). Each turn's own event list keeps its original
  relative order.
  """
  @spec bucket_by_turn([map()]) :: [{term(), [map()]}]
  def bucket_by_turn(events) do
    {order, groups} =
      Enum.reduce(events, {[], %{}}, fn event, {order, groups} ->
        turn_id = Map.get(event, :turn_id)

        order =
          if Map.has_key?(groups, turn_id), do: order, else: [turn_id | order]

        groups = Map.update(groups, turn_id, [event], &[event | &1])
        {order, groups}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn turn_id ->
      {turn_id, groups |> Map.fetch!(turn_id) |> Enum.reverse()}
    end)
  end

  @doc "Whether this turn's event list never saw a `turn_started` event."
  @spec missing_turn_started?([map()]) :: boolean()
  def missing_turn_started?(events) do
    not Enum.any?(events, &(Map.get(&1, :type) == :turn_started))
  end
end
