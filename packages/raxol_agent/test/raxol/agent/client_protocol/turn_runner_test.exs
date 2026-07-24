defmodule Raxol.Agent.ClientProtocol.TurnRunnerTest do
  @moduledoc """
  Red suite for `Raxol.Agent.ClientProtocol.TurnRunner` — the production
  `:turn_runner` for `Raxol.AgentClientProtocol.Session`, wrapping the real
  streaming stack (`Raxol.Agent.Stream`) and composing cancellation with
  `Raxol.Agent.Interrupt` (the OS-pgroup staged kill).

  Every test drives the runner through the REAL ACP `Session` GenServer (the
  turn state machine: begin_prompt → root task → drain gate → exactly-one
  reply), with a test-local `FakeConn` standing in for the Connection seam,
  exactly like the ACP package's own suite does.

  ## Claims pinned here

    1. **Happy path** — a mock backend streaming N chunks lands N
       `agent_message_chunk` updates in order, then exactly one
       `PromptResponse{stop_reason: :end_turn}` reply, updates strictly
       before the reply (Session I3).
    2. **Cancel mid-stream** — on `session/cancel` the chunks STOP, the
       injected Interrupt double is invoked (with a tool-less `tool_ref`
       carrying the runner's turn id), the streaming pump process is dead
       (no BEAM orphan), exactly one cancelled `PromptResponse` goes out,
       and NO update is emitted after the interrupt (post-kill quiescence).
    3. **Hung backend** — a backend that never yields a chunk still cancels
       promptly: Interrupt fires well before the Session's 30s
       `Process.exit(:kill)` backstop (which must never be the kill
       mechanism for tool processes).
    4. **Kill-complete fence** — when a tool call was announced on the turn,
       the cancel path emits the fence as a final `tool_call_update`
       (status `:failed`) whose notification `_meta` carries the
       `"raxol.dev/interrupt"` rider built from the Interrupt outcome, and
       that fence precedes the cancelled reply on the Session's FIFO lane.
  """

  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.TurnRunner
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Session

  # -- test doubles -----------------------------------------------------------

  defmodule FakeConn do
    @moduledoc "Connection seam double: forwards every IC call to the conn pid (the test)."
    def delegate_reply(conn, reply_ref, adopter) do
      send(conn, {:conn_delegated, reply_ref, adopter})
      :ok
    end

    def reply(conn, reply_ref, rendered) do
      send(conn, {:conn_reply, reply_ref, rendered})
      :ok
    end

    def notify(conn, method, notification) do
      send(conn, {:conn_notify, method, notification})
      :ok
    end

    def async_request(_conn, _method, _req, _owner, _tag, _timeout), do: :ok
    def cancel_request(_conn, _tag), do: :ok
  end

  defmodule ChunkedBackend do
    @moduledoc "Streams the configured chunks, then done. The happy-path backend."
    def stream(_messages, opts) do
      chunks = Keyword.fetch!(opts, :chunks)

      events =
        Enum.map(chunks, &{:chunk, &1}) ++
          [{:done, %{content: Enum.join(chunks), usage: %{}}}]

      {:ok, events}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule CapturingBackend do
    @moduledoc "Reports the exact messages it was handed, then streams one chunk."
    def stream(messages, opts) do
      send(Keyword.fetch!(opts, :owner), {:backend_saw, messages})
      {:ok, [{:chunk, "ok"}, {:done, %{content: "ok", usage: %{}}}]}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule GatedBackend do
    @moduledoc """
    A backend whose stream is driven by test messages: each pull blocks in a
    `receive` until the test sends `{:chunk, text}` / `:finish` — so with no
    message it models a HUNG backend. Announces the streaming (pump) process
    to the test via `{:backend_up, pid}` so orphan checks can target it.
    """
    def stream(_messages, opts) do
      owner = Keyword.fetch!(opts, :owner)

      stream =
        Stream.resource(
          fn ->
            send(owner, {:backend_up, self()})
            :ok
          end,
          fn acc ->
            receive do
              {:chunk, text} -> {[{:chunk, text}], acc}
              :finish -> {[{:done, %{content: "", usage: %{}}}], acc}
            end
          end,
          fn _acc -> :ok end
        )

      {:ok, stream}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule EchoAction do
    @moduledoc "A fast, non-blocking tool that echoes its `v` argument back."
    use Raxol.Agent.Action,
      name: "echo",
      description: "echoes v",
      schema: [input: [v: [type: :integer, required: true]]]

    @impl true
    def run(%{v: v}, _context), do: {:ok, %{v: v}}
  end

  defmodule BlockingAction do
    @moduledoc "A tool that announces itself then blocks until killed."
    use Raxol.Agent.Action,
      name: "block_tool",
      description: "blocks forever (until killed)",
      schema: [input: []]

    @impl true
    def run(_params, context) do
      case Map.get(context, :owner) do
        pid when is_pid(pid) -> send(pid, {:tool_started, self()})
        _ -> :ok
      end

      receive do
        :release -> {:ok, %{}}
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp interrupt_double(test_pid, outcome_overrides \\ %{}) do
    fn tool_ref, sink, opts ->
      send(test_pid, {:interrupt_called, tool_ref, opts, System.monotonic_time(:millisecond)})

      # Behave like the real staged kill's bookkeeping: stages through the sink.
      :ok = sink.(:interrupt_signaled, %{})
      :ok = sink.(:turn_canceled, %{reason: Keyword.get(opts, :reason, :interrupted)})

      outcome =
        Map.merge(
          %{
            turn_id: tool_ref.turn_id,
            stages: [:interrupt_signaled],
            reason: Keyword.get(opts, :reason, :interrupted),
            os_pid: nil,
            killed?: false,
            confirmed_dead?: false
          },
          outcome_overrides
        )

      {:ok, outcome}
    end
  end

  defp start_session!(runner) do
    task_sup = start_supervised!(Task.Supervisor)
    session_id = "sess-#{System.unique_integer([:positive])}"

    session =
      start_supervised!(
        {Session,
         [
           session_id: session_id,
           conn: self(),
           conn_mod: FakeConn,
           task_sup: task_sup,
           turn_runner: runner,
           name: :"tr_session_#{System.unique_integer([:positive])}"
         ]},
        restart: :temporary
      )

    {session, session_id}
  end

  defp begin_prompt!(session, session_id, text \\ "hello") do
    reply_ref = make_ref()
    req = PromptRequest.new(session_id, [ContentBlock.from_string(text)])
    assert :ok = Session.begin_prompt(session, req, reply_ref, 1)
    reply_ref
  end

  defp cancel!(session), do: GenServer.cast(session, {:acp_session_cancel, 2})

  defp chunk_text(%{update: {:agent_message_chunk, %{content: {:text, %{text: text}}}}}),
    do: text

  # -- 1. happy path ------------------------------------------------------------

  test "streams N chunks as agent_message_chunk updates, then exactly one end_turn response" do
    runner =
      TurnRunner.new(
        backend: ChunkedBackend,
        backend_opts: [chunks: ["alpha", "beta", "gamma"]]
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:conn_notify, "session/update", n1}, 2_000
    assert_receive {:conn_notify, "session/update", n2}, 2_000
    assert_receive {:conn_notify, "session/update", n3}, 2_000
    assert Enum.map([n1, n2, n3], &chunk_text/1) == ["alpha", "beta", "gamma"]
    assert Enum.all?([n1, n2, n3], &(&1.session_id == session_id))

    # Updates strictly before the reply (I3): the reply lands only now.
    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :end_turn}}}, 2_000

    # Exactly one reply, no straggler updates.
    refute_receive {:conn_reply, _, _}, 100
    refute_receive {:conn_notify, _, _}, 10
  end

  # -- 1b. system prompt threading ----------------------------------------------

  test "a system_prompt source spec resolves at wiring time and reaches the backend" do
    runner =
      TurnRunner.new(
        backend: CapturingBackend,
        backend_opts: [owner: self()],
        system_prompt: {:text, "You are the bonded core."}
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id, "hi")

    assert_receive {:backend_saw, messages}, 2_000

    assert [
             %{role: :system, content: "You are the bonded core."},
             %{role: :user, content: "hi"}
           ] = messages

    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :end_turn}}}, 2_000
  end

  test "a literal binary system_prompt still passes through (back-compat)" do
    runner =
      TurnRunner.new(
        backend: CapturingBackend,
        backend_opts: [owner: self()],
        system_prompt: "literal prompt"
      )

    {session, session_id} = start_session!(runner)
    begin_prompt!(session, session_id, "hi")

    assert_receive {:backend_saw, messages}, 2_000
    assert [%{role: :system, content: "literal prompt"} | _] = messages
  end

  test "system_prompt: :none resolves to no system message at all" do
    runner =
      TurnRunner.new(
        backend: CapturingBackend,
        backend_opts: [owner: self()],
        system_prompt: :none
      )

    {session, session_id} = start_session!(runner)
    begin_prompt!(session, session_id, "hi")

    assert_receive {:backend_saw, messages}, 2_000
    assert [%{role: :user, content: "hi"}] = messages
  end

  test "an unresolvable system_prompt source fails at wiring time, never mid-turn" do
    assert_raise ArgumentError, ~r/system_prompt.*failed to resolve/s, fn ->
      TurnRunner.new(
        backend: CapturingBackend,
        system_prompt: {:file, "/nonexistent/prompt.md"}
      )
    end
  end

  # -- 2. cancel mid-stream -----------------------------------------------------

  test "cancel mid-stream: chunks stop, Interrupt invoked, one cancelled reply, no orphan" do
    runner =
      TurnRunner.new(
        backend: GatedBackend,
        backend_opts: [owner: self()],
        interrupt: interrupt_double(self())
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:backend_up, pump}, 2_000

    send(pump, {:chunk, "one"})
    assert_receive {:conn_notify, "session/update", notif}, 2_000
    assert chunk_text(notif) == "one"

    cancel!(session)

    # Interrupt is the cancel mechanism — invoked with the runner's turn id,
    # tool-less (no Port/os_pid on a mid-provider-stream interrupt).
    assert_receive {:interrupt_called, tool_ref, opts, _at}, 2_000
    assert is_binary(tool_ref.turn_id)
    assert tool_ref.os_pid == nil
    assert tool_ref.port == nil
    assert Keyword.get(opts, :reason) == :acp_cancel

    # Exactly one cancelled PromptResponse.
    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :cancelled}}}, 2_000
    refute_receive {:conn_reply, _, _}, 100

    # No orphaned streaming process: the pump is dead.
    refute Process.alive?(pump)

    # Post-kill quiescence: nothing further lands on the update lane, even if
    # the (dead) pump is poked again.
    send(pump, {:chunk, "two"})
    refute_receive {:conn_notify, _, _}, 150
  end

  # -- 3. hung backend ----------------------------------------------------------

  test "hung backend: Interrupt fires promptly, well before the 30s ACP backstop" do
    runner =
      TurnRunner.new(
        backend: GatedBackend,
        backend_opts: [owner: self()],
        interrupt: interrupt_double(self())
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:backend_up, pump}, 2_000
    # No chunk is ever sent: the backend hangs in its receive.

    cancelled_at = System.monotonic_time(:millisecond)
    cancel!(session)

    assert_receive {:interrupt_called, _tool_ref, _opts, interrupted_at}, 2_000
    # The whole point of the composition: the staged kill fires on cancel,
    # orders of magnitude before the Session's 30_000ms Process.exit backstop.
    assert interrupted_at - cancelled_at < 5_000

    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :cancelled}}}, 2_000
    refute_receive {:conn_reply, _, _}, 100
    refute Process.alive?(pump)
  end

  # -- 3b. interrupt-failure telemetry --------------------------------------------

  test "a failing interrupt still completes the cancel honestly, and fires a distinguishable telemetry event" do
    test_pid = self()
    handler_id = "turn-runner-interrupt-failed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :agent, :acp_turn_runner, :interrupt_failed],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry_interrupt_failed, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    runner =
      TurnRunner.new(
        backend: GatedBackend,
        backend_opts: [owner: self()],
        interrupt: fn _tool_ref, _sink, _opts -> {:error, :boom} end
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:backend_up, pump}, 2_000
    cancel!(session)

    assert_receive {:telemetry_interrupt_failed, %{stage: :error, detail: :boom}},
                   2_000

    # The failure is measurable, but the cancel sequence still completes:
    # exactly one cancelled reply, the pump still dead.
    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :cancelled}}}, 2_000
    refute Process.alive?(pump)
  end

  # -- 4. kill-complete fence -----------------------------------------------------

  test "cancel mid-tool: fence tool_call_update with _meta rider precedes the cancelled reply" do
    killed_outcome = %{
      stages: [:interrupt_signaled, :interrupt_waited, :interrupt_killed],
      os_pid: 4242,
      killed?: true,
      confirmed_dead?: true
    }

    runner =
      TurnRunner.new(
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [
          tool_calls: [%{"name" => "block_tool", "arguments" => %{}, "id" => "tc-1"}]
        ],
        actions: [BlockingAction],
        context: %{owner: self()},
        interrupt: interrupt_double(self(), killed_outcome)
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    # The tool call is announced on the update stream, then the tool blocks.
    assert_receive {:conn_notify, "session/update",
                    %{update: {:tool_call, %{tool_call_id: "tc-1", status: :in_progress}}}},
                   2_000

    assert_receive {:tool_started, _tool_pid}, 2_000

    cancel!(session)
    assert_receive {:interrupt_called, _tool_ref, _opts, _at}, 2_000

    # The kill-complete fence: a final tool_call_update for the killed tool,
    # honest terminal status, the fence riding the notification _meta.
    assert_receive {:conn_notify, "session/update", fence_notif}, 2_000
    assert {:tool_call_update, tcu} = fence_notif.update
    assert tcu.tool_call_id == "tc-1"
    assert tcu.fields.status == :failed

    rider = fence_notif._meta[TurnRunner.fence_meta_key()]
    assert rider["fence"] == "interrupt_killed"
    assert rider["killed"] == true
    assert rider["confirmedDead"] == true
    assert rider["osPid"] == 4242
    assert is_binary(rider["turnId"])

    # Fence strictly before the (single) cancelled reply; nothing after it.
    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :cancelled}}}, 2_000
    refute_receive {:conn_reply, _, _}, 100
    refute_receive {:conn_notify, _, _}, 150
  end

  test "no kill stage in the outcome means NO fence update (never forge the fence)" do
    # The double reports only the cooperative signal — no kill landed, so the
    # runner must not claim one on the wire, even with a tool announced.
    runner =
      TurnRunner.new(
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [
          tool_calls: [%{"name" => "block_tool", "arguments" => %{}, "id" => "tc-2"}]
        ],
        actions: [BlockingAction],
        context: %{owner: self()},
        interrupt: interrupt_double(self())
      )

    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:conn_notify, "session/update", %{update: {:tool_call, _}}}, 2_000
    assert_receive {:tool_started, _}, 2_000

    cancel!(session)
    assert_receive {:interrupt_called, _, _, _}, 2_000

    # Straight to the cancelled reply: no tool_call_update fence in between.
    assert_receive {:conn_reply, ^reply_ref, {:ok, %{stop_reason: :cancelled}}}, 2_000
    refute_receive {:conn_notify, _, _}, 150
    refute_receive {:conn_reply, _, _}, 100
  end

  # -- 4b. tool id correlation (same-name parallel calls) ------------------------

  test "two in-flight tool_use calls sharing a name correlate their results by call order, not by name" do
    runner =
      TurnRunner.new(
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [
          tool_calls: [
            %{"name" => "echo", "arguments" => %{"v" => 1}, "id" => "tc-a"},
            %{"name" => "echo", "arguments" => %{"v" => 2}, "id" => "tc-b"}
          ]
        ],
        actions: [EchoAction],
        # Bounds the ReAct loop to exactly one tool-turn: the mock backend
        # replays the SAME static tool_calls every round, so without this the
        # runner would loop announcing "tc-a"/"tc-b" again indefinitely.
        max_iterations: 1
      )

    {session, session_id} = start_session!(runner)
    _reply_ref = begin_prompt!(session, session_id)

    # Both calls are announced (batch-style) BEFORE either is executed —
    # the exact window the prior name-keyed single slot corrupted.
    assert_receive {:conn_notify, "session/update",
                    %{update: {:tool_call, %{tool_call_id: "tc-a", status: :in_progress}}}},
                   2_000

    assert_receive {:conn_notify, "session/update",
                    %{update: {:tool_call, %{tool_call_id: "tc-b", status: :in_progress}}}},
                   2_000

    # Results are executed and emitted in the SAME order as their
    # announcements (`execute_tools/2`'s `Enum.map/2`): tc-a's result (v: 1)
    # must correlate back to "tc-a", tc-b's (v: 2) to "tc-b" — the prior
    # name-keyed `tool_ids[name] = id` slot pointed BOTH at whichever id
    # fired last ("tc-b"), corrupting tc-a's correlation.
    assert_receive {:conn_notify, "session/update", %{update: {:tool_call_update, tcu_a}}},
                   2_000

    assert tcu_a.tool_call_id == "tc-a"
    assert tcu_a.fields.status == :completed
    assert tcu_a.fields.raw_output == %{v: 1}

    assert_receive {:conn_notify, "session/update", %{update: {:tool_call_update, tcu_b}}},
                   2_000

    assert tcu_b.tool_call_id == "tc-b"
    assert tcu_b.fields.raw_output == %{v: 2}
  end

  # -- 5. stream error ------------------------------------------------------------

  test "a backend error event folds to the Session's internal-error prompt response" do
    defmodule ErrorBackend do
      def stream(_messages, _opts), do: {:ok, [{:error, :boom}]}
      def complete(_messages, _opts), do: {:error, :boom}
    end

    runner = TurnRunner.new(backend: ErrorBackend)
    {session, session_id} = start_session!(runner)
    reply_ref = begin_prompt!(session, session_id)

    assert_receive {:conn_reply, ^reply_ref, {:error, %{code: -32_603}}}, 2_000
    refute_receive {:conn_reply, _, _}, 100
  end
end
