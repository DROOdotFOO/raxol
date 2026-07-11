defmodule Raxol.CrossTerminal.MouseCharacterizationTest do
  @moduledoc """
  Pins CURRENT behavior of the two parallel mouse decoders (problems
  backlog #4) before consolidation:

    * `Raxol.Terminal.ANSI.InputParser` — the driver input path
    * `Raxol.Terminal.Input.MouseHandler` — standalone handler

  KNOWN DIVERGENCE (documented, not fixed here): for the same SGR
  sequence, InputParser keeps 1-based coordinates while MouseHandler
  converts to 0-based. Whichever module survives consolidation must
  keep the DRIVER path's observable behavior (InputParser), since that
  is what apps see today.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Input.MouseHandler
  alias Raxol.Core.Events.Event

  # SGR: ESC [ < button ; x ; y (M=press|m=release), 1-based coords
  @sgr_left_press "\e[<0;10;5M"
  @sgr_left_release "\e[<0;10;5m"
  @sgr_wheel_up "\e[<64;3;4M"
  @sgr_ctrl_left "\e[<16;2;2M"
  @sgr_motion "\e[<32;7;8M"

  describe "InputParser (driver path) SGR decoding" do
    test "left press keeps 1-based coordinates" do
      assert [%Event{type: :mouse, data: data}] = InputParser.parse(@sgr_left_press)

      assert data.button == :left
      assert data.action == :press
      assert data.x == 10
      assert data.y == 5
      assert data.ctrl == false
    end

    test "release variant" do
      assert [%Event{type: :mouse, data: %{action: :release, button: :left}}] =
               InputParser.parse(@sgr_left_release)
    end

    test "wheel up decodes as wheel_up press" do
      assert [%Event{type: :mouse, data: %{button: :wheel_up}}] =
               InputParser.parse(@sgr_wheel_up)
    end

    test "ctrl modifier decodes" do
      assert [%Event{type: :mouse, data: %{ctrl: true, button: :left}}] =
               InputParser.parse(@sgr_ctrl_left)
    end

    test "motion bit decodes as move" do
      assert [%Event{type: :mouse, data: %{action: :move}}] =
               InputParser.parse(@sgr_motion)
    end

    test "X10 encoding: coords are byte minus 32 (1-based preserved)" do
      # button 0 (+32), x=11 (+32=43), y=6 (+32=38)
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 77, 32, 43, 38>>)

      assert data.button == :left
      assert data.action == :press
      assert data.x == 11
      assert data.y == 6
    end

    test "mouse event embedded in key stream parses in order" do
      events = InputParser.parse("a" <> @sgr_left_press <> "\e[A")
      assert [%Event{type: :key}, %Event{type: :mouse}, %Event{type: :key}] = events
    end
  end

  describe "MouseHandler (parallel module) SGR decoding" do
    test "left press converts to 0-based coordinates — DIVERGES from InputParser" do
      assert {:ok, event} = MouseHandler.parse_mouse_event(@sgr_left_press)

      assert event.button == :left
      assert event.type == :press
      assert event.protocol == :sgr
      # Same sequence, different origin convention than InputParser:
      assert event.x == 9
      assert event.y == 4
    end

    test "wheel event maps type to :scroll" do
      assert {:ok, event} = MouseHandler.parse_mouse_event(@sgr_wheel_up)
      assert event.type == :scroll
      assert event.button == :wheel_up
    end

    test "unknown sequence rejected" do
      assert {:error, :unknown_mouse_sequence} =
               MouseHandler.parse_mouse_event("\e[Znope")
    end
  end

  describe "tracking-mode enable sequences" do
    test "MouseHandler emits documented enable sequences" do
      # Pins the exact bytes; if consolidation changes them, terminals
      # stop reporting mouse and nothing else will catch it.
      assert MouseHandler.enable_mouse_tracking(:x11) =~ "\e[?1000h"
      assert MouseHandler.enable_mouse_tracking(:button_event) =~ "\e[?1002h"
      assert MouseHandler.enable_mouse_tracking(:any_event) =~ "\e[?1003h"
      assert MouseHandler.enable_mouse_tracking(:sgr) =~ "\e[?1006h"
    end
  end
end
