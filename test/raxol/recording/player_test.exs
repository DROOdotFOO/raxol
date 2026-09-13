defmodule Raxol.Recording.PlayerTest do
  use ExUnit.Case, async: true

  alias Raxol.Recording.{Player, Session}

  # Tests use non-interactive mode to avoid stty/raw terminal in CI
  @play_opts [interactive: false]

  describe "play/2" do
    test "plays empty session without error" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.utc_now(),
        events: []
      }

      assert :ok = Player.play(session, @play_opts)
    end

    test "plays session with events" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.utc_now(),
        events: [
          {0, :output, "hello"},
          {10_000, :output, " world"}
        ]
      }

      assert :ok = Player.play(session, [speed: 100.0] ++ @play_opts)
    end

    test "an :input event advances playback instead of crashing it" do
      # `input_marks/1` exists to tick the `:input` events on the scrub bar,
      # and `Asciicast.decode_event_type("i")` produces them, but `loop/1`
      # hard-matched `{_us, :output, _}` -- so a recording whose marks the
      # track advertised raised MatchError the moment playback reached one.
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.utc_now(),
        events: [
          {0, :output, "prompt$ "},
          {1_000, :input, "ls\r"},
          {2_000, :output, "file.txt"}
        ]
      }

      assert :ok = Player.play(session, [speed: 100.0] ++ @play_opts)
    end

    test "input_marks/1 indexes exactly the :input events" do
      events = [
        {0, :output, "a"},
        {1_000, :input, "x"},
        {2_000, :output, "b"},
        {3_000, :input, "y"}
      ]

      assert Player.input_marks(events) == [1, 3]
      assert Player.input_marks([{0, :output, "a"}]) == []
    end

    @tag :tmp_dir
    test "plays from .cast file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.cast")

      content = """
      {"version":2,"width":80,"height":24,"timestamp":1700000000}
      [0.0,"o","hello"]
      [0.01,"o"," world"]
      """

      File.write!(path, content)

      assert :ok = Player.play(path, [speed: 100.0] ++ @play_opts)
    end

    test "respects speed multiplier" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.utc_now(),
        events: [
          {0, :output, "a"},
          {5_000_000, :output, "b"}
        ]
      }

      assert :ok = Player.play(session, [speed: 100.0] ++ @play_opts)
    end
  end

  # The multiplier used to be checked by timing `play/2`: at 100x a 5s gap
  # becomes 50ms, so "ignored multiplier" showed up as a ~5s run and the test
  # asserted `elapsed < 2.5s`. That is a wall-clock ceiling standing in for
  # an arithmetic claim. `frame_delay_ms/3` is the arithmetic, so the claim
  # is now checked directly -- and it covers the interactive path too, which
  # the timed test never reached.
  describe "frame_delay_ms/3" do
    test "the speed multiplier divides the inter-event gap" do
      assert Player.frame_delay_ms(5_000_000, 1.0, 10.0) == 5_000
      assert Player.frame_delay_ms(5_000_000, 100.0, 10.0) == 50
      assert Player.frame_delay_ms(5_000_000, 0.5, 20.0) == 10_000
    end

    test "max_delay caps the wait, and a backwards gap never sleeps" do
      # A 5s gap at 1x, capped at 3s.
      assert Player.frame_delay_ms(5_000_000, 1.0, 3.0) == 3_000

      # Out-of-order timestamps must not produce a negative sleep.
      assert Player.frame_delay_ms(-1_000_000, 1.0, 5.0) == 0
    end
  end
end
