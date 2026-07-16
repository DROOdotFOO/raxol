defmodule Raxol.Property.RendererAdversarialTest do
  @moduledoc """
  The append path's negative suite: the printed-history append path,
  covering full-grid-path clear-on-resize regression characterization,
  fail-first checks on the immutable-prefix oracle, and the reflow-aware
  detection seam.

  Each test here either (a) characterizes a regression class the real,
  full-grid path exhibits and proves the new inline path is exempt from
  it, or (b) demonstrates the byte-capture oracle CATCHES a deliberately
  wrong stream before trusting any of the positive suite's green results
  (the same fail-first discipline `tb_oracle_test.exs` established,
  applied here to `InlineAuthority` itself rather than a hand-written
  byte string).
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Capabilities
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

  # ---------------------------------------------------------------------
  # Today's full-grid path clears on width change; the inline
  # append path is exempt by construction.
  # ---------------------------------------------------------------------

  describe "full-grid \\e[2J-on-resize characterization vs the inline path's exemption" do
    test "characterization: Backends.build_terminal_frame/4 emits \\e[2J on a width change (today's known regression class)" do
      prev = ScreenBuffer.new(80, 24)
      next = ScreenBuffer.new(120, 24)
      renderer = Renderer.new(next, %{}, %{}, true)

      frame = Backends.build_terminal_frame(prev, next, renderer, %{})

      assert SealOracle.emits_full_clear?(frame),
             "characterization assumption broke: build_terminal_frame no longer " <>
               "clears on width change -- update this test, and re-verify the " <>
               "inline path's exemption below is still a meaningful regression guard"
    end

    test "regression guard: InlineAuthority.resize/3 emits no \\e[2J on the equivalent width+height change" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed before resize\r\n")

      _resized = InlineAuthority.resize(authority, 120, 24)

      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # ---------------------------------------------------------------------
  # Fail-first: the immutable-prefix oracle must catch a deliberately-
  # repainting append before any GREEN result from the positive suite is
  # trusted.
  # ---------------------------------------------------------------------

  describe "fail-first: immutable-prefix oracle catches a deliberately-repainting append" do
    test "RED: repainting an already-sealed row (simulating a buggy append_sealed) is caught by the immutable-prefix oracle" do
      {device, authority} = new_authority()

      # Three CORRECT seals via the real production path.
      authority =
        Enum.reduce(1..3, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _authority = authority

      # Simulate the regression class the immutable-prefix oracle exists to reject: instead of
      # ALWAYS positioning at the region's bottom row (the real
      # `InlineAuthority.append_sealed/2`'s only addressing behavior),
      # a buggy implementation repaints row 1 -- already sealed -- with
      # different content (the Ink-style failure).
      IO.write(device, "\e[1;1Hrepainted row 1! (violates seal-once)\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      # THE RED RUN. If this ever starts returning `:ok`, the oracle
      # itself has regressed -- this is the RED counterpart to every `:ok`
      # assertion in `renderer_seal_once_property_test.exs`.
      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "GREEN: the same 3 blocks, continued with correct InlineAuthority.seal/2 calls, stay a valid immutable prefix" do
      {device, authority} = new_authority()

      authority =
        Enum.reduce(1..3, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _authority =
        Enum.reduce(4..6, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)
    end
  end

  # ---------------------------------------------------------------------
  # with_cursor/3 exception safety: the sole \e7/\e8 owner must not leave
  # the save/restore bracket unbalanced if the wrapped fun raises.
  # ---------------------------------------------------------------------

  describe "with_cursor/3: the DECSC/DECRC bracket stays balanced even when the wrapped fun raises" do
    test "an exception inside the fun still emits the matching restore, then propagates" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      assert_raise RuntimeError, "boom", fn ->
        InlineAuthority.with_cursor(authority, :history, fn _t ->
          raise "boom"
        end)
      end

      all_bytes = raw(device)

      new_bytes =
        binary_part(
          all_bytes,
          byte_size(bytes_before),
          byte_size(all_bytes) - byte_size(bytes_before)
        )

      # The save ("\e7") and restore ("\e8") must both have been emitted,
      # in order, even though `fun` never returned normally -- the
      # `after` block in `with_cursor/3` runs on unwind, not just on the
      # happy path, so the single hardware DECSC register is never left
      # holding an unmatched save.
      assert new_bytes == Dialect.cursor_save() <> Dialect.cursor_restore()
    end
  end

  # ---------------------------------------------------------------------
  # The reflow-aware detection seam: thin, wired, no re-emission.
  # ---------------------------------------------------------------------

  describe "reflow-aware detection seam: reflow_capable?/1 + resize/3's telemetry hook" do
    test "reflow_capable?/1: true only for iTerm2 per the terminal-matrix probe, false for everything else" do
      assert InlineAuthority.reflow_capable?(%Capabilities{
               identity: {"iTerm2", "3.5.0"}
             })

      refute InlineAuthority.reflow_capable?(%Capabilities{
               identity: {"WezTerm", "20240203"}
             })

      refute InlineAuthority.reflow_capable?(%Capabilities{
               identity: {"kitty", "0.32.2"}
             })

      refute InlineAuthority.reflow_capable?(%Capabilities{identity: nil})
      refute InlineAuthority.reflow_capable?(nil)
    end

    test "resize/3 fires the seam's telemetry event only when geometry changed AND the terminal is reflow-capable -- and re-emits nothing" do
      handler_id = "t2b-reflow-seam-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_fired, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      caps = %Capabilities{identity: {"iTerm2", "3.5.0"}}
      {device, authority} = new_authority(capabilities: caps)
      authority = InlineAuthority.seal(authority, "sealed\r\n")

      bytes_before_resize = raw(device)

      _resized = InlineAuthority.resize(authority, @width, 20)

      assert_receive {:telemetry_fired,
                      [:raxol, :ui, :paint_authority, :reflow_capable_resize],
                      _measurements, metadata}

      assert metadata.old_region_top == @region_top
      assert metadata.new_region_top == 20 - @footer_rows

      all_bytes = raw(device)
      assert String.starts_with?(all_bytes, bytes_before_resize)

      new_bytes =
        binary_part(
          all_bytes,
          byte_size(bytes_before_resize),
          byte_size(all_bytes) - byte_size(bytes_before_resize)
        )

      # The ONLY new bytes after resize are ScrollRegionManager's single
      # DECSTBM re-set -- ships seal-time-only no matter what the seam detects.
      assert new_bytes == Dialect.region_set(1, 20 - @footer_rows)
      refute SealOracle.emits_full_clear?(all_bytes)
    end

    test "resize/3 does NOT fire the seam when geometry is unchanged (same height, footer_rows constant)" do
      handler_id = "t2b-reflow-seam-noop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_fired, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      caps = %Capabilities{identity: {"iTerm2", "3.5.0"}}
      {_device, authority} = new_authority(capabilities: caps)

      _resized = InlineAuthority.resize(authority, @width, @height)

      refute_receive {:telemetry_fired, _event, _measurements, _metadata}, 50
    end

    test "resize/3 does NOT fire the seam on a reflow-incapable terminal, even when geometry changes" do
      handler_id =
        "t2b-reflow-seam-incapable-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_fired, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      caps = %Capabilities{identity: {"WezTerm", "20240203"}}
      {device, authority} = new_authority(capabilities: caps)

      _resized = InlineAuthority.resize(authority, @width, 20)

      refute_receive {:telemetry_fired, _event, _measurements, _metadata}, 50

      # Seal-time-only is still correctly applied regardless -- the DECSTBM
      # re-set still happens, just with no telemetry.
      assert SealOracle.region_sets(raw(device)) == [
               {1, @region_top},
               {1, 20 - @footer_rows}
             ]
    end
  end
end
