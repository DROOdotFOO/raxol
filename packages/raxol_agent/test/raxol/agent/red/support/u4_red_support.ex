defmodule Raxol.Agent.Red.U4Support do
  @moduledoc """
  Support harness for the U4-R red suite
  (`test/raxol/agent/red/u4_reattach_red_test.exs`).

  Three responsibilities, mirroring `Raxol.Agent.Invariants.FaultJournal`:

    1. **Record builders + journal seeding** against the REAL
       `Raxol.Agent.Journal.FileStore` — no mock journal, ever. Builders cover
       the frozen JS-FREEZE record shapes (harness-freeze-contracts.md §1.1):
       conversational loop events, `family: "meta"` events, `checkpoint`
       records, the Dormammu tails (`idle` / `woken` / `state_change`), unknown
       future kinds, branch-tagged records, and grandfathered (kind-less)
       records.

    2. **The independent tip oracle** (meta-invariant m6, oracle independence).
       `raw_tip/2` computes the conversational tip from raw file bytes via
       `FaultJournal.raw_records!/1` and a DELIBERATE second copy of the frozen
       CONVERSATIONAL whitelist + predicate, structured as a backward scan —
       never calling `Raxol.Agent.Journal.Tip`. If the two implementations ever
       drift, the P-JS2 dual-oracle property fails: that divergence IS the test.

    3. **Dead injectors + fired-counters** (meta-invariants m1/m2). Each
       negative control from the freeze table gets a deliberately-broken
       variant here, and a per-site fire counter so an armed-but-never-fired
       injector fails the suite loudly:

         * `:emit_ahead`       — N-JS7: publish the live id BEFORE the journal
                                 append/ack (the I3 publish-ahead window)
         * `:tip_kind_only`    — N-JS5: tip predicate collapsed to
                                 `kind == "event"` (family/type clauses dropped)
         * `:branch_blind`     — N-JS8: tip scan ignoring `branch_id`
         * `:strict_reader`    — N-JS4: reader that damages-on-unknown-kind
         * `:marker_dependent` — a reattach that requires an attach marker
                                 record (forbidden by §1.1: no attach kind, and
                                 the meta attach event is best-effort only)
  """

  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore

  # ===========================================================================
  # Fired counters (m1) — same discipline as FaultJournal, U4-R's own sites.
  # ===========================================================================

  @sites [:emit_ahead, :tip_kind_only, :branch_blind, :strict_reader, :marker_dependent]

  @doc "All named U4-R dead-injector sites."
  def sites, do: @sites

  @doc "Start a fresh fired-counter harness."
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  @doc "Arm a site: it MUST fire before `assert_all_fired!/2` or the test fails."
  def arm(harness, site) when site in @sites do
    Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    harness
  end

  @doc "Record that a site fired."
  def record_fired(harness, site) when site in @sites do
    Agent.update(harness, fn s -> %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))} end)
    :ok
  end

  @doc "Per-site fire counts."
  def fired(harness), do: Agent.get(harness, & &1.fired)

  @doc """
  Meta-invariant m1: fail if any armed site never fired (a dead injector =
  green lies). `schedule` is dumped in the failure message (m2 — alongside the
  ExUnit seed it makes the run reproducible).
  """
  def assert_all_fired!(harness, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(harness, & &1)
    dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed U4-R fault site(s) never fired: #{inspect(dead)}\n" <>
            "fired counts: #{inspect(fired)}\n" <>
            "schedule: #{inspect(schedule)}"
    end

    fired
  end

  # ===========================================================================
  # Record builders — the frozen §1.1 shapes, string keys throughout (what the
  # Writer persists and the Reader hands back).
  # ===========================================================================

  # The frozen CONVERSATIONAL whitelist (§1.1). This is the SUPPORT-SIDE copy —
  # see the oracle section below for why it is duplicated on purpose.
  @conversational ~w(
    turn_started item_started item_completed
    turn_completed turn_canceled error approval_requested
  )

  @doc "The support-side copy of the CONVERSATIONAL whitelist."
  def conversational_types, do: @conversational

  @doc """
  A conversational loop event record (a legal tip candidate).

  Options: `:branch` (adds `"branch_id"`; omitted = grandfathered to "main"),
  `:grandfathered` (omits `"kind"` — the pre-freeze shape), `:turn_id`,
  `:marker` (payload marker to identify THIS event independently of its offset).
  """
  def conv_event(type, opts \\ []) when type in @conversational do
    base = %{
      "family" => "loop",
      "type" => type,
      "tier" => "durable",
      "v" => 0,
      "turn_id" => Keyword.get(opts, :turn_id, "turn-1"),
      "payload" => %{"marker" => Keyword.get(opts, :marker, "conv")}
    }

    base
    |> maybe_kind(Keyword.get(opts, :grandfathered, false))
    |> maybe_branch(Keyword.get(opts, :branch))
  end

  defp maybe_kind(record, true), do: record
  defp maybe_kind(record, false), do: Map.put(record, "kind", "event")

  defp maybe_branch(record, nil), do: record
  defp maybe_branch(record, branch), do: Map.put(record, "branch_id", branch)

  @doc "A `family: \"meta\"` event (tip-excluded by decision, §1.1)."
  def meta_event(type \\ "attach") do
    %{
      "kind" => "event",
      "family" => "meta",
      "type" => type,
      "tier" => "durable",
      "v" => 0,
      "payload" => %{"from_offset" => 0, "history_policy" => "none", "refs" => []}
    }
  end

  @doc "A `checkpoint` pointer record (§1.1-checkpoint; tip-excluded non-event kind)."
  def checkpoint_record(tip_offset) do
    %{
      "kind" => "checkpoint",
      "session_id" => "red-u4",
      "ts" => System.system_time(:microsecond),
      "tip_offset" => tip_offset,
      "snapshot_ref" => nil,
      "snapshot_hash" => nil,
      "reason" => "manual"
    }
  end

  @doc """
  A `family: "loop"` event whose type is excluded from CONVERSATIONAL — the
  Dormammu shapes: `"idle"`, `"woken"` (excluded BY DECISION though it is
  family loop), `"state_change"`.
  """
  def excluded_loop_event(type) when type in ~w(idle woken state_change) do
    %{
      "kind" => "event",
      "family" => "loop",
      "type" => type,
      "tier" => "durable",
      "v" => 0,
      "payload" => %{}
    }
  end

  @doc "A record of an unknown future kind (reader tolerance, P-JS6)."
  def unknown_kind_record(kind \\ "future_kind_v9") do
    %{
      "kind" => kind,
      "session_id" => "red-u4",
      "ts" => System.system_time(:microsecond),
      "payload" => %{"opaque" => true}
    }
  end

  @doc "One record of every non-conversational shape — the Dormammu tail pool."
  def dormammu_tail_pool(tip_offset) do
    [
      checkpoint_record(tip_offset),
      meta_event("attach"),
      excluded_loop_event("idle"),
      excluded_loop_event("woken"),
      excluded_loop_event("state_change"),
      unknown_kind_record()
    ]
  end

  # ===========================================================================
  # Journal seeding — the REAL FileStore, unique dir per journal.
  # ===========================================================================

  @doc "Open a fresh session journal under `base`; returns `{handle, session, dir}`."
  def open!(base, opts \\ []) do
    session = "red-u4-#{System.unique_integer([:positive])}"
    {:ok, j} = FileStore.open(session, Keyword.put(opts, :base_dir, base))
    {j, session, Path.join(base, session)}
  end

  @doc "Append `records` in order through the real Writer; returns assigned offsets."
  def append_all!(j, records) do
    Enum.map(records, fn record ->
      {:ok, offset} = FileStore.append(j, record)
      offset
    end)
  end

  # ===========================================================================
  # The independent tip oracle (m6).
  # ===========================================================================

  # DELIBERATE DUPLICATE of Raxol.Agent.Journal.Tip's whitelist and predicate:
  # the P-JS2 dual-oracle property needs two INDEPENDENT implementations that
  # must agree. Structured differently on purpose (backward scan / Enum.find
  # over reversed file order vs. the Tip module's filter + max_by). Do NOT
  # "refactor" this to call Tip — agreement between the two is the property.

  @doc """
  The conversational tip computed from raw journal bytes — `{:tip, offset}` or
  `:no_tip`. `records` in file order (dense ascending ids), e.g. from
  `FaultJournal.raw_records!/1`.
  """
  def raw_tip(records, branch \\ "main") when is_list(records) do
    records
    |> Enum.reverse()
    |> Enum.find(fn r ->
      to_string(Map.get(r, "branch_id", "main")) == branch and raw_conversational?(r)
    end)
    |> case do
      nil -> :no_tip
      record -> {:tip, Map.fetch!(record, "id")}
    end
  end

  @doc "The oracle's own conversational? — independent of Raxol.Agent.Journal.Tip."
  def raw_conversational?(record) do
    to_string(Map.get(record, "kind", "event")) == "event" and
      to_string(Map.get(record, "family", "")) == "loop" and
      to_string(Map.get(record, "type", "")) in @conversational
  end

  # ===========================================================================
  # Closure / publish-ahead detectors (P-JS5 / I3).
  # ===========================================================================

  @doc """
  P-JS5 replay-closure check: `history ++ live`, as an id SEQUENCE (not a
  multiset — ordering bugs hide behind multiset equality), must equal the full
  durable stream's ids, and no live id may precede `from_offset` (an earlier
  durable delivered as live). Returns `:ok` or `{:violation, reason}`.
  """
  def closure_check(history, live, full, from_offset) do
    seq = Enum.map(history ++ live, &Map.fetch!(&1, "id"))
    full_ids = Enum.map(full, &Map.fetch!(&1, "id"))
    early_live = live |> Enum.map(&Map.fetch!(&1, "id")) |> Enum.filter(&(&1 < from_offset))

    cond do
      early_live != [] ->
        {:violation, {:earlier_durable_delivered_as_live, early_live}}

      seq != full_ids ->
        {:violation, {:sequence_mismatch, seq, full_ids}}

      true ->
        :ok
    end
  end

  @doc """
  The I3 / N-JS7 detector: at the moment a live subscriber first sees id
  `live_id`, an independent raw-file read must already return a complete record
  with that id. `true` = VIOLATION (the id is not yet durable — the
  emit-ahead-of-journal window is open).
  """
  def publish_ahead_violation?(dir, live_id) do
    ids =
      dir
      |> FaultJournal.raw_scan()
      |> Enum.flat_map(fn
        {:ok, %{"id" => id}, _line} -> [id]
        _ -> []
      end)

    live_id not in ids
  end

  @doc """
  Dead injector `:emit_ahead` (N-JS7): the buggy EmitBridge-like ordering —
  predict the next offset from a local counter, PUBLISH the live event first,
  and only then append (the inverse of the real EmitBridge's
  append-before-publish; invariant I3's publish-ahead window held open).

  Sends `{:reattach_live, session, record}` to `subscriber`, then calls
  `probe.(predicted_id)` INSIDE the window (this models the late subscriber
  raw-reading the journal at delivery time), then appends. Returns
  `{predicted_id, probe_result}`.
  """
  def emit_ahead_publish!(harness, j, dir, session, subscriber, record, probe) do
    predicted = length(FaultJournal.raw_ids!(dir)) + 1
    send(subscriber, {:reattach_live, session, Map.put(record, "id", predicted)})
    record_fired(harness, :emit_ahead)
    probe_result = probe.(predicted)
    {:ok, ^predicted} = FileStore.append(j, record)
    {predicted, probe_result}
  end

  # ===========================================================================
  # Dead injectors: broken tip scans / readers / reattach variants.
  # ===========================================================================

  @doc """
  Dead injector `:tip_kind_only` (N-JS5): the tip predicate collapsed to
  `kind == "event"` — the family/type clauses (the whole closure rule) dropped.
  Must fail the Dormammu red: a trailing meta event or idle/woken marker gets
  selected as tip.
  """
  def kind_only_tip(harness, records, branch \\ "main") do
    record_fired(harness, :tip_kind_only)

    records
    |> Enum.reverse()
    |> Enum.find(fn r ->
      to_string(Map.get(r, "branch_id", "main")) == branch and
        to_string(Map.get(r, "kind", "event")) == "event"
    end)
    |> case do
      nil -> :no_tip
      record -> {:tip, Map.fetch!(record, "id")}
    end
  end

  @doc """
  Dead injector `:branch_blind` (N-JS8): a tip scan that never filters on
  `branch_id`. Must fail the branch red: it selects another branch's record as
  the "main" tip.
  """
  def branch_blind_tip(harness, records) do
    record_fired(harness, :branch_blind)

    records
    |> Enum.reverse()
    |> Enum.find(&raw_conversational?/1)
    |> case do
      nil -> :no_tip
      record -> {:tip, Map.fetch!(record, "id")}
    end
  end

  @doc """
  Dead injector `:strict_reader` (N-JS4): a reader that marks the journal
  DAMAGED when it meets a record whose kind is not in its compiled registry —
  producer-seam strictness applied at the reader seam. Must fail the tolerance
  red (`{:ok, _}` required).
  """
  def strict_reader_scan(harness, dir) do
    record_fired(harness, :strict_reader)
    records = FaultJournal.raw_records!(dir)

    case Enum.find(records, fn r -> Map.get(r, "kind", "event") not in ["event"] end) do
      nil -> {:ok, records}
      offender -> {:damaged, {:unknown_kind, Map.get(offender, "kind"), Map.get(offender, "id")}}
    end
  end

  @doc """
  Dead injector `:marker_dependent`: a reattach that REQUIRES a journaled
  attach marker (`family: "meta"`, `type: "attach"`) before serving history.
  §1.1 forbids exactly this dependence — the attach audit event is best-effort,
  written only when a live Writer exists; a writerless (dead-BEAM / tar'd)
  session has none. Must fail the writerless red.
  """
  def marker_dependent_attach(harness, dir, from_offset) do
    record_fired(harness, :marker_dependent)
    records = FaultJournal.raw_records!(dir)

    marker? =
      Enum.any?(records, fn r ->
        Map.get(r, "family") == "meta" and Map.get(r, "type") == "attach"
      end)

    if marker? do
      {:ok, %{history: Enum.filter(records, &(Map.fetch!(&1, "id") < from_offset))}}
    else
      {:error, :no_attach_marker}
    end
  end
end
