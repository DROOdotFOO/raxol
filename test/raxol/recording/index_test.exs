defmodule Raxol.Recording.IndexTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Raxol.Recording.{Index, Player, Session}
  alias Raxol.Test.CrossTerminal.AnsiReplayer

  doctest Index

  @width 20
  @height 5

  # Small screens and few events on purpose: every assertion here drives the
  # real emulator, which is the expensive part of a replay.
  defp session(events) do
    %Session{
      width: @width,
      height: @height,
      started_at: DateTime.utc_now(),
      env: %{},
      events: events
    }
  end

  defp output_session do
    session([
      {0, :output, "\e[1;1Hone"},
      {1_000_000, :output, "\e[2;1H\e[31mtwo\e[0m"},
      {1_000_000, :input, "x"},
      {2_500_000, :output, "\e[3;1Hthree"},
      {4_000_000, :output, "\e[4;1Hfour"},
      {5_500_000, :input, "\r"},
      {6_000_000, :output, "\e[5;1Hfive"}
    ])
  end

  # Reference implementation: the O(n) prefix replay the index replaces, built
  # on the same emulator path the index uses.
  defp prefix_replay(session, us) do
    session.events
    |> Enum.flat_map(fn
      {event_us, :output, data} when event_us < us -> [data]
      _other -> []
    end)
    |> AnsiReplayer.replay_chunks(width: session.width, height: session.height)
    |> Index.snapshot()
  end

  describe "buffer_at/3" do
    test "agrees with a full prefix replay at arbitrary times" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)

      for us <- [0, 1, 999_999, 1_000_000, 2_600_000, 4_000_001, 6_000_000] do
        assert Index.buffer_at(index, session, us) ==
                 prefix_replay(session, us),
               "buffer_at/3 diverged from a prefix replay at #{us}us"
      end
    end

    test "a time past the end of the recording returns the final screen" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)

      assert Index.buffer_at(index, session, 60_000_000) ==
               prefix_replay(session, 60_000_000)
    end

    test "a session with no output events stays blank" do
      session = session([{0, :input, "a"}, {900_000, :input, "b"}])
      index = Index.build(session)

      blank = Raxol.Core.Buffer.create_blank_buffer(@width, @height)

      assert Index.buffer_at(index, session, 0) == blank
      assert Index.buffer_at(index, session, 5_000_000) == blank
    end

    test "an empty session stays blank" do
      session = session([])
      index = Index.build(session)

      assert Index.buffer_at(index, session, 0) ==
               Raxol.Core.Buffer.create_blank_buffer(@width, @height)
    end
  end

  describe "keyframe_before/2" do
    test "us: 0 always resolves to the blank starting screen" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)

      keyframe = Index.keyframe_before(index, 0)

      assert keyframe.us == 0
      assert keyframe.event_index == 0

      assert keyframe.buffer ==
               Raxol.Core.Buffer.create_blank_buffer(@width, @height)
    end

    test "mid-stream resolves to the nearest keyframe at or before the time" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)

      keyframe_times = Enum.map(index.keyframes, & &1.us)
      assert keyframe_times == [0, 2_500_000, 6_000_000]

      assert Index.keyframe_before(index, 2_499_999).us == 0
      assert Index.keyframe_before(index, 2_500_000).us == 2_500_000
      assert Index.keyframe_before(index, 5_999_999).us == 2_500_000
    end

    test "past the end resolves to the last keyframe" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)

      assert Index.keyframe_before(index, 60_000_000).us == 6_000_000
    end

    test "an empty session still resolves" do
      index = Index.build(session([]))

      assert Index.keyframe_before(index, 0).us == 0
      assert Index.keyframe_before(index, 99_000_000).us == 0
    end
  end

  describe "marks" do
    test "are exactly the elapsed times of the input events" do
      index = Index.build(output_session(), interval_us: 2_000_000)

      assert index.marks == [1_000_000, 5_500_000]
    end

    test "are empty when nobody typed" do
      index = Index.build(session([{0, :output, "hi"}]))

      assert index.marks == []
    end
  end

  describe "Player seeking" do
    test "an indexed seek shows what a prefix replay shows" do
      session = output_session()
      index = Index.build(session, interval_us: 2_000_000)
      target = 4_500_000

      {plain_state, plain_bytes} = with_io(fn -> seek(session, nil, target) end)

      {indexed_state, indexed_bytes} =
        with_io(fn -> seek(session, index, target) end)

      assert screen(plain_bytes) == screen(indexed_bytes)
      assert cursor(plain_bytes) == cursor(indexed_bytes)
      assert plain_state.index == indexed_state.index
    end

    test "seeking without an index replays the prefix" do
      session = output_session()

      {_state, bytes} = with_io(fn -> seek(session, nil, 2_600_000) end)

      # The recorded bytes themselves, not a repaint: that is the fallback the
      # frozen invariant protects.
      assert bytes ==
               "\e[2J\e[H\e[1;1Hone\e[2;1H\e[31mtwo\e[0m\e[3;1Hthree"
    end
  end

  defp seek(session, index, target_us) do
    Player.jump_to_us(
      %{
        events: session.events,
        event_count: length(session.events),
        index: 0,
        total_us: 6_000_000,
        session: session,
        keyframe_index: index
      },
      target_us
    )
  end

  defp screen(bytes) do
    bytes
    |> AnsiReplayer.replay(width: @width, height: @height)
    |> Index.snapshot()
  end

  defp cursor(bytes) do
    bytes
    |> AnsiReplayer.replay(width: @width, height: @height)
    |> AnsiReplayer.cursor()
  end
end
