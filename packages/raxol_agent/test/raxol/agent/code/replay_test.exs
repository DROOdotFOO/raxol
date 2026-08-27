defmodule Raxol.Agent.Code.ReplayTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.Replay
  alias Raxol.Agent.Code.Store
  alias Raxol.Agent.Journal.FileStore

  # Time component: `unique_integer` restarts every BEAM run and these
  # dirs outlive the run, so reruns could collide with leftovers.
  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "raxol-replay-#{System.os_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"
    )
  end

  defp journal_event(turn_id, ts, type, payload) do
    %{
      v: 0,
      session_id: "seed",
      turn_id: turn_id,
      ts: ts,
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  defp message_turn(turn_id, prompt, answer) do
    [
      journal_event(turn_id, 1, :turn_started, %{"prompt" => prompt}),
      journal_event(turn_id, 2, :item_started, %{
        "item_id" => "i1",
        "item_type" => "message"
      }),
      journal_event(turn_id, 3, :item_completed, %{
        "item_id" => "i1",
        "item_type" => "message",
        "content" => answer
      }),
      journal_event(turn_id, 4, :turn_completed, %{"final" => true})
    ]
  end

  defp seed_journal(base, session_id, events) do
    {:ok, journal} = FileStore.open(session_id, base_dir: base)

    Enum.each(events, fn event ->
      {:ok, _offset} = FileStore.append(journal, event)
    end)

    :ok = FileStore.close(journal)
  end

  test "replays a journaled session as a text transcript" do
    base = tmp_dir()

    seed_journal(
      base,
      "sess-a",
      message_turn("t1", "say hi", "hello there") ++
        message_turn("t2", "again", "hello again")
    )

    {:ok, text} = Replay.run("sess-a", base_dir: base)

    assert text =~ "session sess-a · journal · 8 events"
    assert text =~ "> say hi"
    assert text =~ "hello there"
    assert text =~ "> again"
    assert text =~ "hello again"
  end

  test "to_offset replays a prefix by journal offset" do
    base = tmp_dir()

    seed_journal(
      base,
      "sess-b",
      message_turn("t1", "one", "first") ++ message_turn("t2", "two", "second")
    )

    {:ok, text} = Replay.run("sess-b", base_dir: base, to_offset: 4)

    assert text =~ "4 events"
    assert text =~ "first"
    refute text =~ "second"
  end

  test "falls back to the session store when no journal exists" do
    store = tmp_dir()

    stored =
      [
        {"t1", 1, "turn_started", %{"prompt" => "old prompt"}},
        {"t1", 2, "item_started", %{"item_id" => "i1", "item_type" => "message"}},
        {"t1", 3, "item_completed",
         %{
           "item_id" => "i1",
           "item_type" => "message",
           "content" => "old answer"
         }},
        {"t1", 4, "turn_completed", %{"final" => true}}
      ]
      |> Enum.map(fn {turn, id, type, payload} ->
        %{
          "id" => id,
          "turn_id" => turn,
          "ts" => id,
          "family" => "loop",
          "type" => type,
          "tier" => "durable",
          "payload" => payload
        }
      end)

    :ok = Store.save(store, "sess-old", %{messages: [], events: stored})

    {:ok, text} =
      Replay.run("sess-old", base_dir: tmp_dir(), store_dir: store)

    assert text =~ "· store ·"
    assert text =~ "> old prompt"
    assert text =~ "old answer"
  end

  test "a missing session errors" do
    assert {:error, message} =
             Replay.run("nope", base_dir: tmp_dir(), store_dir: tmp_dir())

    assert message =~ "not found"
  end

  test "an invalid session id errors without touching the disk" do
    assert {:error, message} = Replay.run("../escape", base_dir: tmp_dir())
    assert message =~ "invalid session id"
  end

  test "a rewind marker hides the dropped turn; an earlier offset bound does not" do
    base = tmp_dir()
    {:ok, journal} = FileStore.open("sess-rw", base_dir: base)

    events =
      message_turn("t1", "one", "first") ++ message_turn("t2", "two", "second")

    Enum.each(events, fn event ->
      {:ok, _offset} = FileStore.append(journal, event)
    end)

    marker = %{
      v: 0,
      session_id: "sess-rw",
      turn_id: nil,
      ts: 9,
      family: :meta,
      type: :rewind,
      tier: :durable,
      payload: %{"dropped_turn" => "t2"}
    }

    {:ok, 9} = FileStore.append(journal, marker)
    :ok = FileStore.close(journal)

    {:ok, text} = Replay.run("sess-rw", base_dir: base)
    assert text =~ "4 events"
    assert text =~ "first"
    refute text =~ "second"

    # Bounding below the marker's offset replays the pre-rewind state.
    {:ok, text} = Replay.run("sess-rw", base_dir: base, to_offset: 8)
    assert text =~ "second"
  end

  test "a rewind marker only drops the trailing run of a colliding turn id" do
    base = tmp_dir()
    {:ok, journal} = FileStore.open("sess-coll", base_dir: base)

    events =
      message_turn("turn-9", "old", "old answer") ++
        message_turn("t-mid", "mid", "mid answer") ++
        message_turn("turn-9", "new", "new answer")

    Enum.each(events, fn event ->
      {:ok, _offset} = FileStore.append(journal, event)
    end)

    marker = %{
      v: 0,
      session_id: "sess-coll",
      turn_id: nil,
      ts: 13,
      family: :meta,
      type: :rewind,
      tier: :durable,
      payload: %{"dropped_turn" => "turn-9"}
    }

    {:ok, _offset} = FileStore.append(journal, marker)
    :ok = FileStore.close(journal)

    {:ok, text} = Replay.run("sess-coll", base_dir: base)

    assert text =~ "old answer"
    assert text =~ "mid answer"
    refute text =~ "new answer"
  end

  test "a damaged journal errors instead of rendering partial state" do
    base = tmp_dir()
    seed_journal(base, "sess-d", message_turn("t1", "p", "a"))

    segment = Path.join([base, "sess-d", "journal", "000001.jsonl"])
    [first | rest] = segment |> File.read!() |> String.split("\n")
    # Corrupt an interior (terminated) record — the tolerant Reader only
    # self-heals a torn final line, never interior damage.
    File.write!(segment, Enum.join([first, "garbage" | tl(rest)], "\n"))

    assert {:error, message} = Replay.run("sess-d", base_dir: base)
    assert message =~ "damaged"
  end
end
