defmodule Raxol.Playground.HarnessComposerDemoTest do
  @moduledoc """
  The cursor-park law (harness TEA migration §5 law 6) proven end-to-end
  through the pipeline: the Composer declares its edit point, the demo
  lowers it to the root `:cursor` key, and the buffer's `cursor_position` /
  `cursor_visible` (the F0-cursor assert surface, read via
  `Raxol.Headless.get_buffer/1`) land exactly where the next grapheme goes.
  Plus the placeholder and the submit / refuse notices (§7 pins).
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessComposerDemo

  @settle_ms 200

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
    id = :"composer_demo_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(HarnessComposerDemo, id: id, width: 60, height: 20)

    Process.sleep(@settle_ms)
    id
  end

  defp buffer(id) do
    {:ok, b} = Headless.get_buffer(id)
    b
  end

  defp screenshot(id) do
    {:ok, t} = Headless.screenshot(id)
    t
  end

  defp row(id, n), do: screenshot(id) |> String.split("\n") |> Enum.at(n)

  describe "cursor park at the buffer level (§5 law 6)" do
    test "the initial caret parks at the end of the seeded draft" do
      id = start_demo()
      buf = buffer(id)

      assert row(id, 0) == "hi there"
      # {x, y}: after the 8 cells of "hi there", on row 0
      assert buf.cursor_position == {8, 0}
      assert buf.cursor_visible == true
    end

    test "typing advances the parked column with the draft" do
      id = start_demo()
      :ok = Headless.send_key(id, "!")
      Process.sleep(@settle_ms)

      assert row(id, 0) == "hi there!"
      assert buffer(id).cursor_position == {9, 0}
    end

    test "a wide CJK grapheme advances the park by two cells (display-width honesty)" do
      id = start_demo()
      :ok = Headless.send_key(id, "中")
      Process.sleep(@settle_ms)

      assert row(id, 0) =~ "中"
      assert buffer(id).cursor_position == {10, 0}
    end

    test "backspace moves the park back with the draft" do
      id = start_demo()
      :ok = Headless.send_key(id, :backspace)
      Process.sleep(@settle_ms)

      assert row(id, 0) == "hi ther"
      assert buffer(id).cursor_position == {7, 0}
    end
  end

  describe "placeholder + submit/refuse notices (§7)" do
    test "the empty, unfocused composer shows its placeholder" do
      id = start_demo()
      assert screenshot(id) =~ "type a prompt"
    end

    test "Enter with content emits a submit notice (and clears the draft)" do
      id = start_demo()
      :ok = Headless.send_key(id, :enter)
      Process.sleep(@settle_ms)

      assert screenshot(id) =~ "submitted: hi there"
      # the caret returns home after the draft clears
      assert buffer(id).cursor_position == {0, 0}
    end

    test "Enter on an emptied draft emits a refuse notice (empty prompt)" do
      id = start_demo()
      for _ <- 1..8, do: Headless.send_key(id, :backspace)
      Process.sleep(@settle_ms)
      :ok = Headless.send_key(id, :enter)
      Process.sleep(@settle_ms)

      assert screenshot(id) =~ "refused: empty prompt"
    end
  end
end
