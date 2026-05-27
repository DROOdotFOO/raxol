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

      # At 100x speed, 5s delay becomes 50ms. If the multiplier were ignored,
      # this would take ~5s. Threshold leaves headroom for slow CI runners
      # (macOS GitHub runners can add ~1s of ExUnit/JIT overhead).
      {time_us, :ok} =
        :timer.tc(fn -> Player.play(session, [speed: 100.0] ++ @play_opts) end)

      assert time_us < 2_500_000
    end
  end
end
