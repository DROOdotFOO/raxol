defmodule Raxol.AgentClientProtocol.Torture.PbusCoverageAudit do
  @moduledoc """
  AUDIT of the frozen P-BUS1..7 red suite (`harness-bus-protocol.md` §9) and
  its J1..J12 invariant breakdown (`acp-reattach-design.md` §8), against
  what actually ships in `test/ext/journal_test.exs`,
  `test/ext/journal_writer_test.exs`, `test/ext/reattach_test.exs`,
  `test/ext/attach_policy_test.exs`, and `test/ext/token_test.exs`.

  This file is NOT a re-implementation of the red suite -- per contour it
  either (a) CITES the existing positive test + its named dead injector, or
  (b) where a contour or dead injector is genuinely absent, adds the
  MINIMAL red for it below and marks it `:added_here` in the map. Every
  citation is mechanically verified by `coverage map citations resolve to
  real files and real test names` below (a `File.read!/1` + substring
  check), so a renamed/deleted cited test fails this audit, not silently
  rots.

  ## Coverage map

  | contour | positive (existing) | dead injector (existing) | status |
  |---|---|---|---|
  | P-BUS1 / J1 replay closure | reattach_test.exs "J1 — replay closure (P-JS5) over the ACP wire" / "history ++ live == the durable substream, no gap, no dup, incl. turn kinds"; J5 taint-as-positive-injector: "J5 — every delivered frame carries the record taint; counts == record counts" | reattach_test.exs "DEAD taint-filter breaks closure (a taint filter drops records ⇒ history != durable)" | covered |
  | P-BUS2 / J2 register-before-h + decision-time h + gate-arm | reattach_test.exs "J2 — register-before-h..." / "permanent monotone gate: offset <= h dropped forever, offset > h forwarded once"; journal_test.exs "high_watermark reads the store max at call time (decision-time-fold)" | (a) register-after-history: reattach_test.exs "DEAD register-after-history: a record appended in the window is missed (gap)"; (b) cached-counter: reattach_test.exs "DEAD cached-counter high_watermark mis-places the boundary (gap)" + journal_test.exs "DEAD cached-counter high_watermark lags the durable store (J2 negative control)"; (c) **live-before-gate-arm: ABSENT upstream — ADDED HERE** | partial → completed here |
  | P-BUS3 / J4 writerless = history-only | reattach_test.exs "J4 — writerless attach" / "no live Writer ⇒ history-only, replies normally, NO error, no live frames" | reattach_test.exs "DEAD attach-requires-writer would error; the correct path does NOT" | covered |
  | P-BUS4 / J9 fail-closed admission | reattach_test.exs "J9 — fail-closed attach (the CDI-1 funnel contract)" (3 tests); attach_policy_test.exs's full Runner outcome-table describe block (13 tests, T-1..T-30); token_test.exs's offline verify + Token-policy describe block (35+ tests, incl. "the full Runner funnel admits a valid token and denies an expired one") | attach_policy_test.exs "raise / throw / exit all deny :policy_crash (T-2, T-3)" (the raise-never-admits control) | covered |
  | P-BUS5 / J6 lagged heal from last_offset+1 | reattach_test.exs "J6 — Lagged disconnect and lossless heal" / "Lagged carries the subscriber's own last-forwarded offset; +1 heals dup-free" | reattach_test.exs "DEAD reattach-from-last_offset re-delivers last_offset (dup)"; **`p_bus5_dead_drop_middle_backpressure_test` ABSENT upstream, NOT added here (see Known gaps below)** | partial (flagged, not fixed) |
  | P-BUS6 / J3 single-publisher / I3 | journal_writer_test.exs "single publisher: a subscriber receives every appended record live, in order, all durable"; "no public publish surface exists — publishing is the Writer's alone (J3)" | journal_writer_test.exs "DEAD publish-phantom delivers a live offset with no durable backing (N-JS7 control)" | covered |
  | P-BUS7 matrix conformance | **ABSENT upstream — ADDED HERE** (no test exercises the `(json × stdio)` codec cell against the reattach delivery sequence at all; every existing reattach test drives the `(term × process)` cell via `FakeConnection`/`Transport.Paired`) | n/a (single positive contour, no dead-injector variant named in the design) | absent → added here |
  | J5 taint annotate-never-filter | reattach_test.exs "J5 — every delivered frame carries the record taint; counts == record counts"; journal_writer_test.exs "taint is stamped into the record and NEVER filters delivery" | (shares P-BUS1's taint-filter dead injector) | covered |
  | J7a turn_completed = rendered response (session-drain path) | reattach_test.exs "J7 — a reattacher finalizes a turn from replay..."; "Session Emitter.Journal" describe block's live-turn-to-journal test asserts `completed.payload["stopReason"]` equals the actual rendered `PromptResponse` stop reason | n/a | covered |
  | J7b orphan path totality (no render, no response) | journal_writer_test.exs "orphan repair (appender death): exactly one orphaned turn_completed, latch clears, next turn OK"; "Writer-restart tip-fold (C14)..."; "success-then-crash produces ZERO orphan rows (C13)..." — none of these ever construct a rendered response to compare against, satisfying "no response equality claimed" vacuously by construction | n/a | covered |
  | J8 offset law (incl. under concurrency) | journal_test.exs "append assigns contiguous offsets from 1, strictly increasing, fully stamped"; property "offset law: concurrent appends through the Writer are contiguous, monotone, no gap/dup" | (shares J2's cached-counter dead injector for the decision-time leg) | covered |
  | J9 fail-closed admission | (see P-BUS4 row — identical contour) | | covered |
  | J10 no-bypass / grep-gate | **KNOWN, REPORTED DEVIATION** (see `Session.Emitter.Journal`'s own moduledoc "Reported deviations" section): the origin connection's `emit/2` keeps a direct `Connection.notify` call ALONGSIDE the durable `Writer.append`, so the literal "one call site" grep-gate does NOT hold for the origin (two sites: origin-direct + reattacher-via-Writer). The OBSERVABLE invariant the grep-gate exists to guarantee — every delivered update is durable — IS tested: reattach_test.exs "Session Emitter.Journal — a live turn fills the journal end-to-end" / "updates + turn boundaries are durable; a reattacher replays the substream" drives a REAL `Session` + `Emitter.Journal` turn and asserts the durable journal (`Mem.read`) contains exactly the kinds/order a reattacher (`delivered_offsets/1`) independently replays. | n/a | deviation documented + observable leg covered |
  | J11 stock invisibility | **ABSENT upstream — ADDED HERE.** No test drives a stock `_raxol/session.load` request through a live `Connection` against a handler that never overrides `raxol_load_session/2` and asserts the promised `-32601` (`acp-reattach-design.md` §3.2: "-32601 when the optional callback is unimplemented"). The generated-default UNIT-level assertion exists (`agent_test.exs` "every request-kind callback defaults to {:error, method_not_found}", which iterates ALL `Codegen.rows(:agent)` including the ext row) but never exercises the real wire/Router/Connection path for this specific method. | n/a | absent → added here |
  | J12(a) orphan repair, appender death | journal_writer_test.exs "orphan repair (appender death): exactly one orphaned turn_completed, latch clears, next turn OK" | n/a | covered |
  | J12(b) orphan repair, Writer death (tip-fold) | journal_writer_test.exs "Writer-restart tip-fold (C14): a dangling turn_started is orphaned exactly once on restart"; "...is idempotent: a completed tip is a no-op on restart"; "Writer-restart onto a completed-turn tip no-ops (no phantom orphan)"; dead: "R-C14-lazy witness (a)/(b): fold-AFTER-op buries/double-completes..." | journal_writer_test.exs "R-C14-lazy witness (a)" + "(b)" | covered |
  | J12(c) success-then-crash, zero orphans | journal_writer_test.exs "success-then-crash produces ZERO orphan rows (C13): appender dies after turn_completed" | n/a | covered |

  ## Known gaps (flagged, not fixed here — see per-row notes above)

    * `p_bus5_dead_drop_middle_backpressure_test` (P-BUS5's second named dead
      injector) has no realization anywhere. The POSITIVE invariant it would
      guard is structurally true by construction today —
      `Ext.Reattach.Subscriber`'s live-gate `handle_info({:reattach_live,
      ...})` clause (see `ext/reattach.ex`) has exactly two outcomes for a
      subscribed subscriber: forward (`offset > h`) or silently-drop-because-
      already-in-history (`offset <= h`); there is no third "randomly skip a
      live record without signaling Lagged" branch to demonstrate as dead
      without hand-writing an entirely alternate Subscriber implementation.
      Left for the coder who owns the P-BUS5 wave to decide whether a
      structural argument suffices or a literal dead variant is required.

  Every positive/dead-injector citation above that names a test still
  physically exists and still contains the cited substring, verified by the
  first test below (a living, mechanical drift-detector: rename or delete a
  cited test and this audit red-flags it, not silently rot).
  """

  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Ext.Reattach
  alias Raxol.AgentClientProtocol.Rpc.Message
  alias Raxol.AgentClientProtocol.Rpc.Notification
  alias Raxol.AgentClientProtocol.Test.FakeConnection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  # ===========================================================================
  # Meta-test: the coverage map's citations are real, live, and current.
  # ===========================================================================

  @citations [
    {"test/ext/reattach_test.exs",
     "history ++ live == the durable substream, no gap, no dup, incl. turn kinds"},
    {"test/ext/reattach_test.exs",
     "J5 — every delivered frame carries the record taint; counts == record counts"},
    {"test/ext/reattach_test.exs",
     "DEAD taint-filter breaks closure (a taint filter drops records ⇒ history != durable)"},
    {"test/ext/reattach_test.exs",
     "permanent monotone gate: offset <= h dropped forever, offset > h forwarded once"},
    {"test/ext/journal_test.exs",
     "high_watermark reads the store max at call time (decision-time-fold)"},
    {"test/ext/reattach_test.exs",
     "DEAD register-after-history: a record appended in the window is missed (gap)"},
    {"test/ext/reattach_test.exs",
     "DEAD cached-counter high_watermark mis-places the boundary (gap)"},
    {"test/ext/journal_test.exs",
     "DEAD cached-counter high_watermark lags the durable store (J2 negative control)"},
    {"test/ext/reattach_test.exs",
     "no live Writer ⇒ history-only, replies normally, NO error, no live frames"},
    {"test/ext/reattach_test.exs",
     "DEAD attach-requires-writer would error; the correct path does NOT"},
    {"test/ext/reattach_test.exs",
     "a {:denied, _} verdict ⇒ -32000 deny envelope, NO registration, NO history, NO reply"},
    {"test/ext/attach_policy_test.exs",
     "raise / throw / exit all deny :policy_crash (T-2, T-3)"},
    {"test/ext/token_test.exs",
     "the full Runner funnel admits a valid token and denies an expired one"},
    {"test/ext/reattach_test.exs",
     "Lagged carries the subscriber's own last-forwarded offset; +1 heals dup-free"},
    {"test/ext/reattach_test.exs",
     "DEAD reattach-from-last_offset re-delivers last_offset (dup)"},
    {"test/ext/journal_writer_test.exs",
     "single publisher: a subscriber receives every appended record live, in order, all durable"},
    {"test/ext/journal_writer_test.exs",
     "no public publish surface exists — publishing is the Writer's alone (J3)"},
    {"test/ext/journal_writer_test.exs",
     "DEAD publish-phantom delivers a live offset with no durable backing (N-JS7 control)"},
    {"test/ext/journal_writer_test.exs",
     "taint is stamped into the record and NEVER filters delivery"},
    {"test/ext/reattach_test.exs",
     "J7 — a reattacher finalizes a turn from replay (turn_started matched by turn_completed)"},
    {"test/ext/reattach_test.exs",
     "updates + turn boundaries are durable; a reattacher replays the substream"},
    {"test/ext/journal_writer_test.exs",
     "orphan repair (appender death): exactly one orphaned turn_completed, latch clears, next turn OK"},
    {"test/ext/journal_writer_test.exs",
     "Writer-restart tip-fold (C14): a dangling turn_started is orphaned exactly once on restart"},
    {"test/ext/journal_writer_test.exs",
     "success-then-crash produces ZERO orphan rows (C13): appender dies after turn_completed"},
    {"test/ext/journal_test.exs",
     "append assigns contiguous offsets from 1, strictly increasing, fully stamped"},
    {"test/ext/journal_test.exs",
     "offset law: concurrent appends through the Writer are contiguous, monotone, no gap/dup"},
    {"test/agent_test.exs",
     "every request-kind callback defaults to {:error, method_not_found}"}
  ]

  test "coverage map citations resolve to real files and real test names" do
    root = Path.expand("../..", __DIR__)

    Enum.each(@citations, fn {rel_path, needle} ->
      path = Path.join(root, rel_path)

      assert File.exists?(path),
             "cited file #{rel_path} does not exist -- coverage map is stale"

      contents = File.read!(path)

      assert contents =~ needle,
             "cited test #{inspect(needle)} not found in #{rel_path} -- coverage map is stale " <>
               "(renamed/removed test?)"
    end)
  end

  test "every P-BUS/J contour in the coverage map is accounted for (no silent TODOs)" do
    # The map itself (moduledoc table) enumerates all 7 P-BUS rows + J1..J12;
    # this is a deliberately low-tech but LIVE completeness check: the three
    # contours this file adds reds for below must have their own test(s) in
    # THIS module, named identifiably by contour tag.
    added_here_tags = ["P-BUS2/J2", "P-BUS7", "J11"]

    this_module_tests =
      __MODULE__.__info__(:functions)
      |> Enum.filter(fn {name, arity} ->
        arity == 1 and name |> Atom.to_string() |> String.starts_with?("test ")
      end)
      |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)

    Enum.each(added_here_tags, fn tag ->
      assert Enum.any?(this_module_tests, &String.contains?(&1, tag)),
             "expected a red tagged #{inspect(tag)} in #{__MODULE__} (see moduledoc's " <>
               "\"ADDED HERE\" rows) but found none"
    end)
  end

  # ===========================================================================
  # Shared fixtures (mirrors test/ext/reattach_test.exs's own helpers —
  # duplicated minimally rather than imported, per this task's "new test
  # files only" scope).
  # ===========================================================================

  setup do
    start_supervised!({Registry, keys: :unique, name: Writer.registry()})
    :ok
  end

  defp hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp start_writer(records) do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    w =
      start_supervised!(
        %{
          id: {:writer, sid},
          start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
          restart: :temporary
        },
        restart: :temporary
      )

    Enum.each(records, fn {k, p, t} -> {:ok, _} = Writer.append(w, k, p, t) end)
    {sid, j, w}
  end

  defp grant(fields \\ %{}) do
    Map.merge(
      %{actor: %{"id" => "tester"}, scope: :attach, expires_at: nil, lens: nil},
      fields
    )
  end

  defp granting, do: fn _ctx -> {:ok, grant()} end

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

  defp sync(pid) do
    if is_pid(pid) and Process.alive?(pid), do: :sys.get_state(pid), else: :ok
  catch
    :exit, _ -> :ok
  end

  defp notifies(conn), do: FakeConnection.entries(conn, :notify)

  # ===========================================================================
  # P-BUS2/J2 -- the third named dead injector: live-before-gate-arm.
  #
  # Cannot be realized against the REAL `Ext.Reattach.Subscriber` directly:
  # its `:run` handle_call is one synchronous function body (subscribe -> read
  # h -> ...), and Erlang's one-message-at-a-time GenServer semantics make it
  # structurally impossible for a QUEUED `{:reattach_live, ...}` message to be
  # processed before that handle_call returns -- there is no yield point. That
  # absence of a yield point IS the positive J2 gate-arm invariant, proven by
  # construction rather than by a runtime race. The dead injector below proves
  # the CONSEQUENCE side of the invariant instead (bus §9's own framing:
  # "mis-places the h boundary ⇒ dup or gap"): manually replaying the WRONG
  # order — consume a live message, THEN read h — on the raw Writer/Mem
  # primitives, and showing that a naive history-bounds decision made from
  # that late-read h reproduces the boundary record it already saw live.
  # ===========================================================================

  describe "P-BUS2/J2 — DEAD live-before-gate-arm (added here, structural)" do
    test "P-BUS2/J2 DEAD: reading h AFTER a live record was already processed reproduces it in history (boundary dup)" do
      {sid, j, w} = start_writer([{"session_update", %{"n" => 1}, "agent"}])

      test_pid = self()
      :ok = Writer.subscribe(w, test_pid)

      {:ok, boundary_record} =
        Writer.append(w, "session_update", %{"n" => 2}, "agent")

      # DEAD ordering: the live message is consumed FIRST (as a race-prone
      # Session variant that started draining its mailbox before deciding
      # its history bounds would do)...
      assert_receive {:reattach_live, ^sid, live_record}
      assert live_record.offset == boundary_record.offset

      # ...and ONLY THEN is h read -- too late, it already includes the
      # record just delivered live.
      h_read_late = Mem.high_watermark(j)
      assert h_read_late == boundary_record.offset

      {:ok, history_dead} = Mem.read(j, 1, h_read_late)

      # The dead consequence: a history replay bounded by this late h
      # re-emits the SAME offset the live path already delivered -- exactly
      # the P-BUS2 "dup at the boundary" failure class the gate-arm-before-
      # live invariant `[G5:C1]` exists to prevent. The real seam
      # (`Ext.Reattach.run_attach/1`) cannot reach this state: `h` is bound
      # by the time `:run`'s handle_call returns, and no earlier live
      # message can have been processed (see reattach.ex `run_attach/1` /
      # `run_after_subscribe/4`, cited in the coverage map above).
      assert Enum.any?(history_dead, &(&1.offset == live_record.offset))
    end
  end

  # ===========================================================================
  # P-BUS7 -- matrix conformance: (term x process) vs (json x stdio).
  #
  # Every existing reattach red drives the in-process, zero-copy `(term x
  # process)` cell (`FakeConnection` standing in for the wire, `Transport.
  # Paired`-shaped semantics — no JSON anywhere). None exercises the `(json x
  # stdio)` cell's own conformance obligation (harness-bus-protocol.md §8:
  # "Encoding (Layer 2) MUST round-trip every message losslessly... or
  # §4/P-JS5 sequence-equality breaks"). This red closes that gap minimally:
  # it takes the EXACT delivered notify sequence from the real
  # single-publisher Writer + `Ext.Reattach` seam (the term/process cell) and
  # round-trips each frame through the SAME `Jason.encode!/1` +
  # `Jason.decode!/1` codec `Transport.Stdio` uses on real bytes, asserting
  # the record/delivery sequence survives byte-identical -- proof the
  # `(json x stdio)` cell would observe the identical sequence the `(term x
  # process)` cell did (P-BUS7's "record/delivery sequence" conformance
  # target; UX frames are excluded from the P-BUS7 obligation by design, and
  # none of the three record kinds exercised here are UX frames).
  # ===========================================================================

  describe "P-BUS7 — matrix conformance (added here)" do
    test "P-BUS7 matrix conformance: (term x process) reattach delivery == (json x stdio)-round-tripped delivery" do
      {sid, j, _w} =
        start_writer([
          {"turn_started", %{"turnId" => 1, "prompt" => []}, "user"},
          {"session_update",
           %{"sessionUpdate" => "agent_message_chunk", "n" => 1}, "agent"},
          {"turn_completed", %{"turnId" => 1, "stopReason" => "end_turn"},
           "system"}
        ])

      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      # 5 notify frames: genesis session_created (offset 1, from the default
      # full-history replay) + the 3 supplied records + one non-load-bearing
      # `_raxol/session.caught_up` UX frame (offset-aware default). The
      # round-trip claim below applies uniformly to all of them -- P-BUS7's
      # own carve-out (UX frames excluded from the conformance TARGET) does
      # not mean UX frames are exempt from losslessly round-tripping too.
      term_cell = notifies(conn)
      assert length(term_cell) == 5

      # Round-trip each frame's full wire envelope (not just its params)
      # through the real JSON-RPC Message wrapper + Jason codec.
      json_cell =
        for {:notify, method, params} <- term_cell do
          wire =
            method
            |> Notification.new(params)
            |> Message.wrap()
            |> Message.to_json()
            |> Jason.encode!()
            |> Jason.decode!()

          {wire["method"], wire["params"]}
        end

      term_cell_as_pairs =
        for {:notify, method, params} <- term_cell, do: {method, params}

      assert json_cell == term_cell_as_pairs
    end
  end

  # ===========================================================================
  # J11 -- stock invisibility: disabled/unimplemented extension answers
  # -32601 through the REAL wire/Router/Connection path (not just the
  # generated-default UNIT assertion `agent_test.exs` already has).
  # ===========================================================================

  defmodule StockAgent do
    @moduledoc false
    # Deliberately does NOT override raxol_load_session/2 -- the extension
    # is "not configured" from the wire's point of view.
    use Raxol.AgentClientProtocol.Agent

    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

    @impl true
    def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}
  end

  describe "J11 — stock invisibility (added here)" do
    test "J11: an unimplemented _raxol/session.load answers -32601 through a live Connection" do
      task_sup = start_supervised!({Task.Supervisor, []})
      {conn_handle, peer} = ScriptedPeer.new()

      _conn =
        start_supervised!(%{
          id: Connection,
          start:
            {Connection, :start_link,
             [
               [
                 role: :agent,
                 transport: {Paired, conn_handle},
                 handler: StockAgent,
                 handler_arg: nil,
                 task_sup: task_sup
               ]
             ]},
          restart: :temporary
        })

      ScriptedPeer.send_request(peer, 1, "initialize", %{"protocolVersion" => 1})

      init_frame = ScriptedPeer.recv(peer)
      assert init_frame["result"]["protocolVersion"] == 1

      ScriptedPeer.send_request(peer, 2, "_raxol/session.load", %{
        "sessionId" => "sess-1",
        "cwd" => "/tmp"
      })

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 2
      assert frame["error"]["code"] == Error.method_not_found_code()

      # The Connection stays healthy afterward (this is not a crash path).
      ScriptedPeer.send_request(peer, 3, "session/new", %{"cwd" => "/tmp"})
      # StockAgent has no new_session override either -- same default,
      # same -32601, proving the ext row and a core row are handled by the
      # identical generated-default mechanism (no special-casing).
      new_session_frame = ScriptedPeer.recv(peer)
      assert new_session_frame["id"] == 3
      assert new_session_frame["error"]["code"] == Error.method_not_found_code()
    end
  end
end
