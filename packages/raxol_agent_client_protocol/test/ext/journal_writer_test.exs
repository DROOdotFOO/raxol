defmodule Raxol.AgentClientProtocol.Ext.Journal.WriterTest do
  @moduledoc """
  The single-publisher Writer (§2.1): append-then-publish (I3 / J3), taint
  annotate-never-filter (§6 / J5), the atomic latch clear (C13), and orphan
  repair total across BOTH appender death (§2.6 monitor `:DOWN`) and Writer death
  (startup tip-fold, C14 / R-C14-lazy, witnesses (a) and (b)).

  Every positive contour ships its named dead-injector negative control (bus §9):
  the publish-phantom Writer breaks closure (N-JS7), and the fold-after-op Writer
  buries/doubles the strand (R-C14-lazy).
  """
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Ext.Journal
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer

  setup do
    start_supervised!({Registry, keys: :unique, name: Writer.registry()})
    :ok
  end

  defp hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Start a Writer over a fresh (or supplied) test-owned Mem journal. `name: nil`
  # keeps it out of the Registry so kill/restart tests don't collide; the handle
  # is owned by the test process, so it OUTLIVES the Writer (the C14 precondition).
  defp start_writer(opts \\ []) do
    sid = Keyword.get(opts, :session_id, "sess-" <> hex())

    j =
      case Keyword.fetch(opts, :journal) do
        {:ok, handle} -> handle
        :error -> elem(Mem.open(sid), 1)
      end

    knobs =
      Keyword.take(opts, [
        :__dead_publish_phantom__,
        :__dead_bootstrap_after_op__,
        :session_meta,
        :subscriber_credit
      ])

    writer_opts = [session_id: sid, journal: {Mem, j}, name: nil] ++ knobs

    pid =
      start_supervised!(
        %{
          id: {:writer, make_ref()},
          start: {Writer, :start_link, [writer_opts]},
          restart: :temporary
        },
        restart: :temporary
      )

    {pid, sid, j}
  end

  defp hwm(j), do: Mem.high_watermark(j)
  defp read_all(j), do: elem(Mem.read(j, 1, max(hwm(j), 1)), 1)

  defp completed(j),
    do: Enum.filter(read_all(j), &(&1.kind == "turn_completed"))

  defp wait_until(fun, timeout \\ 2_000) do
    cond do
      fun.() -> :ok
      timeout <= 0 -> flunk("wait_until timed out")
      true -> Process.sleep(10) && wait_until(fun, timeout - 10)
    end
  end

  # Seed a journal whose tip is a dangling turn_started (no matching completed):
  # start a Writer, begin a turn, then kill the Writer WITHOUT completing it.
  defp dangling_journal(turn_id) do
    {w, sid, j} = start_writer()
    {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => turn_id}, "user")
    Process.exit(w, :kill)
    {sid, j}
  end

  # -- Genesis ----------------------------------------------------------------

  test "genesis: the first op appends session_created at offset 1" do
    {w, _sid, j} = start_writer()
    {:ok, rec} = Writer.append(w, "session_update", %{"x" => 1}, "agent")
    assert rec.offset == 2

    {:ok, [genesis]} = Mem.read(j, 1, 1)
    assert genesis.kind == "session_created"
    assert genesis.offset == 1
  end

  # -- J3: single publisher, append-then-publish ------------------------------

  test "single publisher: a subscriber receives every appended record live, in order, all durable" do
    {w, sid, j} = start_writer()
    :ok = Writer.subscribe(w, self())

    {:ok, _} = Writer.append(w, "session_update", %{"i" => 1}, "agent")
    {:ok, _} = Writer.append(w, "session_update", %{"i" => 2}, "external")

    assert_receive {:reattach_live, ^sid, %Record{offset: 2, taint: "agent"}}
    assert_receive {:reattach_live, ^sid, %Record{offset: 3, taint: "external"}}

    # Every delivered offset is durable in the store (append precedes publish).
    durable = MapSet.new(read_all(j), & &1.offset)
    assert MapSet.member?(durable, 2)
    assert MapSet.member?(durable, 3)

    # Genesis was appended by the bootstrap BEFORE this subscriber registered, so
    # it is NOT delivered live (history-only) — the subscribe-before-h seam.
    refute_received {:reattach_live, ^sid, %Record{kind: "session_created"}}
  end

  test "no public publish surface exists — publishing is the Writer's alone (J3)" do
    exports = Writer.__info__(:functions) ++ Journal.__info__(:functions)

    refute Enum.any?(exports, fn {name, _arity} ->
             name in [:publish, :notify, :broadcast]
           end)
  end

  # -- J5: taint annotate, never filter ---------------------------------------

  test "taint is stamped into the record and NEVER filters delivery" do
    {w, sid, _j} = start_writer()
    :ok = Writer.subscribe(w, self())

    for t <- ~w(user agent external system) do
      {:ok, %Record{taint: ^t}} =
        Writer.append(w, "session_update", %{"t" => t}, t)
    end

    for t <- ~w(user agent external system) do
      assert_receive {:reattach_live, ^sid, %Record{taint: ^t}}
    end
  end

  # -- N-JS7 dead control: publish-ahead / phantom breaks closure -------------

  test "DEAD publish-phantom delivers a live offset with no durable backing (N-JS7 control)" do
    {w, sid, j} = start_writer(__dead_publish_phantom__: true)
    :ok = Writer.subscribe(w, self())

    {:ok, rec} = Writer.append(w, "session_update", %{"i" => 1}, "agent")

    # Genesis took offset 1, so this real record is offset 2 and the phantom is 3.
    assert rec.offset == 2

    assert_receive {:reattach_live, ^sid, %Record{offset: 2}}

    assert_receive {:reattach_live, ^sid, %Record{offset: 3, payload: %{"phantom" => true}}}

    durable = MapSet.new(read_all(j), & &1.offset)

    # Closure broken: the phantom offset (3) was delivered live but never appended.
    assert MapSet.member?(durable, 2)
    refute MapSet.member?(durable, 3)

    # Contrast: the correct Writer only ever delivers durable offsets.
    {w2, sid2, j2} = start_writer()
    :ok = Writer.subscribe(w2, self())
    {:ok, _} = Writer.append(w2, "session_update", %{"i" => 1}, "agent")
    durable2 = MapSet.new(read_all(j2), & &1.offset)
    assert_receive {:reattach_live, ^sid2, %Record{offset: o}}
    assert MapSet.member?(durable2, o)
  end

  # -- C13: atomic latch clear on success -------------------------------------

  test "latch clear (C13): turn_completed clears the latch atomically in the same step" do
    {w, _sid, _j} = start_writer()

    {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 1}, "user")
    assert %{turn: %{turn_id: 1}} = :sys.get_state(w)

    {:ok, _} =
      Writer.append(
        w,
        "turn_completed",
        %{"turnId" => 1, "stopReason" => "end_turn"},
        "agent"
      )

    # Latch is nil the instant turn_completed returns — no separate end message.
    assert %{turn: nil} = :sys.get_state(w)

    # The next prompt is never wedged at :turn_in_flight.
    assert {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 2}, "user")
  end

  test "success-then-crash produces ZERO orphan rows (C13): appender dies after turn_completed" do
    {w, _sid, j} = start_writer()
    test = self()

    appender =
      spawn(fn ->
        {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 1}, "user")

        {:ok, _} =
          Writer.append(
            w,
            "turn_completed",
            %{"turnId" => 1, "stopReason" => "end_turn"},
            "agent"
          )

        send(test, :completed)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :completed
    ref = Process.monitor(appender)
    Process.exit(appender, :kill)
    assert_receive {:DOWN, ^ref, :process, ^appender, _}

    # Two barriers flush the Writer's own :DOWN (same termination event) — if the
    # latch had NOT cleared, this is where a second (orphan) turn_completed lands.
    _ = :sys.get_state(w)
    _ = :sys.get_state(w)

    assert length(completed(j)) == 1
    refute Enum.any?(completed(j), &(&1.payload["outcome"] == "orphaned"))
  end

  # -- §2.6: orphan repair on appender death ----------------------------------

  test "orphan repair (appender death): exactly one orphaned turn_completed, latch clears, next turn OK" do
    {w, _sid, j} = start_writer()
    test = self()

    appender =
      spawn(fn ->
        {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 7}, "user")
        send(test, :started)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :started
    # A concurrent second turn is rejected while the first is latched (§2.7).
    assert {:error, :turn_in_flight} =
             Writer.append(w, "turn_started", %{"turnId" => 8}, "user")

    Process.exit(appender, :kill)
    wait_until(fn -> length(completed(j)) == 1 end)

    [orphan] = completed(j)
    assert orphan.kind == "turn_completed"
    assert orphan.payload["turnId"] == 7
    assert orphan.payload["outcome"] == "orphaned"
    assert orphan.payload["stopReason"] == "cancelled"

    # Latch cleared: a fresh turn now succeeds.
    assert {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 9}, "user")
  end

  # -- C14: Writer-restart tip-fold orphan repair -----------------------------

  test "Writer-restart tip-fold (C14): a dangling turn_started is orphaned exactly once on restart" do
    {sid, j} = dangling_journal(1)

    {w2, ^sid, ^j} = start_writer(session_id: sid, journal: j)
    # The first op triggers the tip-fold BEFORE it is honored.
    :ok = Writer.subscribe(w2, self())

    assert length(completed(j)) == 1
    [orphan] = completed(j)
    assert orphan.payload["turnId"] == 1
    assert orphan.payload["outcome"] == "orphaned"
  end

  test "Writer-restart tip-fold is idempotent: a completed tip is a no-op on restart" do
    {sid, j} = dangling_journal(1)

    # First restart heals the strand.
    {w2, ^sid, ^j} = start_writer(session_id: sid, journal: j)
    {:ok, _} = Writer.append(w2, "session_update", %{"x" => 1}, "agent")
    assert length(completed(j)) == 1
    Process.exit(w2, :kill)

    # Second restart: tip is now a plain session_update (last real op), and no
    # turn is open ⇒ no new orphan. Even a restart onto the healed turn_completed
    # tip must not double.
    {w3, ^sid, ^j} = start_writer(session_id: sid, journal: j)
    {:ok, _} = Writer.append(w3, "session_update", %{"x" => 2}, "agent")
    assert length(completed(j)) == 1
  end

  test "Writer-restart onto a completed-turn tip no-ops (no phantom orphan)" do
    {w, sid, j} = start_writer()
    {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 1}, "user")

    {:ok, _} =
      Writer.append(
        w,
        "turn_completed",
        %{"turnId" => 1, "stopReason" => "end_turn"},
        "agent"
      )

    Process.exit(w, :kill)

    {w2, ^sid, ^j} = start_writer(session_id: sid, journal: j)
    :ok = Writer.subscribe(w2, self())
    assert length(completed(j)) == 1
    refute Enum.any?(completed(j), &(&1.payload["outcome"] == "orphaned"))
  end

  # -- R-C14-lazy witnesses: fold MUST run strictly before the first op --------

  test "R-C14-lazy witness (a): fold-AFTER-op buries the strand (dead control)" do
    # Correct (fold-before): the strand is finalized before the new turn.
    {sid_ok, j_ok} = dangling_journal(1)
    {w_ok, ^sid_ok, ^j_ok} = start_writer(session_id: sid_ok, journal: j_ok)
    {:ok, _} = Writer.append(w_ok, "turn_started", %{"turnId" => 2}, "user")

    assert Enum.any?(
             read_all(j_ok),
             &(&1.kind == "turn_completed" and &1.payload["turnId"] == 1)
           )

    # DEAD (fold-after): the new turn_started buries the strand — the tip becomes
    # the NEW turn, so the fold never finalizes strand 1 (violates J7 totality).
    {sid_bad, j_bad} = dangling_journal(1)

    {w_bad, ^sid_bad, ^j_bad} =
      start_writer(
        session_id: sid_bad,
        journal: j_bad,
        __dead_bootstrap_after_op__: true
      )

    {:ok, _} = Writer.append(w_bad, "turn_started", %{"turnId" => 2}, "user")

    refute Enum.any?(
             read_all(j_bad),
             &(&1.kind == "turn_completed" and &1.payload["turnId"] == 1)
           )
  end

  test "R-C14-lazy witness (b): fold-AFTER-op double-completes the new turn (dead control)" do
    # Correct (fold-before): exactly one turn_completed for the new turn.
    {sid_ok, j_ok} = dangling_journal(1)
    {w_ok, ^sid_ok, ^j_ok} = start_writer(session_id: sid_ok, journal: j_ok)
    {:ok, _} = Writer.append(w_ok, "turn_started", %{"turnId" => 2}, "user")

    {:ok, _} =
      Writer.append(
        w_ok,
        "turn_completed",
        %{"turnId" => 2, "stopReason" => "end_turn"},
        "agent"
      )

    assert length(
             for(
               r <- read_all(j_ok),
               r.kind == "turn_completed" and r.payload["turnId"] == 2,
               do: r
             )
           ) ==
             1

    # DEAD (fold-after): the fold runs after the new turn_started, orphans turn 2,
    # then turn 2's real drain appends again ⇒ DOUBLE turn_completed for turn 2.
    {sid_bad, j_bad} = dangling_journal(1)

    {w_bad, ^sid_bad, ^j_bad} =
      start_writer(
        session_id: sid_bad,
        journal: j_bad,
        __dead_bootstrap_after_op__: true
      )

    {:ok, _} = Writer.append(w_bad, "turn_started", %{"turnId" => 2}, "user")

    {:ok, _} =
      Writer.append(
        w_bad,
        "turn_completed",
        %{"turnId" => 2, "stopReason" => "end_turn"},
        "agent"
      )

    assert length(
             for(
               r <- read_all(j_bad),
               r.kind == "turn_completed" and r.payload["turnId"] == 2,
               do: r
             )
           ) ==
             2
  end

  # -- S6: credit-based lagged producer (§5) ----------------------------------

  test "credit exhaustion: the Writer emits a REAL {:reattach_lagged, sid, last_offset} and stops sending (S6)" do
    # A tiny credit forces real lag: one live frame fits, the next overflows.
    {w, sid, _j} = start_writer(subscriber_credit: 1)
    :ok = Writer.subscribe(w, self())

    # Within credit (1) ⇒ delivered live. Genesis took offset 1, so this is 2.
    {:ok, r1} = Writer.append(w, "session_update", %{"i" => 1}, "agent")
    assert_receive {:reattach_live, ^sid, %Record{offset: o1}}
    assert o1 == r1.offset

    # Credit exhausted ⇒ the Writer PRODUCES the lagged message itself (not a test
    # fake), carrying the highest offset it actually sent this subscriber, then
    # demonitors + drops it.
    {:ok, _r2} = Writer.append(w, "session_update", %{"i" => 2}, "agent")
    assert_receive {:reattach_lagged, ^sid, ^o1}

    # Dropped ⇒ no further live frames reach this subscriber, ever.
    {:ok, _r3} = Writer.append(w, "session_update", %{"i" => 3}, "agent")
    refute_receive {:reattach_live, ^sid, _}, 100

    # And the subscriber is gone from the Writer's set (pruned on lag-drop).
    assert :sys.get_state(w).subscribers == %{}
  end

  test "healthy subscriber that replenishes credit never false-lags (credit/3 is LIVE API, S6)" do
    # De-green-wash: the exhaustion test above proves lag when credit runs OUT.
    # This proves the REPLENISH half — a subscriber that drains and calls
    # `credit/3` after each frame tracks 'unforwarded backlog', so it stays
    # attached and receives MORE frames than its (tiny) starting credit, with
    # NO {:reattach_lagged}. Without a live `credit/3`, this drops at credit+1.
    {w, sid, _j} = start_writer(subscriber_credit: 2)
    :ok = Writer.subscribe(w, self())

    # Publish 5 (> credit 2). After each delivery we replenish exactly one credit
    # (as the production reattach Subscriber does after forwarding a frame), so
    # the running credit never reaches 0 and the subscriber is never lagged.
    for i <- 1..5 do
      {:ok, rec} = Writer.append(w, "session_update", %{"i" => i}, "agent")
      assert_receive {:reattach_live, ^sid, %Record{offset: got}}
      assert got == rec.offset
      :ok = Writer.credit(w, self(), 1)
      # Barrier: the credit cast is processed before the next publish, so the
      # replenishment provably lands in time (deterministic, no timing race).
      _ = :sys.get_state(w)
    end

    # Never lagged, and still attached in the Writer's subscriber set.
    refute_received {:reattach_lagged, ^sid, _}
    assert map_size(:sys.get_state(w).subscribers) == 1
  end

  # -- §2.7: a non-holder turn_completed must be REFUSED at the APPEND ---------

  test "non-holder turn_completed is refused at the append — no false durable boundary (§2.7)" do
    # Two connections' Sessions on ONE Writer/session_id. Connection A opens the
    # turn (latch HOLDER). A DIFFERENT connection's turn_completed must be refused
    # at the durable append: persisting it would write a completion row while A's
    # turn is still open, letting a reattacher finalize from a phantom boundary.
    {w, _sid, j} = start_writer()
    test = self()

    holder =
      spawn(fn ->
        {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 1}, "user")
        send(test, :holder_started)

        receive do
          :complete ->
            res =
              Writer.append(
                w,
                "turn_completed",
                %{"turnId" => 1, "stopReason" => "end_turn"},
                "agent"
              )

            send(test, {:holder_completed, res})
        end
      end)

    assert_receive :holder_started
    assert completed(j) == []

    # The non-holder (this test process, != holder) attempts turn_completed.
    non_holder_res =
      Writer.append(
        w,
        "turn_completed",
        %{"turnId" => 1, "stopReason" => "end_turn"},
        "external"
      )

    # Refused: NOT {:ok, record}, and NO durable completion row was written.
    refute match?({:ok, _}, non_holder_res)
    assert completed(j) == []

    # The latch is untouched — A's turn is still open (a fresh turn is rejected).
    assert {:error, :turn_in_flight} =
             Writer.append(w, "turn_started", %{"turnId" => 2}, "user")

    # The HOLDER's turn_completed still appends + clears normally (legit path).
    send(holder, :complete)
    assert_receive {:holder_completed, {:ok, _}}
    assert length(completed(j)) == 1
    [c] = completed(j)
    assert c.payload["turnId"] == 1
    refute c.payload["outcome"] == "orphaned"

    # Latch cleared by the holder — the next turn now succeeds.
    assert {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 3}, "user")
  end

  test "a dead subscriber is pruned from the Writer's set (monitor)" do
    {w, _sid, _j} = start_writer()
    sub = spawn(fn -> receive do: (:never -> :ok) end)
    :ok = Writer.subscribe(w, sub)
    assert map_size(:sys.get_state(w).subscribers) == 1

    ref = Process.monitor(sub)
    Process.exit(sub, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sub, _}
    _ = :sys.get_state(w)

    assert :sys.get_state(w).subscribers == %{}
  end

  # -- Live-bus registration facade (Journal.subscribe/2 → Writer) ------------

  test "Journal.subscribe/2 facade routes registration through the Writer registry" do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    start_supervised!(
      %{
        id: {:reg_writer, sid},
        start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
        restart: :temporary
      },
      restart: :temporary
    )

    assert Writer.whereis(sid) |> is_pid()
    assert :ok = Journal.subscribe(sid, self())

    {:ok, _} =
      Writer.append(Writer.via(sid), "session_update", %{"i" => 1}, "agent")

    assert_receive {:reattach_live, ^sid, %Record{offset: 2}}

    assert :ok = Journal.unsubscribe(sid, self())

    {:ok, _} =
      Writer.append(Writer.via(sid), "session_update", %{"i" => 2}, "agent")

    refute_receive {:reattach_live, ^sid, %Record{offset: 3}}, 100

    # An unknown session has no live Writer — subscribe reports it, unsubscribe no-ops.
    assert {:error, :no_writer} = Journal.subscribe("nope-" <> hex(), self())
    assert :ok = Journal.unsubscribe("nope-" <> hex(), self())
  end
end
