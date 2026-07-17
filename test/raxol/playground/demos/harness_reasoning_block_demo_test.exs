defmodule Raxol.Playground.Demos.HarnessReasoningBlockDemoTest do
  @moduledoc """
  Headless pins for `HarnessReasoningBlockDemo` -- the U1-a autotest
  contract for the re-hosted REASONING block (harness TEA migration §7):
  collapsed-by-default in both real registers (the component's `▸ N
  lines` peek line and the sealed transcript's `∴ reasoning · N lines`
  compact line), dim prominence buffer-verified, peek toggle on
  z/Enter/Space, blank-row rhythm.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

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

  defp start_demo(id) do
    {:ok, session} =
      Headless.start(Raxol.Playground.Demos.HarnessReasoningBlockDemo, id: id)

    Process.sleep(200)
    session
  end

  defp lines(session) do
    {:ok, text} = Headless.screenshot(session)
    String.split(text, "\n")
  end

  defp cell(session, x, y) do
    {:ok, buffer} = Headless.get_buffer(session)
    buffer.cells |> Enum.at(y) |> Enum.at(x)
  end

  defp press(session, key) do
    :ok = Headless.send_key(session, key)
    Process.sleep(120)
    session
  end

  defp occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end

  describe "collapsed default (both registers)" do
    test "component peek line and transcript ∴ line render collapsed; the body stays hidden" do
      session = start_demo(:r_collapsed)
      {:ok, text} = Headless.screenshot(session)

      assert text =~ "▸ 4 lines — Phase 1"
      assert text =~ "∴ reasoning · 4 lines"
      assert text =~ "expanded: false"

      refute text =~ "Phase 2",
             "collapsed means collapsed -- no body line may leak"

      Headless.stop(session)
    end

    test "reasoning content sits at the 2-cell indent; column 0 stays blank" do
      session = start_demo(:r_indent)
      rows = lines(session)

      peek_row = Enum.find(rows, &String.contains?(&1, "▸ 4 lines"))
      compact_row = Enum.find(rows, &String.contains?(&1, "∴ reasoning"))

      assert String.starts_with?(peek_row, "  ▸")
      assert String.starts_with?(compact_row, "  ∴")

      Headless.stop(session)
    end

    test "both registers render dim (faint), never bold -- buffer-verified prominence" do
      session = start_demo(:r_dim)
      rows = lines(session)

      peek_y = Enum.find_index(rows, &String.contains?(&1, "▸ 4 lines"))
      compact_y = Enum.find_index(rows, &String.contains?(&1, "∴ reasoning"))

      peek_cell = cell(session, 2, peek_y)
      compact_cell = cell(session, 2, compact_y)

      assert peek_cell.char == "▸"
      assert peek_cell.style.faint == true
      assert peek_cell.style.bold == false

      assert compact_cell.char == "∴"
      assert compact_cell.style.faint == true
      assert compact_cell.style.bold == false

      Headless.stop(session)
    end
  end

  describe "peek toggle (z / Enter / Space through the real app loop)" do
    test "z expands BOTH registers from the one model flag, and collapses back" do
      session = start_demo(:r_peek)

      press(session, "z")
      {:ok, expanded} = Headless.screenshot(session)

      assert expanded =~ "▾ 4 lines"
      assert expanded =~ "expanded: true"

      assert occurrences(expanded, "Phase 2 — hypothesis") == 2,
             "both registers (component body + Block body) must expand together"

      press(session, "z")
      {:ok, collapsed} = Headless.screenshot(session)

      assert collapsed =~ "▸ 4 lines — Phase 1"
      assert collapsed =~ "expanded: false"
      refute collapsed =~ "Phase 2"

      Headless.stop(session)
    end

    test "Enter expands, Space collapses (activation-key precedent)" do
      session = start_demo(:r_keys)

      press(session, :enter)
      {:ok, expanded} = Headless.screenshot(session)
      assert expanded =~ "expanded: true"

      press(session, :space)
      {:ok, collapsed} = Headless.screenshot(session)
      assert collapsed =~ "expanded: false"

      Headless.stop(session)
    end

    test "expanded body lines keep the 2-cell indent and dim prominence" do
      session = start_demo(:r_expanded_dim)
      press(session, "z")
      rows = lines(session)

      body_y =
        Enum.find_index(rows, &String.contains?(&1, "Phase 2 — hypothesis"))

      body_row = Enum.at(rows, body_y)

      assert String.starts_with?(body_row, "  Phase 2")

      body_cell = cell(session, 2, body_y)
      assert body_cell.style.faint == true

      Headless.stop(session)
    end
  end

  describe "blank-row rhythm" do
    test "one blank row between sections, none doubled" do
      session = start_demo(:r_rhythm)
      rows = lines(session)

      peek_y = Enum.find_index(rows, &String.contains?(&1, "▸ 4 lines"))
      assert Enum.at(rows, peek_y + 1) == ""

      assert Enum.at(rows, peek_y + 2) =~ "Sealed transcript register",
             "exactly ONE blank row separates the two registers"

      hint_y = Enum.find_index(rows, &String.contains?(&1, "expanded:"))

      rows
      |> Enum.slice(0..hint_y)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn pair ->
        refute pair == ["", ""], "doubled blank rows break the rhythm"
      end)

      Headless.stop(session)
    end
  end
end
