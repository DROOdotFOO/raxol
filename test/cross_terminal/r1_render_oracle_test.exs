defmodule Raxol.CrossTerminal.R1RenderOracleTest do
  @moduledoc """
  Spike for the R1 autonomous validation flow (proposal §11). Exercises the
  reference emit (`RenderOracle`) through the reference emulator and asserts the
  design's oracles — no golden bytes, no tty, no human.

  L0/L1 exercise the reference emit (`RenderOracle`); L2 drives the shipped
  production emit (`Backends.build_terminal_frame/4`) through the emulator for
  the recovery and sanitization invariants.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Test.CrossTerminal.RenderOracle, as: Oracle
  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.{Emulator, Renderer}
  alias Raxol.Terminal.Buffer.Queries

  # --- L0: deterministic oracle fixtures ---------------------------------

  describe "L0 fixtures" do
    test "oracle 4 — an unchanged frame emits nothing" do
      buf = Oracle.grid(6, 3, fn x, _y -> <<?a + x::utf8>> end)

      assert Oracle.changed_rows(buf, buf) == []
      assert Oracle.emit(buf, buf) == ""
    end

    test "oracle 4 — only changed rows are addressed" do
      prev = Oracle.grid(6, 3, fn _x, _y -> " " end)
      next = Oracle.build(6, 3, [{0, 1, "X"}])

      assert Oracle.changed_rows(prev, next) == [1]
      # exactly one CUP address, to row 2 (1-based)
      assert Oracle.emit(prev, next) =~ "\e[2;1H"
      refute Oracle.emit(prev, next) =~ "\e[1;1H"
      refute Oracle.emit(prev, next) =~ "\e[3;1H"
    end

    test "oracle 1 — keyframe round-trips to the buffer's own text" do
      buf =
        Oracle.build(10, 3, [
          {0, 0, "h"},
          {1, 0, "i"},
          {0, 2, "z"}
        ])

      assert Oracle.grid_full(buf) == Oracle.buffer_text(buf)
    end

    test "oracle 2 — a one-cell change lands the same grid as a fresh keyframe" do
      prev = Oracle.grid(8, 4, fn _x, _y -> " " end)
      next = Oracle.build(8, 4, [{3, 2, "Q"}])

      assert Oracle.grid_diff(prev, next) == Oracle.grid_full(next)
    end
  end

  # --- L1: generative property -------------------------------------------

  describe "L1 property" do
    # Small dims keep each check to microseconds; StreamData shrinks any
    # failure to a minimal grid pair.
    defp dims, do: {StreamData.integer(3..7), StreamData.integer(2..4)}

    defp safe_char, do: StreamData.member_of([" ", "a", "b", "c"])

    defp buffer_gen(w, h) do
      cells = StreamData.list_of(safe_char(), length: w * h)

      StreamData.map(cells, fn flat ->
        Oracle.grid(w, h, fn x, y -> Enum.at(flat, y * w + x) end)
      end)
    end

    property "oracle 2 — diff(prev,next) reaches the same grid as keyframe(next)" do
      {w_gen, h_gen} = dims()

      check all(
              w <- w_gen,
              h <- h_gen,
              prev <- buffer_gen(w, h),
              next <- buffer_gen(w, h),
              max_runs: 200
            ) do
        assert Oracle.grid_diff(prev, next) == Oracle.grid_full(next)
      end
    end

    property "oracle 1 — keyframe round-trips for any generated grid" do
      {w_gen, h_gen} = dims()

      check all(
              w <- w_gen,
              h <- h_gen,
              buf <- buffer_gen(w, h),
              max_runs: 200
            ) do
        assert Oracle.grid_full(buf) == Oracle.buffer_text(buf)
      end
    end
  end

  # --- L2: production emit -- recovery + sanitization --------------------
  #
  # Drives the shipped Backends.build_terminal_frame/4 (not the reference emit)
  # through one emulator threaded across steps, so resize, corruption recovery,
  # and C0 sanitization are asserted on the code that actually ships.

  describe "L2 production emit" do
    defp prod_frame(prev, next, force_repaint) do
      renderer = Renderer.new(next, %{}, %{}, true)

      Backends.build_terminal_frame(prev, next, renderer, %{
        force_repaint: force_repaint
      })
    end

    defp apply_to(emulator, bytes) do
      {emu, _} = Emulator.process_input(emulator, bytes)
      emu
    end

    defp emu_grid(emulator) do
      emulator |> Emulator.get_screen_buffer() |> Queries.get_text()
    end

    test "keyframe paints, corruption persists through a no-op diff, force_repaint recovers" do
      a = Oracle.build(6, 3, [{0, 0, "A"}, {2, 1, "B"}])
      emu = Emulator.new(6, 3)

      # keyframe paints model A
      emu = apply_to(emu, prod_frame(nil, a, true))
      assert emu_grid(emu) == Queries.get_text(a)

      # out-of-band corruption (a stray write the runtime didn't make)
      emu = apply_to(emu, "\e[1;1HXX")
      refute emu_grid(emu) == Queries.get_text(a)

      # a no-op diff (identical model) emits nothing, so corruption persists
      noop = prod_frame(a, a, false)
      assert noop == ""
      emu = apply_to(emu, noop)
      refute emu_grid(emu) == Queries.get_text(a)

      # force_repaint (Ctrl-L / resume) re-keyframes and restores model A
      emu = apply_to(emu, prod_frame(a, a, true))
      assert emu_grid(emu) == Queries.get_text(a)
    end

    test "resize forces a keyframe that repaints the whole new-size grid" do
      # engine's :update_size swaps in a fresh blank buffer of the new size and
      # sets force_repaint -- the next frame is an all-rows keyframe
      blank = Oracle.grid(6, 3, fn _x, _y -> " " end)
      next = Oracle.build(6, 3, [{0, 0, "R"}, {0, 2, "z"}])

      frame = prod_frame(blank, next, true)
      assert String.starts_with?(frame, "\e[2J")

      emu = apply_to(Emulator.new(6, 3), frame)
      assert emu_grid(emu) == Queries.get_text(next)
    end

    test "an in-cell control byte is sanitized, never bled into the frame (G5)" do
      # a cell holding a raw \n would, unsanitized, land mid-row and shove the
      # rest onto the next line -- and no unchanged row would repaint it
      cells = [
        {0, 1, "\n", :white, :black, []},
        {2, 1, "Q", :white, :black, []}
      ]

      state = %{
        width: 6,
        height: 3,
        buffer: nil,
        sync_output: false,
        force_repaint: true
      }

      {output, result} = render_prod_frame(cells, state)

      refute String.contains?(output, "\n"),
             "an in-cell \\n leaked into the frame"

      grid = Emulator.new(6, 3) |> apply_to(output) |> emu_grid()
      assert grid == Queries.get_text(result.buffer)
    end

    # Runs the full production render_to_terminal (apply_cells + emit), capturing
    # the emitted bytes and resulting state -- exercises the C0 sanitization that
    # lives in the cell-write boundary, which build_terminal_frame alone bypasses.
    defp render_prod_frame(cells, state) do
      parent = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, new_state} = Backends.render_to_terminal(cells, state)
          send(parent, {:result, new_state})
        end)

      receive do
        {:result, new_state} -> {output, new_state}
      after
        1000 -> raise "render_to_terminal did not complete"
      end
    end
  end
end
