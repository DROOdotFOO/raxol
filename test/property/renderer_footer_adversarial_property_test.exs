defmodule Raxol.Property.RendererFooterAdversarialTest do
  @moduledoc """
  Negative-case suite for the pinned footer viewport, relevant to the
  footer path specifically: characterization tests plus fail-first
  RED/GREEN pairs for the footer-confinement and keyframe-ban guards this
  module adds.

  Each test here either (a) characterizes a regression class the real,
  full-grid path exhibits and proves the footer-scoped path is exempt, or
  (b) demonstrates a footer-scoped guard CATCHES a deliberately wrong
  stream before trusting any of the positive suite's GREEN results (the
  fail-first discipline `tb_oracle_test.exs` established and
  `renderer_adversarial_property_test.exs` applied to the append path's
  `InlineAuthority.seal/2`; this file applies the same discipline to
  `repaint/2`/`keyframe/2`).
  """

  # async: false — this suite drives full terminal-emulator replays in a
  # hot loop (CPU-bound). Co-scheduling several such suites in the async
  # pool starves them of cores on small CI runners (the 2-core Windows
  # matrix), timing out whichever heavy property loses the scheduling
  # draw. Serializing costs nothing in throughput there (the work is
  # CPU-bound either way) and removes the contention-induced timeouts.
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Harness.Test.BuggyAuthority
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Renderer
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.UI.Rendering.PaintAuthority.Dialect
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 40
  @height 10
  @footer_rows 2
  @region_top 8

  defp new_authority(opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, @width, @height, @footer_rows, opts)}
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp footer_range(authority) do
    top = InlineAuthority.region_top(authority)
    count = InlineAuthority.footer_row_count(authority)
    (top + 1)..(top + count)//1
  end

  defp delta(all_bytes, prior_size) do
    binary_part(all_bytes, prior_size, byte_size(all_bytes) - prior_size)
  end

  defp strip_cursor_bracket(bytes) do
    save = Dialect.cursor_save()
    restore = Dialect.cursor_restore()

    bytes
    |> strip_prefix(save)
    |> strip_suffix(restore)
  end

  defp strip_prefix(bytes, prefix) do
    if String.starts_with?(bytes, prefix) do
      binary_part(
        bytes,
        byte_size(prefix),
        byte_size(bytes) - byte_size(prefix)
      )
    else
      bytes
    end
  end

  defp strip_suffix(bytes, suffix) do
    if String.ends_with?(bytes, suffix) do
      binary_part(bytes, 0, byte_size(bytes) - byte_size(suffix))
    else
      bytes
    end
  end

  # ---------------------------------------------------------------------
  # Acceptance 4: full-grid keyframe characterization vs the
  # footer-scoped path's exemption.
  # ---------------------------------------------------------------------

  describe "footer-scoped contrast: full-grid \\e[2J-on-resize vs the footer path's exemption" do
    test "characterization: Backends.build_terminal_frame/4 emits \\e[2J on a width change (today's known regression class)" do
      prev = ScreenBuffer.new(80, 24)
      next = ScreenBuffer.new(120, 24)
      renderer = Renderer.new(next, %{}, %{}, true)

      frame = Backends.build_terminal_frame(prev, next, renderer, %{})

      assert SealOracle.emits_full_clear?(frame),
             "characterization assumption broke: build_terminal_frame no longer " <>
               "clears on width change -- update this test, and re-verify the " <>
               "footer path's exemption below is still a meaningful regression guard"
    end

    test "regression guard: resize/3 |> keyframe/2 (the footer re-derivation) emits no \\e[2J on the equivalent width+height change" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed before resize\r\n")
      authority = InlineAuthority.repaint(authority, ["live", "composer"])

      resized = InlineAuthority.resize(authority, 120, 24)
      _final = InlineAuthority.keyframe(resized, ["live", "composer"])

      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # ---------------------------------------------------------------------
  # Fail-first: footer-confinement must be ABLE to fail before any
  # GREEN result from the positive suite is trusted.
  # ---------------------------------------------------------------------

  describe "fail-first: footer-confinement catches a deliberately-bleeding footer write" do
    test "RED: BuggyAuthority.footer_bleed_cup/1 (absolute CUP one row into history) is caught by the confinement check" do
      {_device, authority} = new_authority()
      bad = BuggyAuthority.footer_bleed_cup(@region_top)

      rows = SealOracle.cup_rows(bad)

      refute Enum.all?(rows, &(&1 in footer_range(authority))),
             "fail-first: the footer-confinement check must be ABLE to fail " <>
               "on a bleeding absolute CUP, or every GREEN result below is " <>
               "meaningless"
    end

    test "RED: BuggyAuthority.footer_bleed_relative/1 (CUP to footer then CUU into history) is caught by the confinement check" do
      {_device, authority} = new_authority()
      bad = BuggyAuthority.footer_bleed_relative(@region_top)

      rows = SealOracle.cup_rows(bad)

      refute Enum.all?(rows, &(&1 in footer_range(authority)))
    end

    test "RED: BuggyAuthority.footer_bleed_vpa/1 (CUP to footer then VPA into history) is caught by the confinement check" do
      {_device, authority} = new_authority()
      bad = BuggyAuthority.footer_bleed_vpa(@region_top)

      rows = SealOracle.cup_rows(bad)

      refute Enum.all?(rows, &(&1 in footer_range(authority)))
    end

    test "RED: a hand-injected footer write bypassing repaint/2 (raw CUP into history) is caught by the confinement check" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "history content\r\n")
      prior_size = device |> raw() |> byte_size()

      # Bypasses the safe `repaint/2` API entirely -- simulates a buggy
      # footer implementation that forgot to scope its CUP to the footer
      # range, addressing `region_top` (the last HISTORY row) instead.
      IO.write(device, "\e[#{@region_top};1H\e[2Kbuggy footer bleed")

      new_bytes = delta(raw(device), prior_size)
      rows = SealOracle.cup_rows(new_bytes)

      refute Enum.all?(rows, &(&1 in footer_range(authority)))
    end

    test "GREEN: the same scenarios, repainted via the real repaint/2, stay confined to the footer range" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "history content\r\n")
      prior_size = device |> raw() |> byte_size()

      authority = InlineAuthority.repaint(authority, ["status", "composer"])

      new_bytes = delta(raw(device), prior_size)
      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert Enum.all?(rows, &(&1 in footer_range(authority)))
    end
  end

  # ---------------------------------------------------------------------
  # Fail-first: keyframe/Ctrl-L touching history must be ABLE to fail.
  # ---------------------------------------------------------------------

  describe "fail-first: keyframe-touches-history is caught by the confinement check" do
    test "RED: BuggyAuthority.keyframe_history_touch/1 (a footer keyframe burst that repaints a history row) is caught" do
      {_device, authority} = new_authority()
      bad = BuggyAuthority.keyframe_history_touch(@region_top)

      rows = SealOracle.cup_rows(bad)

      refute Enum.all?(rows, &(&1 in footer_range(authority))),
             "fail-first: the confinement check must be ABLE to fail on a " <>
               "keyframe that touches history, or the GREEN result " <>
               "below is meaningless"
    end

    test "GREEN: the real keyframe/2 (Ctrl-L recovery) never touches history, only the footer range" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "history content\r\n")
      prior_size = device |> raw() |> byte_size()

      authority = InlineAuthority.keyframe(authority, ["status", "composer"])

      new_bytes = delta(raw(device), prior_size)
      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert Enum.all?(rows, &(&1 in footer_range(authority)))
      refute SealOracle.emits_full_clear?(new_bytes)
    end
  end

  # ---------------------------------------------------------------------
  # Fail-first: a footer-originated write that stomps sealed history must
  # be caught by the immutable-prefix oracle, exactly as the append
  # path's own fail-first test proves for a second seal.
  # ---------------------------------------------------------------------

  describe "fail-first: immutable-prefix oracle catches a footer write that stomps sealed history" do
    test "RED: a buggy 'footer' write that actually overwrites row 1 (already sealed) breaks the immutable-prefix oracle" do
      {device, authority} = new_authority()
      _authority = InlineAuthority.seal(authority, "sealed block 1\r\n")

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      # A buggy footer path that stomps the sealed history row instead of
      # confining itself to the footer range -- the two-emit-paths-collide
      # failure mode this oracle exists to reject, this time originating
      # from the footer side rather than a second seal.
      IO.write(device, "\e[1;1Hstomped by a buggy footer write\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "GREEN: the same scenario continued with real repaint/2 + keyframe/2 calls never touches history" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed block 1\r\n")

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      _authority =
        InlineAuthority.keyframe(authority, ["status", "composer v2"])

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)
    end
  end
end
