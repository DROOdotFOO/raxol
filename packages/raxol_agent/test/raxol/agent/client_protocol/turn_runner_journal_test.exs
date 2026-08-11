defmodule Raxol.Agent.ClientProtocol.TurnRunnerJournalTest do
  @moduledoc """
  The durable record `session/load` will replay.

  Claims pinned here:

    1. A turn writes `turn_started`, one `session_update` per delivered
       notification, and a terminal record, all under `family: "acp"`.
    2. **Two turns on one session both survive.** This is the claim worth
       having: the coding TUI shipped a latent defect where every turn after
       the first vanished from the transcript, and no multi-turn test existed
       to catch it. A single-turn test passes either way.
    3. Stored notifications round-trip through `SessionNotification.from_json/1`,
       so a replay can re-send the frames rather than reconstruct them.
    4. A cancelled turn is recorded as cancelled.
    5. Journaling never decides whether a turn can answer: disabled, or
       pointed at an id that cannot be a directory, the turn still completes.
  """

  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.TurnRunner
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Session

  defmodule FakeConn do
    @moduledoc false
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
    @moduledoc false
    def stream(_messages, opts) do
      chunks = Keyword.fetch!(opts, :chunks)

      events =
        Enum.map(chunks, &{:chunk, &1}) ++
          [{:done, %{content: Enum.join(chunks), usage: %{}}}]

      {:ok, events}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule HistoryBackend do
    @moduledoc "Reports the messages it was handed, then replies `ok`."
    def stream(messages, opts) do
      send(Keyword.fetch!(opts, :owner), {:backend_saw, messages})
      {:ok, [{:chunk, "ok"}, {:done, %{content: "ok", usage: %{}}}]}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule HungBackend do
    @moduledoc false
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
              :finish -> {[{:done, %{content: "", usage: %{}}}], acc}
            end
          end,
          fn _acc -> :ok end
        )

      {:ok, stream}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  # -- helpers ------------------------------------------------------------------

  defp start_session!(runner, session_id) do
    # Unique id: a test that opens two sessions starts two Task.Supervisors,
    # and the default spec id collides on the second.
    task_sup =
      start_supervised!({Task.Supervisor, []},
        id: {:task_sup, System.unique_integer([:positive])}
      )

    session =
      start_supervised!(
        {Session,
         [
           session_id: session_id,
           conn: self(),
           conn_mod: FakeConn,
           task_sup: task_sup,
           turn_runner: runner,
           name: :"trj_session_#{System.unique_integer([:positive])}"
         ]},
        restart: :temporary,
        id: {:session, System.unique_integer([:positive])}
      )

    session
  end

  defp begin_prompt!(session, session_id, text) do
    reply_ref = make_ref()
    req = PromptRequest.new(session_id, [ContentBlock.from_string(text)])
    assert :ok = Session.begin_prompt(session, req, reply_ref, 1)
    reply_ref
  end

  defp records!(session_id, dir) do
    assert {:ok, records} = FileStore.read_records(session_id, base_dir: dir)
    records
  end

  defp types(records), do: Enum.map(records, & &1["type"])

  defp of_type(records, type), do: Enum.filter(records, &(&1["type"] == type))

  # -- 1 + 2 + 3: the record, across two turns ----------------------------------

  @tag :tmp_dir
  test "both turns on one session are recorded, with round-trippable notifications",
       %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: ChunkedBackend,
        backend_opts: [chunks: ["alpha", "beta"]],
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-journal-#{System.unique_integer([:positive])}"
    session = start_session!(runner, session_id)

    ref1 = begin_prompt!(session, session_id, "one")
    assert_receive {:conn_reply, ^ref1, {:ok, %{stop_reason: :end_turn}}}, 2_000

    ref2 = begin_prompt!(session, session_id, "two")
    assert_receive {:conn_reply, ^ref2, {:ok, %{stop_reason: :end_turn}}}, 2_000

    records = records!(session_id, dir)

    # Every record is ACP-shaped and belongs to this session.
    assert Enum.all?(records, &(&1["family"] == "acp"))
    assert Enum.all?(records, &(&1["session_id"] == session_id))

    # THE claim: two turns, two distinct turn ids, neither swallowed.
    turn_ids = records |> Enum.map(& &1["turn_id"]) |> Enum.uniq()
    assert length(turn_ids) == 2

    assert length(of_type(records, "turn_started")) == 2
    assert length(of_type(records, "turn_completed")) == 2

    # Each turn carries its own chunk updates, in order.
    for turn_id <- turn_ids do
      turn = Enum.filter(records, &(&1["turn_id"] == turn_id))

      assert ["turn_started" | rest] = types(turn)
      assert List.last(rest) == "turn_completed"

      texts =
        turn
        |> of_type("session_update")
        |> Enum.map(fn record ->
          assert {:ok, %SessionNotification{} = notif} =
                   SessionNotification.from_json(record["payload"]["notification"])

          assert notif.session_id == session_id
          {:agent_message_chunk, %{content: {:text, %{text: text}}}} = notif.update
          text
        end)

      assert texts == ["alpha", "beta"]
    end
  end

  # -- conversation history ---------------------------------------------------

  @tag :tmp_dir
  test "a second turn carries the first turn's exchange", %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: HistoryBackend,
        backend_opts: [owner: self()],
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-history-#{System.unique_integer([:positive])}"
    session = start_session!(runner, session_id)

    ref1 = begin_prompt!(session, session_id, "first")
    assert_receive {:backend_saw, first_seen}, 2_000
    assert_receive {:conn_reply, ^ref1, {:ok, %{stop_reason: :end_turn}}}, 2_000

    assert first_seen == [%{role: :user, content: "first"}]

    ref2 = begin_prompt!(session, session_id, "second")
    assert_receive {:backend_saw, second_seen}, 2_000
    assert_receive {:conn_reply, ^ref2, {:ok, %{stop_reason: :end_turn}}}, 2_000

    assert second_seen == [
             %{role: :user, content: "first"},
             %{role: :assistant, content: "ok"},
             %{role: :user, content: "second"}
           ]
  end

  # An append-only journal that snapshots the whole conversation every turn
  # grows with the SQUARE of the turn count. Each record is this turn's
  # contribution, and the history is their concatenation.
  @tag :tmp_dir
  test "each turn records its contribution, not the whole conversation", %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: HistoryBackend,
        backend_opts: [owner: self()],
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-delta-#{System.unique_integer([:positive])}"
    session = start_session!(runner, session_id)

    for n <- 1..3 do
      ref = begin_prompt!(session, session_id, "turn #{n}")
      assert_receive {:backend_saw, seen}, 2_000
      assert_receive {:conn_reply, ^ref, {:ok, %{stop_reason: :end_turn}}}, 2_000
      # History still accumulates: 1, 3, 5 messages as the turns pile up.
      assert length(seen) == 2 * (n - 1) + 1
    end

    sizes =
      session_id
      |> records!(dir)
      |> of_type("turn_completed")
      |> Enum.map(&length(get_in(&1, ["payload", "messages"])))

    assert sizes == [2, 2, 2]
  end

  # Two sessions must not read each other's history, which is the failure mode
  # a single shared store would have.
  @tag :tmp_dir
  test "history is per session", %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: HistoryBackend,
        backend_opts: [owner: self()],
        journal_opts: [base_dir: dir]
      )

    a = "sess-hist-a-#{System.unique_integer([:positive])}"
    b = "sess-hist-b-#{System.unique_integer([:positive])}"

    session_a = start_session!(runner, a)
    ref_a = begin_prompt!(session_a, a, "mine")
    assert_receive {:backend_saw, _}, 2_000
    assert_receive {:conn_reply, ^ref_a, {:ok, _}}, 2_000

    session_b = start_session!(runner, b)
    ref_b = begin_prompt!(session_b, b, "theirs")
    assert_receive {:backend_saw, b_seen}, 2_000
    assert_receive {:conn_reply, ^ref_b, {:ok, _}}, 2_000

    assert b_seen == [%{role: :user, content: "theirs"}]
  end

  # A turn with no reply is not an exchange. Carrying the user half alone
  # would put two user messages side by side and assert something the
  # assistant never said.
  @tag :tmp_dir
  test "a cancelled turn contributes no history", %{tmp_dir: dir} do
    hung =
      TurnRunner.new(
        backend: HungBackend,
        backend_opts: [owner: self()],
        interrupt: fn tool_ref, _sink, _opts ->
          {:ok,
           %{
             turn_id: tool_ref.turn_id,
             stages: [:interrupt_signaled],
             reason: :acp_cancel,
             os_pid: nil,
             killed?: false,
             confirmed_dead?: false
           }}
        end,
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-hist-cancel-#{System.unique_integer([:positive])}"
    session = start_session!(hung, session_id)

    ref = begin_prompt!(session, session_id, "abandoned")
    assert_receive {:backend_up, _pid}, 2_000
    GenServer.cast(session, {:acp_session_cancel, 2})
    assert_receive {:conn_reply, ^ref, {:ok, %{stop_reason: :cancelled}}}, 5_000

    # A fresh runner over the SAME session id, so the next turn reads the
    # journal the cancelled turn left behind.
    resumed =
      TurnRunner.new(
        backend: HistoryBackend,
        backend_opts: [owner: self()],
        journal_opts: [base_dir: dir]
      )

    session2 = start_session!(resumed, session_id)
    ref2 = begin_prompt!(session2, session_id, "next")
    assert_receive {:backend_saw, seen}, 2_000
    assert_receive {:conn_reply, ^ref2, {:ok, _}}, 2_000

    assert seen == [%{role: :user, content: "next"}]
  end

  # -- 4: cancellation --------------------------------------------------------

  @tag :tmp_dir
  test "a cancelled turn is recorded as cancelled", %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: HungBackend,
        backend_opts: [owner: self()],
        interrupt: fn tool_ref, _sink, _opts ->
          {:ok,
           %{
             turn_id: tool_ref.turn_id,
             stages: [:interrupt_signaled],
             reason: :acp_cancel,
             os_pid: nil,
             killed?: false,
             confirmed_dead?: false
           }}
        end,
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-journal-cancel-#{System.unique_integer([:positive])}"
    session = start_session!(runner, session_id)
    ref = begin_prompt!(session, session_id, "hang")

    assert_receive {:backend_up, _pid}, 2_000
    GenServer.cast(session, {:acp_session_cancel, 2})
    assert_receive {:conn_reply, ^ref, {:ok, %{stop_reason: :cancelled}}}, 5_000

    records = records!(session_id, dir)

    assert "turn_started" in types(records)
    assert "turn_cancelled" in types(records)
    refute "turn_completed" in types(records)
  end

  # -- 5: journaling never gates the turn -------------------------------------

  @tag :tmp_dir
  test "journal: false writes nothing and still answers", %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: ChunkedBackend,
        backend_opts: [chunks: ["only"]],
        journal: false,
        journal_opts: [base_dir: dir]
      )

    session_id = "sess-journal-off-#{System.unique_integer([:positive])}"
    session = start_session!(runner, session_id)
    ref = begin_prompt!(session, session_id, "hi")

    assert_receive {:conn_reply, ^ref, {:ok, %{stop_reason: :end_turn}}}, 2_000
    assert records!(session_id, dir) == []
  end

  # A session id that could never be a directory name must cost the turn
  # nothing. `FileStore.session_dir/2` joins without sanitizing, so the guard
  # has to be in front of the open, not inside it.
  @tag :tmp_dir
  test "an unusable session id skips the journal rather than failing the turn",
       %{tmp_dir: dir} do
    runner =
      TurnRunner.new(
        backend: ChunkedBackend,
        backend_opts: [chunks: ["only"]],
        journal_opts: [base_dir: dir]
      )

    session_id = "../escape"
    session = start_session!(runner, session_id)
    ref = begin_prompt!(session, session_id, "hi")

    assert_receive {:conn_reply, ^ref, {:ok, %{stop_reason: :end_turn}}}, 2_000
    assert File.ls!(dir) == []
  end
end
