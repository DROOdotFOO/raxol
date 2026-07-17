defmodule Raxol.Playground.HarnessStatusStripDemoTest do
  @moduledoc """
  The status strip's view-path behavior observed through the demo buffer
  (harness TEA migration §4/§7): phase vocabulary, the tick-driven spinner
  (advances on a scripted tick, never on wall time), the ALERT stall state,
  and the charged-minimum absence between turns.
  """
  use ExUnit.Case, async: false

  alias Raxol.Harness.StatusStrip, as: Core
  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessStatusStripDemo

  @settle_ms 150

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  defp start_demo do
    id = :"status_demo_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(HarnessStatusStripDemo, id: id, width: 60, height: 20)

    Process.sleep(@settle_ms)
    id
  end

  defp screenshot(id) do
    {:ok, t} = Headless.screenshot(id)
    t
  end

  # The strip's own line (the only line carrying the "thinking" phase word;
  # the scene label deliberately avoids the phase vocabulary).
  defp thinking_line(id) do
    screenshot(id) |> String.split("\n") |> Enum.find("", &(&1 =~ "thinking"))
  end

  defp spinner_glyph(id),
    do: thinking_line(id) |> String.graphemes() |> List.first()

  defp next_scene(id) do
    Headless.send_key(id, "n")
    Process.sleep(@settle_ms)
  end

  describe "phase vocabulary" do
    test "the opening scene is a live 'thinking' turn with a spinner" do
      id = start_demo()
      line = thinking_line(id)
      assert line =~ "thinking"
      assert spinner_glyph(id) == List.first(Core.spinner_glyphs())
    end

    test "cycling scenes renders each operator phase" do
      id = start_demo()

      next_scene(id)
      assert screenshot(id) =~ "running mix"

      next_scene(id)
      assert screenshot(id) =~ "responding"

      next_scene(id)
      assert screenshot(id) =~ "awaiting approval"

      next_scene(id)
      assert screenshot(id) =~ "ALERT: no progress for 90s"
    end
  end

  describe "the tick-driven braille spinner" do
    test "a scripted tick advances the frame; no tick leaves it put" do
      id = start_demo()
      [f0, f1, f2 | _] = Core.spinner_glyphs()

      assert spinner_glyph(id) == f0

      Headless.send_key(id, "t")
      Process.sleep(@settle_ms)
      assert spinner_glyph(id) == f1

      Headless.send_key(id, "t")
      Process.sleep(@settle_ms)
      assert spinner_glyph(id) == f2

      # Event-clocked: wall time with NO tick never advances the frame.
      Process.sleep(@settle_ms)
      assert spinner_glyph(id) == f2
    end
  end

  describe "charged-minimum absence" do
    test "the idle scene yields to silence (no phase void)" do
      id = start_demo()
      # thinking -> running -> responding -> approval -> alert -> idle
      Enum.each(1..5, fn _ -> next_scene(id) end)
      s = screenshot(id)

      refute s =~ "thinking"
      refute s =~ "running mix"
      refute s =~ "responding"
      refute s =~ "awaiting approval"
      refute s =~ "ALERT"
    end
  end
end
