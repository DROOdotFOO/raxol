defmodule Raxol.AgentClientProtocol.SessionSteerTest do
  @moduledoc """
  Track E / U6-I — the steer channel over the REAL `Session`.

  These reds drive `Session.steer/2` against a live turn-owning Session, proving
  the single-writer seam: the injected `SteerAdapter`'s compare-and-swap runs from
  the Session's own mailbox, the honest CAS vocabulary is returned synchronously,
  an accept forwards the steered text to the runner (`{:acp_steer, text}`) and
  fires the emitter's durable steer hook, and every rejection changes nothing and
  journals nothing.

  The CAS *correctness* (ABA, §5.1 idempotency, order-independence) is owned and
  exhaustively covered by the pure decision core's suite in `raxol_agent`
  (`Raxol.Agent.Red.U6SteerRedTest`). Here the adapter is a faithful local double
  of that decision so the tests exercise the SEAM, not re-litigate the core.
  """
  use ExUnit.Case, async: false
  use Raxol.AgentClientProtocol.Test.InvariantSentinel

  alias Raxol.AgentClientProtocol.Ext.Schema.SteerRequest
  alias Raxol.AgentClientProtocol.Ext.Schema.SteerResponse
  alias Raxol.AgentClientProtocol.Router
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  # -- A faithful local CAS adapter (mirrors Raxol.Agent.Steer, which this
  #    package must never depend on). steer_state is a plain map. ---------------
  defmodule Adapter do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Session.SteerAdapter

    def initial, do: %{turn_id: nil, seen: %{}, log: [], last_offset: 0}

    @impl true
    def turn_started(state, token), do: %{state | turn_id: token}

    @impl true
    def turn_ended(state), do: %{state | turn_id: nil}

    @impl true
    def resolve(%{turn_id: cur, seen: seen} = state, %{
          expected_turn_id: expected,
          client_msg_id: cmid,
          text: text
        }) do
      cond do
        not is_nil(cmid) and Map.has_key?(seen, cmid) ->
          %{ref: ref, text: original} = Map.fetch!(seen, cmid)

          if original == text,
            do: {{:ok, {:duplicate, ref}}, state},
            else: {{:error, :client_msg_id_reuse}, state}

        is_nil(cur) ->
          {{:error, :no_live_turn}, state}

        expected != cur ->
          {{:error, {:stale_turn, expected, cur}}, state}

        true ->
          offset = state.last_offset + 1
          ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}
          seen2 = if is_nil(cmid), do: seen, else: Map.put(seen, cmid, %{ref: ref, text: text})

          next = %{
            state
            | turn_id: {:steered, cur, System.unique_integer([:positive])},
              seen: seen2,
              log: [ref | state.log],
              last_offset: offset
          }

          {{:ok, {:accepted, ref}}, next}
      end
    end
  end

  # -- A recording emitter double: captures steer_accepted invocations so the
  #    "accept is durable, rejects are not" contract is observable. -------------
  defmodule RecordingEmitter do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Session.Emitter

    @impl true
    def emit(state, notification) do
      _ = state.conn_mod.notify(state.conn, "session/update", notification)
      :ok
    end

    @impl true
    def turn_started(_state, _req, _turn_id), do: :ok

    @impl true
    def turn_completed(_state, _rendered, _turn_id), do: :ok

    @impl true
    def steer_accepted(state, ref, request) do
      # The emitter only gets the session state; resolve the test sink through the
      # SessionRegistry keyed by session_id (the test registers itself there).
      case Registry.lookup(
             Raxol.AgentClientProtocol.SessionRegistry,
             {:steer_sink, state.session_id}
           ) do
        [{pid, _} | _] -> send(pid, {:steer_journaled, ref, request})
        [] -> :ok
      end

      :ok
    end
  end

  setup do
    start_supervised!(SessionSup.registry_child_spec())
    task_sup = start_supervised!({Task.Supervisor, []})
    {:ok, task_sup: task_sup}
  end

  defp new_conn, do: start_supervised!({FakeConnection, []}, id: {:conn, make_ref()})

  # A runner that stays live (so the turn is prompting during steer), forwarding
  # any `{:acp_steer, text}` it receives to the test process, ending on `:finish`.
  defp live_runner(test_pid) do
    fn _session, _req ->
      loop = fn loop ->
        receive do
          {:acp_steer, text} ->
            send(test_pid, {:runner_saw_steer, text})
            loop.(loop)

          :finish ->
            {:stop, :end_turn}

          :acp_cancel ->
            {:stop, :cancelled}
        after
          3_000 -> {:stop, :end_turn}
        end
      end

      loop.(loop)
    end
  end

  defp start_session(ctx, conn, overrides) do
    sid = "sess-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    opts = [
      session_id: sid,
      conn: conn,
      conn_mod: FakeConnection,
      task_sup: ctx.task_sup,
      turn_runner: Keyword.fetch!(overrides, :turn_runner),
      steer_adapter: Keyword.get(overrides, :steer_adapter, Adapter),
      steer_state: Keyword.get(overrides, :steer_state, Adapter.initial()),
      emitter: Keyword.get(overrides, :emitter, Session.Emitter.Direct),
      config: Keyword.get(overrides, :config, %{cancel_backstop_ms: 50})
    ]

    pid =
      start_supervised!(%{
        id: {:sess, sid, make_ref()},
        start: {Session, :start_link, [opts]},
        restart: :temporary
      })

    {pid, sid}
  end

  defp begin(session, rx_seq \\ 1) do
    reply_ref = make_ref()
    :ok = Session.begin_prompt(session, %{prompt: [%{}]}, reply_ref, rx_seq)
    reply_ref
  end

  # ---------------------------------------------------------------------------
  # CAS arms over the real Session
  # ---------------------------------------------------------------------------

  describe "CAS arms (real Session, single-writer mailbox)" do
    test "accept: matching expected_turn_id lands, forwards text to the runner", ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      result =
        Session.steer(session, %{text: "go left", expected_turn_id: 1, client_msg_id: "m1"})

      assert {:ok, {:accepted, ref}} = result
      assert ref.turn_id == 1
      assert ref.client_msg_id == "m1"
      # The steered text reached the running turn's runner (the {:acp_steer, _} seam).
      assert_receive {:runner_saw_steer, "go left"}, 1_000
    end

    test "stale: a wrong expected_turn_id rejects {:stale_turn, expected, actual}", ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      result =
        Session.steer(session, %{text: "too late", expected_turn_id: 99, client_msg_id: "m1"})

      assert result == {:error, {:stale_turn, 99, 1}}
      refute_receive {:runner_saw_steer, _}, 200
    end

    test "no_live_turn: a steer against an idle session (no turn) rejects", ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      # No begin_prompt — the session is idle, the adapter's turn_id is nil.

      result = Session.steer(session, %{text: "hello?", expected_turn_id: 1, client_msg_id: "m1"})

      assert result == {:error, :no_live_turn}
    end

    # This test's whole point is a turn that ends having streamed nothing, so it
    # legitimately trips the ADR-0030 delivery guard. Declared rather than
    # muted: the tag asserts the event FIRES, which pins the fact that a
    # completed non-empty-prompt turn with zero updates is observable here.
    @tag expect_invariant: [[:raxol, :acp, :zero_updates_turn]]
    test "no_live_turn: after the turn ends, the CAS token is cleared", ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      # End the turn (runner returns {:stop, :end_turn}); finish/2 clears the token.
      %{turn: {:prompting, t}} = :sys.get_state(session)
      send(t.root_pid, :finish)
      wait_until(fn -> :sys.get_state(session).turn == :idle end)

      result = Session.steer(session, %{text: "late", expected_turn_id: 1, client_msg_id: "m1"})
      assert result == {:error, :no_live_turn}
    end
  end

  # ---------------------------------------------------------------------------
  # Double-steer dedup + client_msg_id reuse
  # ---------------------------------------------------------------------------

  describe "idempotency over the real Session" do
    test "duplicate: same client_msg_id + payload re-delivered acks-as-duplicate, no re-forward",
         ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      req = %{text: "once", expected_turn_id: 1, client_msg_id: "dup"}
      assert {:ok, {:accepted, ref}} = Session.steer(session, req)
      assert_receive {:runner_saw_steer, "once"}, 1_000

      # Re-deliver identical: duplicate, referencing the original accept.
      assert {:ok, {:duplicate, ^ref}} = Session.steer(session, req)
      # No SECOND forward to the runner.
      refute_receive {:runner_saw_steer, _}, 200
    end

    test "reuse: same client_msg_id, different payload rejects {:client_msg_id_reuse}", ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      assert {:ok, {:accepted, _}} =
               Session.steer(session, %{text: "left", expected_turn_id: 1, client_msg_id: "k"})

      assert_receive {:runner_saw_steer, "left"}, 1_000

      assert {:error, :client_msg_id_reuse} =
               Session.steer(session, %{text: "RIGHT", expected_turn_id: 1, client_msg_id: "k"})

      refute_receive {:runner_saw_steer, _}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # Journal record: an ACCEPT is durable, rejections are not
  # ---------------------------------------------------------------------------

  describe "steer-accept journal record shape (emitter seam)" do
    test "accept fires steer_accepted with the ref + request; reject/duplicate do not", ctx do
      conn = new_conn()

      {session, sid} =
        start_session(ctx, conn,
          turn_runner: live_runner(self()),
          emitter: RecordingEmitter
        )

      # Route the emitter's durable steer-record notifications back to this test.
      {:ok, _} =
        Registry.register(Raxol.AgentClientProtocol.SessionRegistry, {:steer_sink, sid}, nil)

      _reply_ref = begin(session)

      # Accept → durable steer record via the emitter seam.
      assert {:ok, {:accepted, ref}} =
               Session.steer(session, %{text: "go left", expected_turn_id: 1, client_msg_id: "j"})

      assert_receive {:steer_journaled, journaled_ref, request}, 1_000
      assert journaled_ref == ref
      assert request.text == "go left"
      assert request.client_msg_id == "j"

      # Duplicate → NOT journaled again.
      assert {:ok, {:duplicate, ^ref}} =
               Session.steer(session, %{text: "go left", expected_turn_id: 1, client_msg_id: "j"})

      refute_receive {:steer_journaled, _, _}, 200

      # Stale reject → NOT journaled.
      assert {:error, {:stale_turn, _, _}} =
               Session.steer(session, %{text: "x", expected_turn_id: 999, client_msg_id: "j2"})

      refute_receive {:steer_journaled, _, _}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # The default adapter refuses (base v2 byte-identical behaviour)
  # ---------------------------------------------------------------------------

  describe "default (unsupported) adapter" do
    test "a Session with no injected adapter refuses every steer honestly", ctx do
      conn = new_conn()

      {session, _sid} =
        start_session(ctx, conn,
          turn_runner: live_runner(self()),
          steer_adapter: Session.SteerAdapter.Unsupported,
          steer_state: nil
        )

      _reply_ref = begin(session)

      assert Session.steer(session, %{text: "x", expected_turn_id: 1, client_msg_id: "m"}) ==
               {:error, :no_steer_channel}
    end
  end

  # ---------------------------------------------------------------------------
  # Wire round-trip: MethodTable decode → response encode/decode
  # ---------------------------------------------------------------------------

  describe "wire round-trip" do
    test "Router decodes _raxol/session.steer to the raxol_steer_session callback + SteerRequest" do
      params = %{
        "sessionId" => "s1",
        "text" => "go left",
        "expectedTurnId" => 1,
        "clientMsgId" => "m1"
      }

      assert {:ok, {:raxol_steer_session, %SteerRequest{} = req}} =
               Router.decode(:agent, :request, "_raxol/session.steer", params)

      assert req.session_id == "s1"
      assert req.text == "go left"
      assert req.expected_turn_id == 1
      assert req.client_msg_id == "m1"
    end

    test "SteerRequest rejects a missing expected_turn_id (loud, total)" do
      assert {:error, {:invalid_steer_request, _}} =
               SteerRequest.from_json(%{"sessionId" => "s1", "text" => "hi"})
    end

    test "SteerRequest with nil text round-trips (to_json is its own inverse)" do
      # `text` is optional (type/new/to_json all allow nil); a text-less
      # steer the module serializes itself must decode back, not be rejected
      # as malformed.
      req = SteerRequest.new("s1", nil, 7, "m1")

      assert {:ok, decoded} = SteerRequest.from_json(SteerRequest.to_json(req))
      assert decoded == req
      assert decoded.text == nil
    end

    test "SteerRequest with absent text key decodes to nil text" do
      assert {:ok, req} =
               SteerRequest.from_json(%{"sessionId" => "s1", "expectedTurnId" => 2})

      assert req.text == nil
    end

    test "SteerRequest with a non-string text is still rejected" do
      assert {:error, {:invalid_steer_request, _}} =
               SteerRequest.from_json(%{
                 "sessionId" => "s1",
                 "text" => 123,
                 "expectedTurnId" => 2
               })
    end

    test "result_marker points a pending _raxol/session.steer response at SteerResponse" do
      assert Router.result_marker("_raxol/session.steer") == {:decode, SteerResponse}
    end

    test "every CAS outcome round-trips through SteerResponse JSON encode/decode" do
      ref = %{turn_id: 1, offset: 3, client_msg_id: "m1"}

      outcomes = [
        {:ok, {:accepted, ref}},
        {:ok, {:duplicate, ref}},
        {:error, {:stale_turn, 1, 2}},
        {:error, :no_live_turn},
        {:error, :client_msg_id_reuse},
        {:error, :no_steer_channel}
      ]

      for outcome <- outcomes do
        json = outcome |> SteerResponse.new() |> SteerResponse.to_json()
        # Survives a real JSON encode/decode (the wire), then decodes back.
        wire = json |> Jason.encode!() |> Jason.decode!()
        assert {:ok, decoded} = SteerResponse.from_json(wire)
        assert SteerResponse.result(decoded) == outcome
      end
    end

    # Regression: the round-trip test above only ever feeds `encode_result/1`
    # integer tokens. `Raxol.Agent.Steer.swap/1` (raxol_agent) issues a CAS
    # token that is a TUPLE (`{:steered, cur, System.unique_integer(...)}`) as
    # the new `turn_id` after every accept, and that value has nowhere
    # legitimate to go (an accept's `ref` only ever carries the PRE-swap
    # token) -- so the very next steer against the same live turn ordinarily
    # resolves `{:error, {:stale_turn, _, actual}}` with `actual` bound to
    # that tuple. Before the fix, handing this straight to `Jason.encode!`
    # (via the struct's `Jason.Encoder` impl) raised `Protocol.UndefinedError`
    # -- tuples have no JSON representation -- crashing the Connection reply
    # for an everyday interaction, not a hostile input.
    test "a stale outcome's actual token being a raw CAS-swap tuple still encodes (no Jason.encode! crash)" do
      actual = {:steered, 1, System.unique_integer([:positive])}
      outcome = {:error, {:stale_turn, 1, actual}}

      json = outcome |> SteerResponse.new() |> SteerResponse.to_json()

      assert json["outcome"] == "stale"
      assert json["expectedTurnId"] == 1
      # The tuple is stringified, never handed to Jason raw.
      assert is_binary(json["actualTurnId"])

      # Must not raise -- this is the crux of the regression.
      wire = json |> Jason.encode!() |> Jason.decode!()

      assert {:ok, decoded} = SteerResponse.from_json(wire)
      assert {:error, {:stale_turn, 1, decoded_actual}} = SteerResponse.result(decoded)
      assert is_binary(decoded_actual)
    end

    test "steer-then-stale over a real turn: the second steer's actual token is a swapped CAS tuple, and the reply still encodes",
         ctx do
      conn = new_conn()
      {session, _sid} = start_session(ctx, conn, turn_runner: live_runner(self()))
      _reply_ref = begin(session)

      # First steer: accepted. The `Adapter` double (mirrors
      # `Raxol.Agent.Steer.resolve/2` byte-for-byte) swaps `turn_id` forward to
      # a tuple as part of the accept.
      assert {:ok, {:accepted, _ref}} =
               Session.steer(session, %{
                 text: "go left",
                 expected_turn_id: 1,
                 client_msg_id: "m1"
               })

      assert_receive {:runner_saw_steer, "go left"}, 1_000

      # Second steer in the SAME live turn: the client was never handed the
      # swapped token (the accept's ref only ever carries the pre-swap value),
      # so this ordinary follow-up steer loses the CAS -- `actual` is now the
      # swapped tuple, not the original integer turn_id.
      assert {:error, {:stale_turn, 1, actual}} =
               Session.steer(session, %{
                 text: "too late",
                 expected_turn_id: 1,
                 client_msg_id: "m2"
               })

      assert {:steered, 1, _} = actual

      # The MAJOR landmine, end to end: encoding this everyday rejection for
      # the wire must not raise `Protocol.UndefinedError`.
      json =
        {:error, {:stale_turn, 1, actual}}
        |> SteerResponse.new()
        |> SteerResponse.to_json()

      assert json["outcome"] == "stale"
      assert is_binary(json["actualTurnId"])
      assert %{} = json |> Jason.encode!() |> Jason.decode!()
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline)
    end
  end
end
