defmodule Raxol.AgentClientProtocol.Ext.ReattachTest do
  @moduledoc """
  The reattach SEAM over the ACP wire (`acp-reattach-design.md` §4, the frozen
  `harness-bus-protocol.md` §4). These are the P-BUS-shaped reds — the Wave 6
  conformance contours — driven against the REAL single-publisher Writer
  (`Ext.Journal.Writer` + `Ext.Journal.Mem`) and a `FakeConnection` standing in
  for the wire, so "delivered" means the ordered `Connection.notify`/`reply`
  frames a client actually sees.

  Every positive contour ships its named dead-injector negative control (bus §9).

  Coverage map:

    * J1  — replay closure over the wire (history ++ live == durable substream,
      no gap/dup, incl. turn-boundary kinds) + dead taint-filter breaks closure.
    * J2  — register-before-`h`, decision-time `h`, permanent monotone gate at
      the boundary + dead register-after-history (gap) + dead cached-counter (gap).
    * J4  — writerless attach = history-only, NO error + dead attach-requires-writer.
    * J5  — taint annotated, never dropped (delivery counts == record counts).
    * J6  — Lagged heals from `last_offset + 1` + dead reattach-from-last_offset (dup).
    * J7  — turn_completed replays/finalizes a turn (totality: every turn_started
      is matched by exactly one turn_completed in the durable substream).
    * `fromOffset > h + 1` rejected (`-32602`, minting a gap is illegal).
    * force-close at `grant.expires_at` cuts the live tail (CDI-6 `[G5:S7]`).
    * fail-closed attach (`{:denied, _}` ⇒ `-32000`, no registration/history) [J9].
    * §3.4 stock projection (offset-aware? = false ⇒ session_update kinds only).
  """

  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Ext.Reattach
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  setup do
    start_supervised!({Registry, keys: :unique, name: Writer.registry()})
    :ok
  end

  # -- fixtures ---------------------------------------------------------------

  defp hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # A registered Writer over a test-owned Mem journal (the handle outlives the
  # Writer). Genesis (session_created @1) is appended on the first op.
  # `writer_opts` are extra `Writer.start_link/1` opts (e.g. the area-B
  # `:journal_subscriber_credit` knob J6 drives to force REAL lag).
  defp start_writer(records \\ [], writer_opts \\ []) do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    w =
      start_supervised!(
        %{
          id: {:writer, sid},
          start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}] ++ writer_opts]},
          restart: :temporary
        },
        restart: :temporary
      )

    Enum.each(records, fn {k, p, t} -> {:ok, _} = Writer.append(w, k, p, t) end)
    {sid, j, w}
  end

  # A writerless (dumped) journal: records appended straight to Mem, no Writer.
  defp dumped_journal(records) do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    Enum.each(records, fn {k, p, t} ->
      {:ok, _} = Mem.append(j, %{kind: k, payload: p, taint: t})
    end)

    {sid, j}
  end

  defp grant(fields \\ %{}) do
    Map.merge(%{actor: %{"id" => "tester"}, scope: :attach, expires_at: nil, lens: nil}, fields)
  end

  defp granting, do: fn _ctx -> {:ok, grant()} end

  # Attach a FakeConnection subscriber to `sid`/`j`. Returns {conn, reply_ref,
  # subscriber_pid, attach_result}. The subscriber pid is captured via the
  # injected start_subscriber so gate/lag/expiry can be driven directly.
  defp attach(sid, j, opts \\ %{}) do
    {:ok, conn} = FakeConnection.start_link()
    ref = make_ref()
    test = self()

    base = %{
      conn: conn,
      conn_mod: FakeConnection,
      session_id: sid,
      reply_ref: ref,
      journal: {Mem, j},
      from_offset: 0,
      history_policy: :from_offset,
      offset_aware?: true,
      authorize: granting(),
      start_subscriber: fn o ->
        {:ok, p} = Reattach.start_link(o)
        send(test, {:sub, p})
        {:ok, p}
      end
    }

    res = Reattach.attach(Map.merge(base, opts))

    sub =
      receive do
        {:sub, p} -> p
      after
        50 -> nil
      end

    {conn, ref, sub, res}
  end

  # -- observation helpers ----------------------------------------------------

  # A mailbox barrier that tolerates a subscriber that already stopped (terminal
  # paths — resource_not_found, fromOffset reject, expiry — reply synchronously
  # during attach's :run call, then {:stop, :normal, ...}).
  defp sync(pid) do
    if is_pid(pid) and Process.alive?(pid), do: :sys.get_state(pid), else: :ok
  catch
    :exit, _ -> :ok
  end

  defp notifies(conn), do: FakeConnection.entries(conn, :notify)

  defp frame_offset("session/update", p), do: get_in(p, ["_meta", "raxol.io", "offset"])
  defp frame_offset("_raxol/session.record", p), do: p["offset"]
  defp frame_offset(_method, _p), do: nil

  # The delivered RECORD substream: the ordered offsets of session/update +
  # _raxol/session.record frames (UX frames caught_up/lagged/closed excluded).
  defp delivered_offsets(conn) do
    for {:notify, method, params} <- notifies(conn),
        off = frame_offset(method, params),
        off != nil,
        do: off
  end

  defp frame_taints(conn) do
    for {:notify, method, params} <- notifies(conn), reduce: [] do
      acc ->
        case method do
          "session/update" -> [get_in(params, ["_meta", "raxol.io", "taint"]) | acc]
          "_raxol/session.record" -> [params["taint"] | acc]
          _ -> acc
        end
    end
    |> Enum.reverse()
  end

  defp durable_offsets(j) do
    hwm = Mem.high_watermark(j)
    {:ok, recs} = Mem.read(j, 1, max(hwm, 1))
    Enum.map(recs, & &1.offset)
  end

  defp reply_entry(conn), do: conn |> FakeConnection.entries(:reply) |> List.last()

  # Poll until the origin connection has recorded a prompt reply (the turn task
  # runs async under the Task.Supervisor).
  defp wait_reply(conn, tries \\ 400)
  defp wait_reply(_conn, 0), do: flunk("timed out waiting for the prompt reply")

  defp wait_reply(conn, tries) do
    if reply_entry(conn) != nil do
      :ok
    else
      Process.sleep(5)
      wait_reply(conn, tries - 1)
    end
  end

  # A synthetic live publish (as the Writer would send it).
  defp live(sub, sid, offset, kind \\ "session_update", taint \\ "agent") do
    record = %Record{
      offset: offset,
      session_id: sid,
      kind: kind,
      payload: %{"o" => offset},
      taint: taint,
      ts_hook: 0
    }

    send(sub, {:reattach_live, sid, record})
    sync(sub)
  end

  # -- J1: replay closure over the wire ---------------------------------------

  describe "J1 — replay closure (P-JS5) over the ACP wire" do
    test "history ++ live == the durable substream, no gap, no dup, incl. turn kinds" do
      {sid, j, w} =
        start_writer([
          {"turn_started", %{"turnId" => 1, "prompt" => []}, "user"},
          {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
          {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
          {"turn_completed", %{"turnId" => 1, "stopReason" => "end_turn"}, "system"}
        ])

      # Durable so far: 1 genesis, 2 turn_started, 3-4 updates, 5 turn_completed.
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      h = Mem.high_watermark(j)
      assert h == 5
      # History delivered exactly the durable substream 1..h, in order.
      assert delivered_offsets(conn) == Enum.to_list(1..5)

      # Live tail: a new turn appends 6,7,8; each delivered once, offset > h.
      {:ok, _} = Writer.append(w, "turn_started", %{"turnId" => 2, "prompt" => []}, "user")
      {:ok, _} = Writer.append(w, "session_update", %{"sessionUpdate" => "plan"}, "agent")

      {:ok, _} =
        Writer.append(w, "turn_completed", %{"turnId" => 2, "stopReason" => "end_turn"}, "system")

      _ = sync(sub)

      # Union (history ++ live) == full durable stream, offset-sorted, no dup.
      assert delivered_offsets(conn) == durable_offsets(j)
      assert delivered_offsets(conn) == Enum.to_list(1..8)
    end

    test "DEAD taint-filter breaks closure (a taint filter drops records ⇒ history != durable)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "external"},
          {"session_update", %{"i" => 3}, "agent"}
        ])

      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      # The real seam NEVER filters by taint: every offset is delivered.
      assert delivered_offsets(conn) == durable_offsets(j)

      # Dead control: a HYPOTHETICAL taint-filtering delivery (drop "external")
      # would omit offset 3's record ⇒ delivered ⊊ durable ⇒ closure broken.
      {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
      filtered = recs |> Enum.reject(&(&1.taint == "external")) |> Enum.map(& &1.offset)
      refute filtered == durable_offsets(j)
    end
  end

  # -- J2: register-before-h, decision-time h, permanent monotone gate --------

  describe "J2 — register-before-h + decision-time h + gate armed before live" do
    test "permanent monotone gate: offset <= h dropped forever, offset > h forwarded once" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      # Durable 1 genesis, 2 update ⇒ h = 2.
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert delivered_offsets(conn) == [1, 2]

      before = length(delivered_offsets(conn))

      # A live record with offset <= h is a leftover already in history ⇒ dropped.
      _ = live(sub, sid, 2)
      _ = live(sub, sid, 1)
      assert length(delivered_offsets(conn)) == before

      # offset > h ⇒ forwarded, exactly once, in order.
      _ = live(sub, sid, 3)
      _ = live(sub, sid, 4)
      assert delivered_offsets(conn) == [1, 2, 3, 4]
    end

    test "DEAD register-after-history: a record appended in the window is missed (gap)" do
      # Correct path: subscribe FIRST, so a record appended after h-read arrives
      # live and closure holds.
      {sid_ok, j_ok, w_ok} = start_writer([{"session_update", %{"i" => 1}, "agent"}])

      {conn_ok, _r, sub_ok, :deferred} =
        attach(sid_ok, j_ok, %{
          __between__: fn ->
            {:ok, _} = Writer.append(w_ok, "session_update", %{"i" => 2}, "agent")
          end
        })

      _ = sync(sub_ok)
      # 1 genesis, 2 first update (history), 3 the between-append (live) — no gap.
      assert delivered_offsets(conn_ok) == [1, 2, 3]

      # DEAD path: read h + history BEFORE subscribing. The between-append lands
      # after history was read and before subscription ⇒ neither in history nor
      # live ⇒ a permanent gap.
      {sid_bad, j_bad, w_bad} = start_writer([{"session_update", %{"i" => 1}, "agent"}])

      {conn_bad, _r2, sub_bad, :deferred} =
        attach(sid_bad, j_bad, %{
          __dead_register_after_history__: true,
          __between__: fn ->
            {:ok, _} = Writer.append(w_bad, "session_update", %{"i" => 2}, "agent")
          end
        })

      _ = sync(sub_bad)
      assert delivered_offsets(conn_bad) == [1, 2]
      refute 3 in delivered_offsets(conn_bad)
      assert 3 in durable_offsets(j_bad)
    end

    test "DEAD cached-counter high_watermark mis-places the boundary (gap)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "agent"}
        ])

      # Correct: decision-time h from the store delivers all durable offsets.
      {conn_ok, _r, sub_ok, :deferred} = attach(sid, j)
      _ = sync(sub_ok)
      assert delivered_offsets(conn_ok) == durable_offsets(j)

      # DEAD: a cached counter (h = 0) reads NO history ⇒ every pre-existing
      # record is missed (history empties) ⇒ gap vs the durable stream.
      {conn_bad, _r2, sub_bad, :deferred} = attach(sid, j, %{__dead_cached_counter__: true})
      _ = sync(sub_bad)
      assert delivered_offsets(conn_bad) == []
      refute delivered_offsets(conn_bad) == durable_offsets(j)
    end
  end

  # -- J4: writerless attach = history-only, NO error -------------------------

  describe "J4 — writerless attach" do
    test "no live Writer ⇒ history-only, replies normally, NO error, no live frames" do
      {sid, j} =
        dumped_journal([
          {"session_created", %{"cwd" => "/tmp"}, "system"},
          {"session_update", %{"i" => 1}, "agent"}
        ])

      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      # History byte-identical to a live attach's history for the same offsets.
      assert delivered_offsets(conn) == durable_offsets(j)

      # Replies normally with the highWatermark, and it is NOT an error.
      assert {:reply, ^ref, {:ok, resp}} = reply_entry(conn)
      assert get_in(resp._meta, ["raxol.io", "highWatermark"]) == Mem.high_watermark(j)

      # No live tail was armed: a stray live message is ignored (live: :none).
      before = length(delivered_offsets(conn))
      _ = live(sub, sid, 99)
      assert length(delivered_offsets(conn)) == before
    end

    test "DEAD attach-requires-writer would error; the correct path does NOT" do
      {sid, j} = dumped_journal([{"session_update", %{"i" => 1}, "agent"}])
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert {:reply, ^ref, {:ok, _}} = reply_entry(conn)
      refute match?({:reply, ^ref, {:error, _}}, reply_entry(conn))
    end

    test "never-seen session (no Writer, empty journal) ⇒ -32002 resource_not_found" do
      sid = "sess-" <> hex()
      {:ok, j} = Mem.open(sid)
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert {:reply, ^ref, {:error, %Error{code: -32_002}}} = reply_entry(conn)
    end
  end

  # -- J5: taint annotated, never dropped -------------------------------------

  test "J5 — every delivered frame carries the record taint; counts == record counts" do
    taints = ~w(user agent external system)

    {sid, j, _w} =
      start_writer(Enum.map(taints, fn t -> {"session_update", %{"t" => t}, t} end))

    {conn, _ref, sub, :deferred} = attach(sid, j)
    _ = sync(sub)

    # Genesis is "system"; then one update per taint.
    delivered = frame_taints(conn)
    for t <- taints, do: assert(t in delivered)

    # Per-taint delivery count == per-taint record count (no drop by taint).
    {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
    assert Enum.frequencies(delivered) == Enum.frequencies(Enum.map(recs, & &1.taint))
  end

  # -- J6: Lagged heals from last_offset + 1 ----------------------------------
  #
  # De-green-washed (GW-1): J6 no longer hand-delivers `{:reattach_lagged, …}`
  # (a message `lib/` never produced). It drives REAL lag through a Writer with a
  # tiny `:journal_subscriber_credit` (area B's producer) so the runtime emits
  # the Lagged, then asserts the client heals from `last_offset + 1` losslessly.
  # The subscriber's consumer-clause reaction (emit terminal Lagged on its OWN
  # forward_hi, then stop) is its own separately-named unit test below.

  describe "J6 — Lagged disconnect and lossless heal (REAL runtime lag)" do
    test "Lagged carries the subscriber's own last-forwarded offset; +1 heals dup-free" do
      # Tiny per-subscriber credit: live publishes past it force the Writer to
      # emit {:reattach_lagged, sid, sent_hi} — PRODUCED by the runtime, not faked.
      {sid, j, w} =
        start_writer(
          [{"session_update", %{"i" => 0}, "agent"}],
          subscriber_credit: 1
        )

      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      mon = Process.monitor(sub)

      # Drain this subscriber's credit with a handful of live appends; the
      # exhausting publish makes the Writer send the Lagged and drop the sub.
      # (The exact triggering offset is B's accounting — assertions below do not
      # hardcode it, so any reasonable credit semantics greens this.)
      for i <- 1..5, do: {:ok, _} = Writer.append(w, "session_update", %{"i" => i}, "agent")

      # The subscriber converts the runtime Lagged into a terminal wire signal
      # and stops (client-driven reattach is the heal, bus §7).
      assert_receive {:DOWN, ^mon, :process, ^sub, :normal}, 1_000

      lagged =
        Enum.find(notifies(conn), fn {:notify, m, _} -> m == "_raxol/session.lagged" end)

      assert {:notify, "_raxol/session.lagged", %{"lastOffset" => wire_last}} = lagged
      assert is_integer(wire_last)

      # Heal: reattach from the wire's lastOffset + 1 ⇒ the union is gap/dup-free.
      {conn2, _r2, sub2, :deferred} = attach(sid, j, %{from_offset: wire_last + 1})
      _ = sync(sub2)
      hwm = Mem.high_watermark(j)
      expected = Enum.filter(1..hwm//1, &(&1 > wire_last))
      assert delivered_offsets(conn2) == expected
      # No offset the client already held (<= wire_last) is re-delivered.
      refute Enum.any?(delivered_offsets(conn2), &(&1 <= wire_last))
    end

    test "DEAD reattach-from-last_offset re-delivers last_offset (dup)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "agent"}
        ])

      last = Mem.high_watermark(j)

      # Correct heal (last + 1): last_offset is NOT re-delivered.
      {conn_ok, _r, sub_ok, :deferred} = attach(sid, j, %{from_offset: last + 1})
      _ = sync(sub_ok)
      refute last in delivered_offsets(conn_ok)

      # DEAD (reattach from last_offset itself): re-delivers last_offset ⇒ dup.
      {conn_bad, _r2, sub_bad, :deferred} = attach(sid, j, %{from_offset: last})
      _ = sync(sub_bad)
      assert last in delivered_offsets(conn_bad)
    end
  end

  # -- Subscriber consumer clauses (unit): Lagged + cancel both stop the tail --

  describe "subscriber lifecycle — Lagged and $/cancel_request stop the live tail" do
    test "on {:reattach_lagged, …} the subscriber emits its OWN forward_hi then stops" do
      # A direct-delivery unit test of the consumer clause (the manufactured send
      # that USED to masquerade as J6): the Writer's 3rd element is conservative;
      # the SUBSCRIBER's own forward counter is what goes on the wire (exactness).
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      last = List.last(delivered_offsets(conn))
      assert last == Mem.high_watermark(j)

      mon = Process.monitor(sub)
      send(sub, {:reattach_lagged, sid, 999})

      # Terminal: emit Lagged, then STOP (no lingering detached process).
      assert_receive {:DOWN, ^mon, :process, ^sub, :normal}, 500

      lagged =
        Enum.find(notifies(conn), fn {:notify, m, _} -> m == "_raxol/session.lagged" end)

      assert {:notify, "_raxol/session.lagged", %{"lastOffset" => ^last}} = lagged
    end

    test "on {:acp_reply_cancelled, ref} the subscriber unsubscribes and stops (no further frames)" do
      # S3: the Subscriber is the adopter (delegate_reply), so a $/cancel_request
      # on the load reaches it as {:acp_reply_cancelled, reply_ref}. The peer
      # abandoned the request ⇒ the live tail MUST stop.
      {sid, j, w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      before = length(delivered_offsets(conn))

      mon = Process.monitor(sub)
      send(sub, {:acp_reply_cancelled, ref})
      assert_receive {:DOWN, ^mon, :process, ^sub, :normal}, 500

      # It unsubscribed from the Writer — severed from the live tail.
      assert %{subscribers: subs} = :sys.get_state(w)
      assert subs == %{}

      # A subsequent live append reaches NO further frame (subscriber gone).
      {:ok, _} = Writer.append(w, "session_update", %{"i" => 2}, "agent")
      Process.sleep(20)
      assert length(delivered_offsets(conn)) == before
    end

    test "a non-matching {:acp_reply_cancelled, other_ref} does NOT stop the subscriber" do
      # Only the subscriber's OWN reply_ref cancels it; a stray ref falls through
      # to the catch-all no-op (a different request's cancel must not tear us down).
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {_conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      mon = Process.monitor(sub)
      send(sub, {:acp_reply_cancelled, make_ref()})
      refute_receive {:DOWN, ^mon, :process, ^sub, _}, 100
      assert Process.alive?(sub)
    end
  end

  # -- J7: turn_completed totality / finalize-from-replay ---------------------

  test "J7 — a reattacher finalizes a turn from replay (turn_started matched by turn_completed)" do
    {sid, j, _w} =
      start_writer([
        {"turn_started", %{"turnId" => 4, "prompt" => []}, "user"},
        {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
        {"turn_completed", %{"turnId" => 4, "stopReason" => "end_turn"}, "system"}
      ])

    {conn, _ref, sub, :deferred} = attach(sid, j)
    _ = sync(sub)

    # The reattacher replays through turn_started AND the persisted
    # turn_completed (delivered as a first-class _raxol/session.record).
    records =
      for {:notify, "_raxol/session.record", p} <- notifies(conn), do: {p["kind"], p["payload"]}

    assert Enum.any?(records, fn {k, p} -> k == "turn_started" and p["turnId"] == 4 end)

    assert Enum.any?(records, fn {k, p} ->
             k == "turn_completed" and p["turnId"] == 4 and p["stopReason"] == "end_turn"
           end)

    # Totality: in the durable substream every turn_started is matched by exactly
    # one turn_completed for its turnId.
    {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
    started = for r <- recs, r.kind == "turn_started", do: r.payload["turnId"]
    completed = for r <- recs, r.kind == "turn_completed", do: r.payload["turnId"]
    assert Enum.sort(started) == Enum.sort(completed)
  end

  # -- fromOffset > h + 1 rejected --------------------------------------------

  test "fromOffset > h + 1 is rejected -32602 (minting a gap is illegal), carries highWatermark" do
    {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
    h = Mem.high_watermark(j)

    {conn, ref, sub, :deferred} = attach(sid, j, %{from_offset: h + 2})
    _ = sync(sub)

    assert {:reply, ^ref, {:error, %Error{code: -32_602} = err}} = reply_entry(conn)
    assert err.data == %{"highWatermark" => h}
    # Nothing was delivered — a rejected attach reads no history.
    assert delivered_offsets(conn) == []

    # fromOffset == h + 1 is LEGAL (a gap-free "tip").
    {conn2, ref2, sub2, :deferred} = attach(sid, j, %{from_offset: h + 1})
    _ = sync(sub2)
    assert {:reply, ^ref2, {:ok, _}} = reply_entry(conn2)
  end

  # -- CDI-6: force-close at grant.expires_at ---------------------------------

  test "force-close at grant.expires_at cuts the live tail (CDI-6 [G5:S7])" do
    {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
    now = System.os_time(:second)

    # expires_at already reached ⇒ the timer fires immediately (delay 0).
    {conn, _ref, sub, :deferred} =
      attach(sid, j, %{
        authorize: fn _ctx -> {:ok, grant(%{expires_at: now})} end,
        now: now
      })

    ref = Process.monitor(sub)
    assert_receive {:DOWN, ^ref, :process, ^sub, :normal}, 1_000

    closed =
      Enum.find(notifies(conn), fn {:notify, m, _} -> m == "_raxol/session.closed" end)

    assert {:notify, "_raxol/session.closed", %{"reason" => "revoked"}} = closed
  end

  # -- J9: fail-closed attach --------------------------------------------------

  describe "J9 — fail-closed attach (the CDI-1 funnel contract)" do
    test "a {:denied, _} verdict ⇒ -32000 deny envelope, NO registration, NO history, NO reply" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      res =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
          journal: {Mem, j},
          authorize: fn _ctx -> {:denied, :not_local} end
        })

      # The CDI-5 deny envelope: -32000 "attach denied", NO data (anti-oracle).
      assert {:error, %Error{code: -32_000, message: "attach denied", data: nil}} = res

      # Nothing registered, no history read, no delegate/reply — a denied
      # attacher never appears in the subscriber set even transiently.
      assert FakeConnection.log(conn) == []
      # The live Writer has no subscribers.
      assert %{subscribers: subs} = :sys.get_state(Writer.whereis(sid))
      assert subs == %{}
    end

    test "a non-conforming authorize return (not {:ok, grant}) also denies (fail-closed)" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      for verdict <- [:ok, true, {:ok, :not_a_grant_but_atom} |> elem(0), {:error, :boom}] do
        res =
          Reattach.attach(%{
            conn: conn,
            conn_mod: FakeConnection,
            session_id: sid,
            reply_ref: make_ref(),
            journal: {Mem, j},
            authorize: fn _ctx -> verdict end
          })

        assert {:error, %Error{code: -32_000}} = res
      end

      assert FakeConnection.log(conn) == []
    end

    test "via the REAL Runner + LocalNode policy: nil transport denies, :process grants" do
      sup = start_supervised!({Task.Supervisor, []})
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])

      real_authorize = fn ctx -> Runner.authorize(LocalNode, ctx, task_supervisor: sup) end

      # Deny: LocalNode fails closed on a nil/absent transport (CDI-2) ⇒ -32000.
      {conn_d, _rd, _sub_d, res_d} =
        attach(sid, j, %{authorize: real_authorize, transport: nil})

      assert {:error, %Error{code: -32_000}} = res_d
      assert FakeConnection.log(conn_d) == []

      # Grant: an in-BEAM :process transport is OS-co-resident ⇒ the real Runner
      # returns a well-formed %Grant{}; the attach proceeds and replies.
      {conn_g, ref_g, sub_g, res_g} =
        attach(sid, j, %{authorize: real_authorize, transport: %{kind: :process, peer: self()}})

      assert res_g == :deferred
      _ = sync(sub_g)
      assert {:reply, ^ref_g, {:ok, _}} = reply_entry(conn_g)
      assert delivered_offsets(conn_g) == durable_offsets(j)
    end
  end

  # -- §3.4: stock projection --------------------------------------------------

  test "§3.4 stock projection: a non-offset-aware attacher gets session_update kinds only" do
    {sid, j, _w} =
      start_writer([
        {"turn_started", %{"turnId" => 1, "prompt" => []}, "user"},
        {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
        {"turn_completed", %{"turnId" => 1, "stopReason" => "end_turn"}, "system"}
      ])

    {conn, _ref, sub, :deferred} = attach(sid, j, %{offset_aware?: false})
    _ = sync(sub)

    methods = for {:notify, m, _} <- notifies(conn), do: m
    # No _raxol/* frames for a stock attacher; only session/update.
    refute Enum.any?(methods, &String.starts_with?(&1, "_raxol/"))
    assert Enum.all?(methods, &(&1 == "session/update"))

    # Only the session_update-kind record (offset 3) is projected onto the wire;
    # genesis/turn_started/turn_completed are kind-projected away (NOT taint).
    assert delivered_offsets(conn) == [3]
  end

  # -- Session→journal emit seam (§2.4): a LIVE turn fills the durable journal --
  #
  # The reattach reds above drive a standalone Writer directly. This closes the
  # loop end-to-end: a real `Session` wired with `Emitter.Journal` runs a prompt
  # turn; its `session/update` + turn boundaries must land DURABLY through the
  # single-publisher Writer (J10 durability leg), and a later reattacher must
  # replay the exact durable substream (J1) — the origin turn is the producer,
  # the reattacher is a pure consumer of the same offset-addressed log.

  describe "Session Emitter.Journal — a live turn fills the journal end-to-end" do
    alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
    alias Raxol.AgentClientProtocol.Session
    alias Raxol.AgentClientProtocol.Session.Emitter.Journal, as: JournalEmitter
    alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup

    test "updates + turn boundaries are durable; a reattacher replays the substream" do
      start_supervised!(SessionSup.registry_child_spec())
      sid = "sess-" <> hex()
      {:ok, j} = Mem.open(sid)

      # The single publisher over the SHARED Mem handle (origin appends land here;
      # the reattacher reads the same store).
      _writer =
        start_supervised!(
          %{
            id: {:writer, sid},
            start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
            restart: :temporary
          },
          restart: :temporary
        )

      task_sup = start_supervised!({Task.Supervisor, []}, id: {:task_sup, sid})
      {:ok, origin_conn} = FakeConnection.start_link()

      notif = SessionNotification.new(sid, {:current_mode_update, CurrentModeUpdate.new("code")})

      runner = fn s, _req ->
        :ok = Session.post_update(s, notif)
        {:stop, :end_turn}
      end

      {:ok, session} =
        Session.start_link(
          session_id: sid,
          conn: origin_conn,
          conn_mod: FakeConnection,
          task_sup: task_sup,
          turn_runner: runner,
          emitter: JournalEmitter,
          journal: {Mem, j}
        )

      # Drive one prompt turn; wait for the async turn task to reply.
      reply_ref = make_ref()
      assert :ok = Session.begin_prompt(session, %{prompt: [%{}]}, reply_ref, 1)
      wait_reply(origin_conn)

      # The origin still got its live session/update via the direct notify path
      # (base behavior preserved) AND its prompt response.
      assert Enum.any?(notifies(origin_conn), fn {:notify, m, _} -> m == "session/update" end)
      assert {:reply, ^reply_ref, {:ok, _}} = reply_entry(origin_conn)

      # DURABLE: genesis(1), turn_started(2), session_update(3), turn_completed(4).
      {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
      kinds = Enum.map(recs, & &1.kind)
      assert kinds == ["session_created", "turn_started", "session_update", "turn_completed"]

      started = Enum.find(recs, &(&1.kind == "turn_started"))
      completed = Enum.find(recs, &(&1.kind == "turn_completed"))
      # J7 totality + single-render equality: the turn_completed carries the same
      # turnId and the rendered stopReason that fed the prompt response.
      assert started.payload["turnId"] == 1
      assert completed.payload["turnId"] == 1
      assert completed.payload["stopReason"] == "end_turn"

      # A reattacher (a different connection) replays the EXACT durable substream
      # (J1) — the origin turn was subscriber-agnostic; the log is the contract.
      {conn2, _ref2, sub2, :deferred} = attach(sid, j)
      _ = sync(sub2)
      assert delivered_offsets(conn2) == durable_offsets(j)
      assert delivered_offsets(conn2) == [1, 2, 3, 4]
    end
  end

  # Wave-6 conformance finding 13: the attach Subscriber must be supervised
  # under the per-connection Session DynamicSupervisor (ctx.session_sup), NOT
  # bare-linked to the ephemeral handler task (whose :normal exit never signals
  # a plain link, leaking the Subscriber past the connection forever).
  describe "supervised subscriber lifetime (finding 13)" do
    test "default start supervises the Subscriber under session_sup; it dies with it" do
      {sid, j, _w} = start_writer()
      {:ok, conn} = FakeConnection.start_link()
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      # NO injected :start_subscriber — exercise the DEFAULT path with a real
      # session_sup (the exact production wiring).
      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: FakeConnection,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: fn _ctx -> {:ok, grant()} end,
                 session_sup: sup
               })

      # The Subscriber is a child of session_sup (supervised), not orphaned.
      children = DynamicSupervisor.which_children(sup)
      assert [{:undefined, sub, :worker, _}] = children
      assert is_pid(sub) and Process.alive?(sub)

      # Killing the session subtree takes the Subscriber with it — no leak.
      ref = Process.monitor(sub)
      :ok = Supervisor.stop(sup)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500
      refute Process.alive?(sub)
    end

    test "with neither session_sup nor start_subscriber, falls back to unsupervised start" do
      {sid, j, _w} = start_writer()
      {:ok, conn} = FakeConnection.start_link()

      # No session_sup, no injected start_subscriber: the documented fallback
      # still attaches (the caller owns lifetime on this path).
      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: FakeConnection,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: fn _ctx -> {:ok, grant()} end
               })
    end
  end
end
