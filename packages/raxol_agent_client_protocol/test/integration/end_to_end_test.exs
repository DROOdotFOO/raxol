defmodule Raxol.AgentClientProtocol.Integration.EndToEndTest do
  @moduledoc """
  The headline end-to-end proof of the ASSEMBLED supervision tree (W-sup).

  Everything the per-connection subtree + reattach extension needs is started
  the way `RaxolAgentClientProtocol.Application.children/0` starts it (the
  SessionRegistry, the journal `WriterRegistry` + `WriterSupervisor`, and the
  AttachPolicy `TaskSupervisor`) — here under the ExUnit-owned test supervisor
  (the "injected tree", equivalent to the real `Application` but startable per
  test without colliding with the rest of the suite). We then drive a REAL
  agent<->client conversation over `Transport.Paired` through the assembled
  tree:

    * `initialize` handshake, `session/new`, a `session/prompt` turn streaming
      two `session/update`s with an agent→client `session/request_permission`
      round-trip — verified both ways: a `selected` outcome resolves to allow,
      a non-`selected` outcome fails **closed** to deny (I8);
    * the MOAT: a SECOND client attaches via `_raxol/session.load` (fromOffset
      0) through a SECOND agent connection sharing the same durable journal +
      single-publisher Writer, replays the full durable history, catches up to
      live, and receives subsequent live updates — asserting P-JS5 closure
      (delivered offsets == durable offsets, no gap/no dup) across a REAL
      journal Writer + the REAL `LocalNode` AttachPolicy admitting a `:process`
      transport through the REAL `Runner` funnel (which needs the assembled
      `TaskSupervisor` — without it every attach would deny `:policy_infra`);
    * a reattach mid-turn finalizes from the persisted `turn_completed` the
      Writer synthesizes on origin-session death (orphan repair, §2.6);
    * a denied attach (no token under `Token` policy) gets the single
      `-32000 "attach denied"` envelope (CDI-5), nothing registered.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Token
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  # ===========================================================================
  # Reference agent + client handlers (a minimal, spec-faithful pair)
  # ===========================================================================

  defmodule RefAgent do
    @moduledoc false
    use Raxol.AgentClientProtocol.Agent

    alias Raxol.AgentClientProtocol.Error
    alias Raxol.AgentClientProtocol.Ext.Journal
    alias Raxol.AgentClientProtocol.Ext.Reattach
    alias Raxol.AgentClientProtocol.Session
    alias Raxol.AgentClientProtocol.Session.Emitter.Journal, as: JournalEmitter

    alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
    alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
    alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
    alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest
    alias Raxol.AgentClientProtocol.Schema.ContentChunk
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
    alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
    alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields

    # handler_arg = %{session_id, journal: {Mem, j}, test: pid, attach_policy: mod}
    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

    @impl true
    def new_session(_req, ctx) do
      %{session_id: sid, journal: journal} = ctx.handler_state
      {:ok, _writer} = Journal.ensure_writer(sid, journal)

      {:ok, _session} =
        Session.Supervisor.start_session(ctx.session_sup,
          session_id: sid,
          conn: ctx.conn,
          task_sup: ctx.task_sup,
          turn_runner: runner(ctx.handler_state),
          emitter: JournalEmitter,
          journal: journal
        )

      {:ok, NewSessionResponse.new(sid)}
    end

    @impl true
    def prompt(req, ctx) do
      case Registry.lookup(Session.registry(), {ctx.conn, req.session_id}) do
        [{pid, _} | _] ->
          case Session.begin_prompt(pid, req, ctx.reply_ref, ctx.rx_seq) do
            :ok -> :deferred
            {:error, %Error{} = e} -> {:error, e}
          end

        [] ->
          {:error, Error.new(-32602, "unknown session")}
      end
    end

    # `_raxol/session.load` is a real MethodTable ext row (callback
    # `:raxol_load_session`, params `LoadSessionRequest` — the rider rides its
    # `_meta`), NOT a bare `_`-prefixed ext request. It converges on the ONE
    # attach seam (`Reattach.attach/1`).
    @impl true
    def raxol_load_session(%{session_id: sid, _meta: meta}, ctx) do
      st = ctx.handler_state
      rider = Reattach.parse_rider(get_in(meta, ["raxol.io"]))

      Reattach.attach(%{
        conn: ctx.conn,
        session_id: sid,
        reply_ref: ctx.reply_ref,
        journal: st.journal,
        from_offset: rider.from_offset,
        history_policy: rider.history_policy,
        capability: rider.capability,
        offset_aware?: true,
        surface: :process,
        # CDI-2: Connection-sourced (in-BEAM Paired ⇒ :process), never peer-asserted.
        transport: %{kind: :process, peer: nil},
        policy: st.attach_policy,
        # Tie the attach Subscriber's lifetime to THIS connection's subtree: start
        # it under the per-connection Session.Supervisor (a DynamicSupervisor), so
        # it is torn down with the connection instead of orphaning past it (the
        # default `Reattach.start_link` links it to the ephemeral handler task,
        # which exits :normal and leaves the Subscriber leaked).
        start_subscriber: fn sub_opts ->
          DynamicSupervisor.start_child(ctx.session_sup, %{
            id: make_ref(),
            start: {Reattach, :start_link, [sub_opts]},
            restart: :temporary
          })
        end
      })
    end

    # The injected turn runner. Content "live" ⇒ a single update (the live-tail
    # probe). Content "hang" ⇒ one update then block forever (the mid-turn death
    # fixture). Otherwise: the full streamed turn with a granted + a fail-closed
    # denied permission round-trip.
    defp runner(%{session_id: sid, test: test}) do
      fn session, req ->
        case prompt_text(req) do
          "live" ->
            :ok = Session.post_update(session, chunk(sid, "live-update"))
            {:stop, :end_turn}

          "hang" ->
            # Link the turn task to the Session so that killing the Session
            # (models mid-turn death) also reaps this task — no orphaned
            # `sleep(:infinity)` lingering under the Task.Supervisor past the test.
            Process.link(session)
            :ok = Session.post_update(session, chunk(sid, "before-hang"))
            Process.sleep(:infinity)

          _ ->
            :ok = Session.post_update(session, chunk(sid, "hello "))

            grant =
              Session.request_permission(
                session,
                perm(sid, [PermissionOption.new("allow", "Allow", :allow_once)])
              )

            send(test, {:perm_result, :grant, grant})

            :ok = Session.post_update(session, chunk(sid, "world"))

            deny =
              Session.request_permission(
                session,
                perm(sid, [PermissionOption.new("nope", "No", :reject_once)])
              )

            send(test, {:perm_result, :deny, deny})
            {:stop, :end_turn}
        end
      end
    end

    defp perm(sid, options) do
      tool_call = ToolCallUpdate.new("tc-1", ToolCallUpdateFields.new())
      RequestPermissionRequest.new(sid, tool_call, options)
    end

    defp chunk(sid, text) do
      block = ContentBlock.from_string(text)

      SessionNotification.new(
        sid,
        {:agent_message_chunk, ContentChunk.new(block)}
      )
    end

    defp prompt_text(%{prompt: [block | _]}), do: block_text(block)
    defp prompt_text(_), do: nil

    defp block_text({:text, %{text: t}}), do: t
    defp block_text(_), do: nil
  end

  defmodule RefClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
    alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome

    # handler_arg = %{tag: atom, test: pid}
    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def request_permission(req, _ctx) do
      # Grant iff the offered option list leads with "allow"; otherwise deny —
      # the client-side half of the fail-closed permission proof.
      outcome =
        case req.options do
          [%{option_id: "allow"} | _] ->
            {:selected, SelectedPermissionOutcome.new("allow")}

          _ ->
            :cancelled
        end

      {:ok, RequestPermissionResponse.new(outcome)}
    end

    @impl true
    def session_update(notification, ctx) do
      %{tag: tag, test: test} = ctx.handler_state
      offset = get_in(notification._meta, ["raxol.io", "offset"])
      send(test, {tag, :update, offset})
      :ok
    end

    # `_raxol/session.record` is a real ext row (callback `:raxol_session_record`)
    # decoded to a `SessionRecordNotification` (first-class offset/kind/payload) —
    # the generic frame for every non-`session_update` record kind.
    @impl true
    def raxol_session_record(notification, ctx) do
      %{tag: tag, test: test} = ctx.handler_state

      send(
        test,
        {tag, :record, notification.offset, notification.kind,
         notification.payload}
      )

      :ok
    end

    # `_raxol/session.caught_up` / `.lagged` / `.closed` are still raw ext
    # notifications (not table rows) — the boundary markers, not records.
    @impl true
    def handle_ext_notification(wire, _params, ctx) do
      %{tag: tag, test: test} = ctx.handler_state
      send(test, {tag, :marker, wire})
      :ok
    end
  end

  # ===========================================================================
  # Assembled-tree fixtures
  # ===========================================================================

  setup do
    # Start EXACTLY the package Application's shared children (the assembled
    # tree), under the ExUnit test supervisor, with unique ids. This is the
    # injected equivalent of the auto-started Application (which is empty under
    # :test on purpose).
    RaxolAgentClientProtocol.Application.children()
    |> Enum.with_index()
    |> Enum.each(fn {spec, i} ->
      start_supervised!(Supervisor.child_spec(spec, id: {:acp_tree, i}))
    end)

    :ok
  end

  defp hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Open a fresh per-session Mem journal owned by the TEST process (outlives any
  # Writer, so a Writer restart / orphan tip-fold survives — §1.4).
  defp open_journal do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)
    {sid, {Mem, j}}
  end

  # Start a real agent connection subtree (the IC-8 §1.2 ConnectionSupervisor)
  # and a real client connection subtree, joined by a Paired transport, then run
  # the initialize handshake. Returns %{agent_conn, client_conn}.
  defp connect(agent_arg, client_tag, client_test \\ self()) do
    {left, right} = Paired.create_pair()

    # `:temporary` so ExUnit's test supervisor never RESTARTS a subtree that
    # `auto_shutdown`s (from the Paired-kill on_exit, or the mid-turn session
    # death) — a restart during teardown would re-adopt a dead handle and churn.
    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:agent, make_ref()},
            handler: RefAgent,
            handler_arg: agent_arg,
            transport: {Paired, left}
          ),
          :restart,
          :temporary
        )
      )

    client_sup =
      start_supervised!(
        Map.put(
          AcpClient.child_spec(
            id: {:client, make_ref()},
            handler: RefClient,
            handler_arg: %{tag: client_tag, test: client_test},
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        )
      )

    agent_conn = connection_of(agent_sup)
    client_conn = connection_of(client_sup)

    # Hermetic teardown: kill the Paired carrier procs (they are start_link'd to
    # THIS test process by `create_pair/0`, so a plain :normal test exit would
    # leave them orphaned and alive) so nothing this test spawned outlives it and
    # perturbs a later sync test.
    on_exit(fn ->
      for %Paired{pid: p} <- [left, right], is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    # Barrier: both Connections must have adopted their transport (left :booting)
    # before the first frame, else a Paired frame to a not-yet-owned handle drops.
    assert_adopted(agent_conn)
    assert_adopted(client_conn)

    {:ok, _} =
      Connection.request(
        client_conn,
        "initialize",
        InitializeRequest.new(1),
        2_000
      )

    %{agent_conn: agent_conn, client_conn: client_conn}
  end

  defp connection_of(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn {_id, pid, _type, mods} ->
      if is_pid(pid) and Connection in mods, do: pid
    end)
  end

  defp assert_adopted(conn) do
    wait_until(fn -> :sys.get_state(conn).phase != :booting end)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  # Drain a tagged client's inbound record frames until a quiet period. Returns
  # the list of {kind, offset, payload} for durable-record frames ONLY — i.e.
  # `session/update` (offset in _meta) and `_raxol/session.record` (offset +
  # kind + payload first-class). The boundary marker `_raxol/session.caught_up`
  # (and lagged/closed) are NOT records and are skipped.
  # Collect exactly `n` durable-record frames for a tagged client — count-based
  # (not a fragile quiet-window), so it is robust under full-suite scheduling
  # load. `session/update` (offset in _meta) and `_raxol/session.record` (offset
  # + kind + payload first-class) both count; boundary markers
  # (`_raxol/session.caught_up`/lagged/closed) do NOT.
  defp collect_records(tag, n, acc \\ [])
  defp collect_records(_tag, 0, acc), do: Enum.reverse(acc)

  defp collect_records(tag, n, acc) do
    receive do
      {^tag, :update, offset} ->
        collect_records(tag, n - 1, [{"session_update", offset, nil} | acc])

      {^tag, :record, offset, kind, payload} ->
        collect_records(tag, n - 1, [{kind, offset, payload} | acc])

      {^tag, :marker, _wire} ->
        collect_records(tag, n, acc)
    after
      5_000 ->
        flunk(
          "timed out waiting for #{n} more #{tag} record(s); got #{inspect(Enum.reverse(acc))}"
        )
    end
  end

  defp offsets(records), do: Enum.map(records, fn {_k, o, _p} -> o end)

  defp durable_offsets({Mem, j}), do: Enum.to_list(1..Mem.high_watermark(j))

  defp durable_kinds({Mem, j}) do
    {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
    Enum.map(recs, & &1.kind)
  end

  # ===========================================================================
  # 1. Headline conversation + the MOAT
  # ===========================================================================

  @tag :moat
  test "full conversation over Paired, then a second client reattaches and closes P-JS5" do
    {sid, journal} = open_journal()

    agent_arg = %{
      session_id: sid,
      journal: journal,
      test: self(),
      attach_policy: LocalNode
    }

    %{client_conn: client1} = connect(agent_arg, :c1)

    # -- session/new --
    {:ok, %NewSessionResponse{session_id: ^sid}} =
      Connection.request(
        client1,
        "session/new",
        NewSessionRequest.new("/"),
        2_000
      )

    # -- session/prompt: a full turn (2 updates + 2 permission round-trips) --
    prompt = PromptRequest.new(sid, [ContentBlock.from_string("hi")])

    turn =
      Task.async(fn ->
        Connection.request(client1, "session/prompt", prompt, 5_000)
      end)

    # The agent→client permission requests round-trip over the real wire:
    # the "allow"-led ask resolves to selected, the other fails CLOSED to deny.
    assert_receive {:perm_result, :grant, {:ok, {:selected, _sel}}}, 3_000
    assert_receive {:perm_result, :deny, {:ok, :cancelled}}, 3_000

    assert {:ok, %PromptResponse{stop_reason: :end_turn}} =
             Task.await(turn, 5_000)

    # Durable journal after turn 1: genesis, turn_started, 2 updates, turn_completed.
    assert durable_kinds(journal) ==
             [
               "session_created",
               "turn_started",
               "session_update",
               "session_update",
               "turn_completed"
             ]

    h1 = Mem.high_watermark(elem_j(journal))
    assert h1 == 5

    # -- MOAT: a SECOND agent connection (shares the journal + Writer) serves a
    #    reattach for a SECOND client. --
    agent_arg2 = %{
      session_id: sid,
      journal: journal,
      test: self(),
      attach_policy: LocalNode
    }

    %{client_conn: client2} = connect(agent_arg2, :c2)

    assert {:ok, %LoadSessionResponse{}} =
             Connection.request(
               client2,
               "_raxol/session.load",
               load_request(sid, 0),
               3_000
             )

    # History replay: the reattacher received the full durable substream 1..5.
    # (Offsets are compared as a SET: the wire is ordered per the design, but this
    # client observes each frame in a concurrent handler task, so their arrival
    # order at the test mailbox is not the observable — closure is set equality.)
    history = collect_records(:c2, 5)
    assert Enum.sort(offsets(history)) == [1, 2, 3, 4, 5]
    assert durable_offsets(journal) == [1, 2, 3, 4, 5]

    # -- live tail: drive another turn on the ORIGIN client; the reattacher (a
    #    live subscriber to the same Writer) receives the new records live. --
    live_prompt = PromptRequest.new(sid, [ContentBlock.from_string("live")])

    assert {:ok, %PromptResponse{stop_reason: :end_turn}} =
             Connection.request(client1, "session/prompt", live_prompt, 5_000)

    live = collect_records(:c2, 3)

    # turn_started(6), session_update(7), turn_completed(8) — all > h1, no dup.
    assert Enum.sort(offsets(live)) == [6, 7, 8]

    # P-JS5 closure over the wire: delivered (history ++ live) == durable, no
    # gap, no dup — across a REAL Writer + REAL LocalNode admit + REAL Runner.
    delivered = offsets(history) ++ offsets(live)
    assert delivered == Enum.uniq(delivered)
    assert Enum.sort(delivered) == durable_offsets(journal)
    assert durable_offsets(journal) == [1, 2, 3, 4, 5, 6, 7, 8]
  end

  # ===========================================================================
  # 2. Reattach mid-turn finalizes from the persisted turn_completed
  # ===========================================================================

  @tag :midturn
  test "reattach mid-turn: origin-session death ⇒ Writer orphan-repairs turn_completed ⇒ reattacher finalizes from replay" do
    {sid, journal} = open_journal()

    agent_arg = %{
      session_id: sid,
      journal: journal,
      test: self(),
      attach_policy: LocalNode
    }

    %{agent_conn: agent1, client_conn: client1} = connect(agent_arg, :c1)

    {:ok, _} =
      Connection.request(
        client1,
        "session/new",
        NewSessionRequest.new("/"),
        2_000
      )

    # A "hang" prompt: the runner posts one update, then blocks forever. The turn
    # stays open (turn_started appended, turn latch held in the Writer). Run it in
    # a task; killing the session below resolves it as a -32603 to this caller.
    hang = PromptRequest.new(sid, [ContentBlock.from_string("hang")])

    turn =
      Task.async(fn ->
        Connection.request(client1, "session/prompt", hang, 5_000)
      end)

    # Wait until turn_started + the one update are durable (hwm 3).
    wait_until(fn -> Mem.high_watermark(elem_j(journal)) >= 3 end)

    # Kill the origin Session mid-turn (models connection death, design §7.2). The
    # Writer monitors the appender (the Session) and orphan-repairs: exactly one
    # synthetic turn_completed{outcome: orphaned, stopReason: cancelled}, §2.6. The
    # linked turn task (see the "hang" runner branch) dies with it — no orphan.
    [{session_pid, _} | _] = Registry.lookup(Session.registry(), {agent1, sid})
    # `:shutdown` (not `:kill`): the Session is a `:temporary` DynamicSupervisor
    # child, so a `:shutdown` exit is a clean, non-restarting removal with NO
    # crash-report logging (a `:kill` burst-logs supervisor reports that can
    # perturb timing-sensitive neighbors). The Writer's appender-DOWN orphan
    # repair and the adopter-death `-32603` both fire on ANY exit reason.
    Process.exit(session_pid, :shutdown)

    # The parked origin prompt caller unwinds (adopter death ⇒ -32603); await it so
    # the linked driver task never outlives the test.
    assert {:error, _} = Task.await(turn, 5_000)

    wait_until(fn -> Mem.high_watermark(elem_j(journal)) >= 4 end)

    assert durable_kinds(journal) == [
             "session_created",
             "turn_started",
             "session_update",
             "turn_completed"
           ]

    # A reattacher replays and FINALIZES the turn from the persisted turn_completed.
    agent_arg2 = %{
      session_id: sid,
      journal: journal,
      test: self(),
      attach_policy: LocalNode
    }

    %{client_conn: client2} = connect(agent_arg2, :c2)

    assert {:ok, %LoadSessionResponse{}} =
             Connection.request(
               client2,
               "_raxol/session.load",
               load_request(sid, 0),
               3_000
             )

    records = collect_records(:c2, 4)
    assert Enum.sort(offsets(records)) == [1, 2, 3, 4]

    completed =
      Enum.find(records, fn {kind, _o, _p} -> kind == "turn_completed" end)

    assert completed != nil
    {_kind, 4, payload} = completed
    assert payload["stopReason"] == "cancelled"
    assert payload["outcome"] == "orphaned"
  end

  # ===========================================================================
  # 3. Denied attach — no token under Token policy ⇒ -32000, nothing registered
  # ===========================================================================

  @tag :denied
  test "denied attach: tokenless _raxol/session.load under Token policy gets -32000 (CDI-5)" do
    {sid, journal} = open_journal()

    agent_arg = %{
      session_id: sid,
      journal: journal,
      test: self(),
      attach_policy: Token
    }

    %{client_conn: client} = connect(agent_arg, :c1)

    # No capability rider ⇒ Token denies (:token_required) through the real
    # Runner funnel ⇒ the single CDI-5 envelope: -32000 "attach denied", no data.
    assert {:error, %Error{code: -32000, message: "attach denied"} = err} =
             Connection.request(
               client,
               "_raxol/session.load",
               load_request(sid, 0),
               3_000
             )

    assert Map.get(err, :data) in [nil, %{}]
  end

  defp elem_j({Mem, j}), do: j

  # A `_raxol/session.load` request: a `LoadSessionRequest` (reused verbatim,
  # §3.1) with the attach rider riding its `_meta` — one parser, one location.
  defp load_request(sid, from_offset) do
    %{
      LoadSessionRequest.new(sid, "/")
      | _meta: %{"raxol.io" => %{"fromOffset" => from_offset}}
    }
  end
end
