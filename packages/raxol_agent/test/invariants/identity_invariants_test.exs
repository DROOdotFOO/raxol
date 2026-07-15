defmodule Raxol.Agent.Invariants.IdentityInvariantsTest do
  @moduledoc """
  Tier-1 identity invariants I1–I3
  (docs/proposals/in-flight/harness-invariants.md).

    * I1 — id authority under failure/crash: under generated fault schedules
      ({append_fail, open_fail, kill_after_write_before_head,
      kill_after_head_before_publish, writer_down}) the journal stays dense
      1..n, live durable ids are never fabricated (⊆ journal, exact expected
      sequence), HEAD ≤ n, and a reopen replays exactly the journal.
    * I2 — ephemeral/durable wall: the journal is durable-only; every ephemeral
      id ∈ {0} ∪ {last durable offset at emission}; durable ids ≥ 1; tier never
      lies; journal record vs live event compared BYTE-identically post-stamp
      (writer-injected id/schema_version included), not loose map equality.
    * I3 — journal-before-publish observability: at the moment the live tail
      first sees durable id N, an independent raw-file read already returns a
      complete record with that id.

  Oracles (m6): journal truth = `FaultJournal.raw_*` (raw `File.read!` + the
  harness's own decoder — never the Writer's in-memory state); live truth =
  this test process as a SessionStreamer subscriber — never a publisher return
  value. Fault sites carry fire counters; every armed site must fire (m1);
  schedules are StreamData-generated, so failures print the shrunk schedule and
  are seed-reproducible (m2).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  @required_faults [
    :append_fail,
    :writer_down,
    :kill_after_write_before_head,
    :kill_after_head_before_publish
  ]

  setup do
    FaultJournal.ensure_registry(:duplicate, EmitBus.registry_name())

    FaultJournal.ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_identity_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # ===========================================================================
  # I1 — id authority under failure/crash
  # ===========================================================================

  describe "I1 — id authority under generated fault schedules" do
    property "journal dense 1..n, live ids never fabricated, HEAD ≤ n, replay == journal" do
      base = context_base()

      check all(schedule <- schedule_gen(), max_runs: 20) do
        ctx = start_run(base, schedule)
        ctx = Enum.reduce(schedule, ctx, &run_step(&2, &1))
        # Always finish with a healthy durable so the run ends in a live state.
        ctx = run_step(ctx, {:durable, :final})

        verify_run!(ctx, schedule)
        stop_run(ctx)
      end
    end

    test "scenario: the full fault gauntlet in one session", %{base: base} do
      schedule =
        [
          {:fault, :open_fail},
          {:durable, 1},
          {:durable, 2},
          {:ephemeral, 1},
          {:fault, :append_fail},
          {:durable, 3},
          {:fault, :kill_after_write_before_head},
          {:ephemeral, 2},
          {:fault, :kill_after_head_before_publish},
          {:durable, 4},
          {:fault, :writer_down},
          {:durable, 5}
        ]

      ctx = start_run(base, schedule)
      ctx = Enum.reduce(schedule, ctx, &run_step(&2, &1))
      verify_run!(ctx, schedule)
      stop_run(ctx)
    end
  end

  # ===========================================================================
  # I2 — the ephemeral/durable wall
  # ===========================================================================

  describe "I2 — ephemeral/durable wall" do
    property "journal is durable-only; ephemeral ids ride the last durable offset; byte-identity post-stamp" do
      base = context_base()

      step = frequency([{3, constant(:durable)}, {2, constant(:ephemeral)}])

      check all(raw_steps <- list_of(step, min_length: 5, max_length: 25), max_runs: 25) do
        # m5 required pattern: MIXED tiers — force at least one of each.
        steps = [:durable, :ephemeral | raw_steps]
        schedule = Enum.with_index(steps, fn s, i -> {s, i} end)

        ctx = start_run(base, schedule)
        ctx = Enum.reduce(schedule, ctx, &run_step(&2, &1))

        # The wall, journal side (independent oracle): durable-only, no line
        # ever carries the ephemeral tier or the ephemeral-only type.
        records = FaultJournal.raw_records!(ctx.dir)
        assert Enum.all?(records, &(&1["tier"] == "durable"))
        refute Enum.any?(records, &(&1["type"] == "item_delta"))
        journal_ids = Enum.map(records, & &1["id"])
        assert journal_ids == Enum.to_list(1..length(journal_ids))

        # The wall, live side: fold the SUBSCRIBER's stream in arrival order.
        # Every durable id ≥ 1; every ephemeral id == the last durable offset
        # seen at its emission (0 before any durable).
        Enum.reduce(ctx.live, 0, fn
          %Event{tier: :durable} = e, _watermark ->
            assert e.id >= 1, "durable id 0 leaked into the live tail"
            assert e.id in journal_ids, "live durable id #{e.id} is not in the journal"
            e.id

          %Event{tier: :ephemeral} = e, watermark ->
            assert e.id == watermark,
                   "ephemeral id #{e.id} != last durable offset #{watermark}"

            assert e.type == :item_delta
            watermark
        end)

        # Byte-identity post-stamp for every live durable event: reconstruct
        # the journal record from the LIVE event (+ writer-injected id and
        # schema_version) and compare against the raw line bytes.
        for %Event{tier: :durable} = e <- ctx.live do
          assert_byte_identical!(ctx.dir, e)
        end

        stop_run(ctx)
      end
    end

    test "the tier field never lies: a durable event is journaled, an ephemeral one is not", %{
      base: base
    } do
      ctx = start_run(base, [])
      ctx = run_step(ctx, {:durable, 1})
      ctx = run_step(ctx, {:ephemeral, 1})
      ctx = run_step(ctx, {:durable, 2})

      [d1, e1, d2] = ctx.live

      assert {%Event{tier: :durable, id: 1}, %Event{tier: :ephemeral, id: 1},
              %Event{tier: :durable, id: 2}} = {d1, e1, d2}

      assert FaultJournal.raw_ids!(ctx.dir) == [1, 2]
      stop_run(ctx)
    end
  end

  # ===========================================================================
  # I3 — journal-before-publish observability
  # ===========================================================================

  describe "I3 — journal-before-publish" do
    # NOTE: run_step/await_durable! asserts I3 on EVERY durable receipt in
    # every I1/I2 run above (an independent raw read at first live sight). This
    # test names the invariant explicitly on a clean stream.
    test "at first live sight of durable id N, a raw file read already returns the complete record",
         %{base: base} do
      ctx = start_run(base, [])

      ctx =
        Enum.reduce(1..8, ctx, fn k, acc ->
          # await_durable! performs the raw-read-at-first-sight check.
          run_step(acc, {:durable, k})
        end)

      assert length(ctx.live) == 8
      stop_run(ctx)
    end
  end

  # ===========================================================================
  # driver
  # ===========================================================================

  # Per-run context: a fresh session dir, an anonymous streamer, a bridge, and
  # book-keeping for the expected journal/live id sequences.
  defp start_run(base, schedule) do
    harness = FaultJournal.new()

    for {:fault, site} <- schedule, do: FaultJournal.arm(harness, site)

    session_id = "inv-id-#{System.unique_integer([:positive])}"
    run_base = Path.join(base, session_id)
    File.mkdir_p!(run_base)

    {:ok, streamer} = SessionStreamer.start_link(name: nil)

    {:ok, bridge} =
      EmitBridge.start_link(
        session_id: session_id,
        streamer: streamer,
        journal_opts: [base_dir: run_base]
      )

    :ok = SessionStreamer.subscribe(session_id, streamer)

    %{
      harness: harness,
      schedule: schedule,
      base: run_base,
      dir: Path.join(run_base, session_id),
      session_id: session_id,
      streamer: streamer,
      bridge: bridge,
      # highest id present in the journal (expected)
      next_id: 0,
      # ids that exist in the journal but were never published live
      journal_only: [],
      # expected live durable id sequence
      expected_live_ids: [],
      # live stream as received by the subscriber (this process)
      live: []
    }
  end

  defp stop_run(ctx) do
    if Process.alive?(ctx.bridge), do: GenServer.stop(ctx.bridge)
    if Process.alive?(ctx.streamer), do: GenServer.stop(ctx.streamer)
    drain_mailbox(ctx.session_id)
    :ok
  end

  # --- steps -----------------------------------------------------------------

  defp run_step(ctx, {:durable, tag}) do
    publish(ctx, :app_update, :durable, %{tag: inspect(tag)})
    expected = ctx.next_id + 1
    ev = await_durable!(ctx)

    assert ev.id == expected,
           "durable got id #{ev.id}, expected #{expected} (schedule: #{inspect(ctx.schedule)})"

    %{
      ctx
      | next_id: expected,
        expected_live_ids: ctx.expected_live_ids ++ [expected],
        live: ctx.live ++ [ev]
    }
  end

  defp run_step(ctx, {:ephemeral, tag}) do
    publish(ctx, :command_result, :ephemeral, %{tag: inspect(tag)})
    ev = await_type!(ctx, :item_delta)
    assert ev.tier == :ephemeral
    %{ctx | live: ctx.live ++ [ev]}
  end

  # :append_fail — dead fd swapped into the live Writer; the durable published
  # under it must be dropped loudly. m3 branch probe: the SPECIFIC observables
  # are (a) an ephemeral :error event with reason :journal_append_failed pinned
  # to the unchanged watermark, (b) the journal bytes untouched, (c) the next
  # successful durable takes the very next offset — no gap, no fabrication.
  defp run_step(ctx, {:fault, :append_fail}) do
    ids_before = FaultJournal.raw_ids!(ctx.dir)
    writer = bridge_writer!(ctx)
    original_io = FaultJournal.inject_append_fail(ctx.harness, writer, ctx.base)

    publish(ctx, :app_update, :durable, %{tag: "victim-append-fail"})
    err = await_error!(ctx, :journal_append_failed)
    assert err.id == last_live_durable_id(ctx), "failure signal must ride the old watermark"

    assert FaultJournal.raw_ids!(ctx.dir) == ids_before,
           "a failed append must not reach the journal"

    :ok = FaultJournal.heal_append_fail(writer, original_io)
    run_step(%{ctx | live: ctx.live ++ [err]}, {:durable, :after_append_fail})
  end

  # :writer_down — the Writer dies under the bridge's handle. The pending
  # durable is dropped loudly; the NEXT durable lazily reopens the journal and
  # resumes from the on-disk offset.
  defp run_step(ctx, {:fault, :writer_down}) do
    writer = bridge_writer!(ctx)
    :ok = FaultJournal.stop_writer(ctx.harness, writer)

    publish(ctx, :app_update, :durable, %{tag: "victim-writer-down"})
    err = await_error!(ctx, :journal_append_failed)
    assert err.payload.detail =~ "writer_down"

    run_step(%{ctx | live: ctx.live ++ [err]}, {:durable, :after_writer_down})
  end

  # :kill_after_write_before_head — flushed journal bytes the crash beat HEAD
  # (and the publish) to. The journal is ahead of both HEAD and the live tail;
  # a reopen must resume PAST the raw record (no id reuse), and the live tail
  # must never see its id.
  defp run_step(ctx, {:fault, :kill_after_write_before_head}) do
    writer = bridge_writer!(ctx)
    raw_id = ctx.next_id + 1

    :ok =
      FaultJournal.inject_write_before_head(ctx.harness, ctx.dir, [
        %{
          "v" => 0,
          "id" => raw_id,
          "session_id" => ctx.session_id,
          "turn_id" => "t1",
          "ts" => System.system_time(:microsecond),
          "family" => "loop",
          "type" => "item_completed",
          "tier" => "durable",
          "payload" => %{"tag" => "crashed-before-head"},
          "schema_version" => "1.0.0"
        }
      ])

    # The kill half: the Writer must never append again over its stale
    # in-memory offset. (Recorded under the same composite site.)
    if Process.alive?(writer), do: GenServer.stop(writer)

    ctx = %{ctx | next_id: raw_id, journal_only: ctx.journal_only ++ [raw_id]}

    # The bridge still holds the dead handle: the next durable is dropped
    # loudly, the one after reopens and resumes at raw_id + 1.
    publish(ctx, :app_update, :durable, %{tag: "victim-after-raw"})
    err = await_error!(ctx, :journal_append_failed)

    run_step(%{ctx | live: ctx.live ++ [err]}, {:durable, :after_write_before_head})
  end

  # :kill_after_head_before_publish — a record lands in journal + HEAD through
  # the session's single Writer but is never published. Journal ⊃ live is the
  # legal direction (append-before-publish); the bridge's next durable takes
  # the NEXT offset.
  defp run_step(ctx, {:fault, :kill_after_head_before_publish}) do
    _writer = bridge_writer!(ctx)

    offset =
      FaultJournal.inject_head_before_publish(ctx.harness, ctx.session_id, ctx.base, %{
        v: 0,
        session_id: ctx.session_id,
        turn_id: "t1",
        ts: System.system_time(:microsecond),
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{tag: "appended-never-published"}
      })

    assert offset == ctx.next_id + 1
    %{ctx | next_id: offset, journal_only: ctx.journal_only ++ [offset]}
  end

  # :open_fail — only valid before the journal exists. The durable published
  # while the session dir is blocked is dropped with the open-specific reason.
  defp run_step(ctx, {:fault, :open_fail}) do
    assert ctx.next_id == 0, "open_fail is a schedule-prefix-only fault"
    :ok = FaultJournal.inject_open_fail(ctx.harness, ctx.session_id, ctx.base)

    publish(ctx, :app_update, :durable, %{tag: "victim-open-fail"})
    err = await_error!(ctx, :journal_open_failed)
    assert err.id == 0, "pre-durable failure signal must carry the 0 sentinel"

    :ok = FaultJournal.heal_open_fail(ctx.session_id, ctx.base)
    %{ctx | live: ctx.live ++ [err]}
  end

  # --- end-of-run verification (the I1 assertions) ----------------------------

  defp verify_run!(ctx, schedule) do
    n = ctx.next_id

    # Journal (independent oracle): dense 1..n, no torn/corrupt entries.
    journal_ids = FaultJournal.raw_ids!(ctx.dir)

    assert journal_ids == Enum.to_list(1..n),
           "journal not dense 1..#{n}: #{inspect(journal_ids)} (schedule: #{inspect(schedule)})"

    # Live durable ids: the exact expected sequence — never a fabricated id,
    # never a dropped-event id, never a journal-only id.
    live_durable_ids = for %Event{tier: :durable} = e <- ctx.live, do: e.id
    assert live_durable_ids == ctx.expected_live_ids
    assert live_durable_ids == Enum.uniq(live_durable_ids)
    assert Enum.all?(live_durable_ids, &(&1 in journal_ids))
    assert journal_ids -- live_durable_ids == ctx.journal_only

    # Every live durable event is byte-identical to its journal record.
    for %Event{tier: :durable} = e <- ctx.live, do: assert_byte_identical!(ctx.dir, e)

    # HEAD never points past the journal.
    case FaultJournal.raw_head(ctx.dir) do
      {:ok, %{"offset" => offset}} -> assert offset <= n
      :missing -> :ok
      {:error, reason} -> flunk("HEAD unreadable: #{inspect(reason)}")
    end

    # Reopen through the production reader: replay == the raw oracle exactly.
    {:ok, j} = FileStore.open(ctx.session_id, base_dir: ctx.base)
    assert {:ok, records} = FileStore.read(j)
    assert records == FaultJournal.raw_records!(ctx.dir)
    :ok = FileStore.close(j)

    # m1: every armed fault site fired at least once — else the run was hollow.
    FaultJournal.assert_all_fired!(ctx.harness, schedule)
  end

  # --- oracle helpers ----------------------------------------------------------

  defp publish(ctx, type, tier, payload) do
    EmitBus.publish(EmitBus.build(ctx.session_id, type, tier, payload, turn_id: "t1"))
  end

  # Receive the next live durable event and assert I3 at the moment of first
  # sight: an INDEPENDENT raw read must already return the complete record.
  defp await_durable!(ctx) do
    ev = await_type!(ctx, :item_completed)
    assert ev.tier == :durable

    on_disk =
      FaultJournal.raw_scan(ctx.dir)
      |> Enum.any?(fn
        {:ok, %{"id" => id, "type" => "item_completed"}, _line} -> id == ev.id
        _ -> false
      end)

    assert on_disk,
           "I3 violated: live saw durable id #{ev.id} before a complete journal record existed"

    ev
  end

  defp await_type!(ctx, type) do
    session_id = ctx.session_id

    receive do
      {:session_event, ^session_id, %Event{type: ^type} = ev} ->
        ev

      {:session_event, ^session_id, %Event{} = other} ->
        flunk(
          "expected a #{inspect(type)} event, got #{inspect(other.type)} " <>
            "(schedule: #{inspect(ctx.schedule)})"
        )
    after
      2_000 ->
        flunk("timed out waiting for #{inspect(type)} (schedule: #{inspect(ctx.schedule)})")
    end
  end

  defp await_error!(ctx, reason) do
    session_id = ctx.session_id

    receive do
      {:session_event, ^session_id, %Event{type: :error} = ev} ->
        assert ev.tier == :ephemeral, "journal-failure signal must never look durable"
        assert ev.payload.reason == reason
        assert ev.payload.original_type == :item_completed
        ev

      {:session_event, ^session_id, %Event{} = other} ->
        flunk(
          "expected the #{inspect(reason)} error signal, got #{inspect(other.type)} " <>
            "(schedule: #{inspect(ctx.schedule)})"
        )
    after
      2_000 ->
        flunk("timed out waiting for #{inspect(reason)} (schedule: #{inspect(ctx.schedule)})")
    end
  end

  defp last_live_durable_id(ctx) do
    ctx.live
    |> Enum.reverse()
    |> Enum.find_value(0, fn
      %Event{tier: :durable, id: id} -> id
      _ -> nil
    end)
  end

  # Post-stamp byte identity (I2): rebuild the journal record from the LIVE
  # event plus the two writer-injected fields and require the encoded bytes to
  # equal the raw line exactly — key order, value encoding, everything.
  defp assert_byte_identical!(dir, %Event{} = e) do
    {_record, line} =
      FaultJournal.raw_lines!(dir)
      |> Enum.find(fn {r, _} -> r["id"] == e.id end) ||
        flunk("no journal line for live durable id #{e.id}")

    reconstructed = %{
      "v" => e.v,
      "id" => e.id,
      "session_id" => e.session_id,
      "turn_id" => e.turn_id,
      "ts" => e.ts,
      "family" => e.family,
      "type" => e.type,
      "tier" => e.tier,
      "payload" => e.payload,
      "schema_version" => "1.0.0"
    }

    assert Jason.encode!(reconstructed) == line,
           "live durable id #{e.id} is not byte-identical to its journal record"
  end

  defp bridge_writer!(ctx) do
    case :sys.get_state(ctx.bridge) do
      %{journal: %FileStore{writer: writer}} ->
        writer

      %{journal: nil} ->
        flunk("fault site needs an open journal; schedule must front-load durables")
    end
  end

  defp drain_mailbox(session_id) do
    receive do
      {:session_event, ^session_id, _} -> drain_mailbox(session_id)
    after
      0 -> :ok
    end
  end

  defp context_base do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_identity_prop_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  # --- schedule generator (m5: required trace patterns) ------------------------
  #
  # Every schedule front-loads two durables (fault sites need a live journal),
  # guarantees at least one ephemeral (mixed tiers), and interleaves EVERY
  # required fault site at a generated position (a 10k-run sample can therefore
  # never lack the required patterns — they are present by construction, and m1
  # verifies each actually fired).
  defp schedule_gen do
    step =
      frequency([
        {3, map(integer(1..1000), &{:durable, &1})},
        {2, map(integer(1..1000), &{:ephemeral, &1})}
      ])

    gen all(
          with_open_fail <- boolean(),
          body <- list_of(step, min_length: 4, max_length: 14),
          positions <- list_of(integer(0..100), length: length(@required_faults))
        ) do
      faults = Enum.map(@required_faults, &{:fault, &1})

      body_with_faults =
        positions
        |> Enum.zip(faults)
        |> Enum.reduce(body, fn {pos, fault}, acc ->
          List.insert_at(acc, rem(pos, length(acc) + 1), fault)
        end)

      prefix = if with_open_fail, do: [{:fault, :open_fail}], else: []
      prefix ++ [{:durable, :seed1}, {:durable, :seed2}, {:ephemeral, :seed}] ++ body_with_faults
    end
  end
end
