defmodule Raxol.Harness.GuestBootTest do
  @moduledoc """
  GUEST-BOOT: start the surface exactly where the user's shell left the
  cursor (`InlineAuthority.new/5`'s `:boot_cursor`, fed by the DSR probe
  `Raxol.Terminal.InlineDriver.probe_cursor/2`; Surface-level opt-in via
  `boot: {:guest, {row, col}}`).

  Closes the adaptive-pin unit's declared deferral ("boot still uses
  startup_push_up -- the footer floats at the top of a blank screen"):
  with a probed cursor the floating footer starts AT the prompt, and a
  prompt at/near the screen bottom takes the SCROLL-ENTRY path -- the
  existing one-way float->pin transition fired at construction -- so the
  transcript + composer are bottom-anchored from the first frame.

  Falsifiers under test:

    * placement math -- float at the probe row; scroll-entry when
      `row > history_bottom`; the `col > 1` unterminated-line advance;
      device-lie clamping; degenerate geometry's honest release;
    * shell content is NEVER repainted -- byte-level (no absolute CUP
      above the content start; the only bytes below it are targeted ELs
      and native `\\n` scroll at the physical bottom) AND via the
      SealOracle emulator replay (independent oracle: simulated shell
      bytes prepended to the captured stream; the replayed history must
      read shell lines then sealed lines, contiguously, byte-for-byte);
    * the caller contract -- `:boot_cursor` without `pin: :adaptive`
      raises; malformed `:boot` shapes raise at the Surface seam; the
      default (`:top` / no `:boot_cursor`) stays byte-identical to
      today, so every existing byte-golden world is untouched;
    * composition -- the state a guest boot lands in is the SAME
      pin-state machine `test/harness/adaptive_pin_test.exs` pins:
      post-boot behavior is byte-identical to an organically
      transitioned authority.
  """

  # Same rationale as adaptive_pin_test: emulator-replay oracle tests
  # are heavy; keep them out of the async pool.
  use ExUnit.Case, async: false

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 60
  @rows 12
  @footer_rows 4
  # The pinned model's history/footer split for this geometry.
  @bottom @rows - @footer_rows

  # -- helpers (mirroring adaptive_pin_test) --------------------------------

  defp new_device do
    {:ok, device} = StringIO.open("")
    device
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp frame_bytes(device, fun) do
    before_bytes = raw(device)
    result = fun.()
    after_bytes = raw(device)

    {result,
     binary_part(
       after_bytes,
       byte_size(before_bytes),
       byte_size(after_bytes) - byte_size(before_bytes)
     )}
  end

  defp new_auth(device, opts) do
    InlineAuthority.new(
      device,
      @width,
      @rows,
      @footer_rows,
      Keyword.merge([capabilities: nil], opts)
    )
  end

  defp footer_lines, do: ["S", "A", "B", "C"]

  defp seal_lines(n, prefix \\ "line") do
    Enum.map(1..n, &"#{prefix}-#{&1}\r\n")
  end

  # Absolute-CUP rows only (`CSI row;col H`) -- the same narrow scan
  # adaptive_pin_test uses, because SealOracle.cup_rows/2 also records
  # the row a `\e8` restore lands on (row 1 in a fresh replay), which is
  # not an address this module chose and would poison a min() assert.
  defp cup_h_rows(bytes) do
    bytes
    |> SequenceScanner.scan()
    |> Enum.flat_map(fn
      {:csi, params, "H"} ->
        case params |> String.split(";") |> List.first() |> Integer.parse() do
          {row, _rest} when row >= 1 -> [row]
          _other -> []
        end

      _token ->
        []
    end)
  end

  defp row_text(row) do
    row
    |> Enum.map_join("", fn cell -> cell.char || " " end)
    |> String.trim_trailing()
  end

  defp history_texts(bytes, region_top, opts) do
    bytes
    |> SealOracle.replay(width: @width, height: @rows)
    |> SealOracle.history(region_top, opts)
    |> Enum.map(&row_text/1)
  end

  # Simulated shell history: what a real shell session leaves on screen
  # before the harness is launched -- N `\r\n`-terminated lines printed
  # by plain native flow from a fresh screen. Returns the bytes AND the
  # 1-based row the cursor ends on (which is what a DSR probe would
  # report as the CPR row).
  defp shell_bytes(n, prefix \\ "shell") do
    bytes = Enum.map_join(1..n, "", &"#{prefix}-#{&1}\r\n")
    cursor_row = min(n + 1, @rows)
    {bytes, cursor_row}
  end

  # ------------------------------------------------------------------
  # Placement math: the LEGACY float (opt-in via guest_placement: :float
  # -- V's ruling made bottom-pin the default; see the next describe)
  # ------------------------------------------------------------------

  describe "guest boot, prompt mid-screen (legacy :float opt-in)" do
    test "construction emits zero bytes; the footer floats at the probe row" do
      device = new_device()

      auth =
        new_auth(device,
          pin: :adaptive,
          boot_cursor: {5, 1},
          guest_placement: :float
        )

      assert raw(device) == ""
      assert auth.pin_state == :floating
      assert auth.next_row == 5

      {_auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.keyframe(auth, footer_lines())
        end)

      assert SealOracle.region_sets(bytes) == []
      assert Enum.sort(Enum.uniq(cup_h_rows(bytes))) == [5, 6, 7, 8]
    end

    test "no byte ever addresses a row above the probe row while floating" do
      device = new_device()

      auth =
        device
        |> new_auth(
          pin: :adaptive,
          boot_cursor: {5, 1},
          guest_placement: :float
        )
        |> InlineAuthority.keyframe(footer_lines())

      auth = InlineAuthority.seal(auth, seal_lines(2))
      _auth = InlineAuthority.repaint(auth, footer_lines())

      all = raw(device)
      rows_addressed = cup_h_rows(all)
      assert rows_addressed != []
      # Rows 1..4 hold the shell's own content -- never addressed.
      assert Enum.min(rows_addressed) >= 5
      assert SealOracle.region_sets(all) == []
      refute SealOracle.emits_full_clear?(all)
    end

    test "a col > 1 probe reply advances past the unterminated shell line" do
      device = new_device()

      {auth, bytes} =
        frame_bytes(device, fn ->
          new_auth(device,
            pin: :adaptive,
            boot_cursor: {5, 9},
            guest_placement: :float
          )
        end)

      # One native \r\n -- never an overwrite of the partial line -- and
      # the float starts on the NEXT row.
      assert bytes == "\r\n"
      assert auth.pin_state == :floating
      assert auth.next_row == 6
    end

    test "the guest float then pins exactly like the organic transition" do
      device = new_device()

      auth =
        device
        |> new_auth(
          pin: :adaptive,
          boot_cursor: {3, 1},
          guest_placement: :float
        )
        |> InlineAuthority.keyframe(footer_lines())

      # 6 rows starting at row 3: next_row 3 -> 9 > bottom 8, so the
      # one-way transition fires inside the seal, exactly as the
      # adaptive-pin suite pins it for a row-1 float.
      {auth, transition_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(6))
        end)

      assert SealOracle.region_sets(transition_bytes) == [{1, @bottom}]
      assert auth.pin_state == :pinned
      assert auth.next_row == @bottom
    end
  end

  # ------------------------------------------------------------------
  # Placement math: the DEFAULT bottom-pin (V ruling -- input at the
  # screen bottom from frame one; supersedes shell-join)
  # ------------------------------------------------------------------

  describe "guest boot, prompt mid-screen (DEFAULT: bottom-pin)" do
    test "construction pins at the bottom with zero scroll bytes; content start stays at the probe row" do
      device = new_device()

      {auth, bytes} =
        frame_bytes(device, fn ->
          new_auth(device, pin: :adaptive, boot_cursor: {5, 1})
        end)

      # One region write, no newline scroll (nothing below the prompt to
      # push), nothing repainted.
      assert SealOracle.region_sets(bytes) == [{1, @bottom}]
      refute bytes =~ "\n\n"
      assert auth.pin_state == :pinned
      assert auth.next_row == 5
    end

    test "the first footer keyframe paints at the TRUE bottom rows, never at the probe row" do
      device = new_device()

      auth = new_auth(device, pin: :adaptive, boot_cursor: {5, 1})

      {_auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.keyframe(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(bytes))) ==
               Enum.to_list((@bottom + 1)..@rows)
    end

    test "shell rows above the probe row are never addressed" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive, boot_cursor: {5, 1})
        |> InlineAuthority.keyframe(footer_lines())

      auth = InlineAuthority.seal(auth, seal_lines(2))
      _auth = InlineAuthority.repaint(auth, footer_lines())

      rows_addressed = cup_h_rows(raw(device))
      assert rows_addressed != []
      assert Enum.min(rows_addressed) >= 5
      refute SealOracle.emits_full_clear?(raw(device))
    end
  end

  # ------------------------------------------------------------------
  # Placement math: scroll-entry (prompt at/near the screen bottom)
  # ------------------------------------------------------------------

  describe "guest boot, prompt at the bottom (scroll-entry)" do
    test "boot pins immediately: honest newline scroll, one region set, bottom-anchored" do
      device = new_device()

      {auth, bytes} =
        frame_bytes(device, fn ->
          new_auth(device, pin: :adaptive, boot_cursor: {@rows, 1})
        end)

      # The scroll that makes room is plain \n at the physical bottom --
      # native flow, exactly what any program printing N lines does.
      scroll = @rows - @bottom
      assert bytes =~ "\e[#{@rows};1H" <> String.duplicate("\n", scroll)

      # One region claim, today's exact split; never a full clear.
      assert SealOracle.region_sets(bytes) == [{1, @bottom}]
      refute SealOracle.emits_full_clear?(bytes)

      assert auth.pin_state == :pinned
      assert auth.next_row == @bottom
      assert auth.needs_keyframe

      # First footer paint lands in the PINNED zone: the bottom rows,
      # from the first frame.
      {_auth, footer_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes))) ==
               Enum.to_list((@bottom + 1)..@rows)
    end

    test "no CUP above the (scrolled) content start; below-prompt bytes are ELs only" do
      device = new_device()
      probe_row = @rows - 1

      auth = new_auth(device, pin: :adaptive, boot_cursor: {probe_row, 1})
      auth = InlineAuthority.keyframe(auth, footer_lines())
      _auth = InlineAuthority.seal(auth, seal_lines(1))

      # probe_row 11 > bottom 8: scrolled by 3, so shell content now
      # ends at row 7 and OUR zone starts at 8. Nothing may address
      # rows 1..7.
      all = raw(device)
      assert Enum.min(cup_h_rows(all)) >= @bottom
      refute SealOracle.emits_full_clear?(all)
    end

    test "a probe row past the physical screen is clamped (device lie)" do
      device = new_device()
      auth = new_auth(device, pin: :adaptive, boot_cursor: {99, 1})

      # Clamped to the bottom row, then the ordinary scroll-entry path.
      assert auth.pin_state == :pinned
      assert auth.next_row == @bottom
      assert SealOracle.region_sets(raw(device)) == [{1, @bottom}]
    end

    test "col > 1 on the bottom row: one native \\r\\n scroll, then scroll-entry" do
      device = new_device()

      {auth, bytes} =
        frame_bytes(device, fn ->
          new_auth(device, pin: :adaptive, boot_cursor: {@rows, 5})
        end)

      # The \r\n comes FIRST (past the unterminated prompt line), then
      # the transition's own bottom-row scroll.
      assert String.starts_with?(bytes, "\r\n")
      assert auth.pin_state == :pinned
      assert auth.next_row == @bottom
    end

    test "degenerate geometry: scroll-entry emits the honest release, never a lying pin" do
      device = new_device()
      # 5 rows, 6-row footer: DECSTBM can never pin here.
      auth =
        InlineAuthority.new(device, @width, 5, 6,
          capabilities: nil,
          pin: :adaptive,
          boot_cursor: {5, 1}
        )

      assert auth.pin_state == :pinned
      assert raw(device) =~ "\e[r"
      refute raw(device) =~ "\e[1;1r"
      assert SealOracle.region_sets(raw(device)) == []
    end
  end

  # ------------------------------------------------------------------
  # The caller contract
  # ------------------------------------------------------------------

  describe "the :boot_cursor caller contract" do
    test "boot_cursor without pin: :adaptive raises (zero bytes)" do
      device = new_device()

      assert_raise ArgumentError, ~r/requires pin: :adaptive/, fn ->
        new_auth(device, boot_cursor: {5, 1})
      end

      assert raw(device) == ""
    end

    test "malformed boot_cursor shapes raise" do
      device = new_device()

      for bad <- [{0, 1}, {1, 0}, {1.5, 1}, :bottom, {5}, {5, 1, 1}] do
        assert_raise ArgumentError, fn ->
          new_auth(device, pin: :adaptive, boot_cursor: bad)
        end
      end

      assert raw(device) == ""
    end

    test "no boot_cursor stays byte-identical to today's adaptive boot" do
      guest_free = new_device()
      classic = new_device()

      a = new_auth(guest_free, pin: :adaptive)
      b = new_auth(classic, pin: :adaptive)

      assert raw(guest_free) == raw(classic)
      assert a.next_row == b.next_row

      a = InlineAuthority.keyframe(a, footer_lines())
      b = InlineAuthority.keyframe(b, footer_lines())
      _a = InlineAuthority.seal(a, seal_lines(2))
      _b = InlineAuthority.seal(b, seal_lines(2))

      assert raw(guest_free) == raw(classic)
    end
  end

  # ------------------------------------------------------------------
  # The emulator-replay oracle: shell content survives boot untouched
  # ------------------------------------------------------------------

  describe "shell content is never repainted (emulator oracle)" do
    test "mid-screen prompt: shell lines read back intact; sealed lines enter at the region bottom" do
      {shell, cursor_row} = shell_bytes(4)
      assert cursor_row == 5

      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive, boot_cursor: {cursor_row, 1})
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(2))

      _auth = InlineAuthority.repaint(auth, footer_lines())

      # Independent oracle: replay the SHELL's own bytes followed by
      # ours. Under the bottom-pin boot's CHAT ENTRY (V field ruling --
      # sealed content enters at the region BOTTOM and scrolls upward,
      # never fills down from the prompt row), the combined history is
      # shell lines IN ORDER, then the fixed blank gap that sat between
      # the prompt row and the entry row (the documented, one-screenful-
      # bounded dirty-scrollback cost), then the sealed lines intact.
      # Any shell repaint, reordering, or sealed-row rewrite breaks the
      # equality. The pre-ruling contiguous layout (sealed lines
      # directly under the prompt) is exactly the retired fill-down
      # behavior -- see test/harness/scroll_entry_test.exs for the
      # entry-position pins.
      combined = shell <> raw(device)

      history = history_texts(combined, @bottom, high_water: @bottom - 1 + 2)

      assert history ==
               Enum.map(1..4, &"shell-#{&1}") ++
                 List.duplicate("", @bottom - 1 - 4) ++
                 ["line-1", "line-2"]
    end

    test "bottom prompt: scroll-entry evicts shell rows into scrollback intact, seals directly above the footer" do
      # 15 lines on a 12-row screen: 4 scrolled off already, cursor on
      # the (blank) bottom row -- the normal busy-shell launch state.
      {shell, cursor_row} = shell_bytes(15)
      assert cursor_row == @rows

      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive, boot_cursor: {cursor_row, 1})
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(3, "post"))

      _auth = InlineAuthority.repaint(auth, footer_lines())

      combined = shell <> raw(device)

      # 15 shell rows + 3 sealed rows, one continuous record: the boot
      # scroll pushed shell rows into scrollback (never rewrote them),
      # and the first sealed line sits directly below shell-15 with
      # zero blank rows between.
      history = history_texts(combined, @bottom, high_water: 18)

      assert history ==
               Enum.map(1..15, &"shell-#{&1}") ++
                 Enum.map(1..3, &"post-#{&1}")

      # And the footer occupies the true bottom rows from frame one.
      assert cup_h_rows(raw(device))
             |> Enum.filter(&(&1 > @bottom))
             |> Enum.sort()
             |> Enum.uniq() == Enum.to_list((@bottom + 1)..@rows)
    end

    test "post-boot behavior is byte-identical to an organically pinned authority" do
      guest_device = new_device()
      organic_device = new_device()

      # Guest: pinned at construction by scroll-entry.
      guest =
        guest_device
        |> new_auth(pin: :adaptive, boot_cursor: {@rows, 1})
        |> InlineAuthority.keyframe(footer_lines())

      # Organic: floated at row 1, filled to the transition (the
      # adaptive-pin suite's own path).
      organic =
        organic_device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(@bottom))
        |> InlineAuthority.keyframe(footer_lines())

      guest = InlineAuthority.keyframe(guest, footer_lines())

      assert guest.pin_state == :pinned
      assert organic.pin_state == :pinned
      assert guest.next_row == organic.next_row

      {guest, guest_seal} =
        frame_bytes(guest_device, fn ->
          InlineAuthority.seal(guest, seal_lines(2, "post"))
        end)

      {organic, organic_seal} =
        frame_bytes(organic_device, fn ->
          InlineAuthority.seal(organic, seal_lines(2, "post"))
        end)

      assert guest_seal == organic_seal

      {_guest, guest_footer} =
        frame_bytes(guest_device, fn ->
          InlineAuthority.repaint(guest, ["S2", "A2", "B2", "C2"])
        end)

      {_organic, organic_footer} =
        frame_bytes(organic_device, fn ->
          InlineAuthority.repaint(organic, ["S2", "A2", "B2", "C2"])
        end)

      assert guest_footer == organic_footer
    end
  end

  # ------------------------------------------------------------------
  # Surface integration (`boot:` option)
  # ------------------------------------------------------------------

  describe "Surface with boot: {:guest, pos}" do
    defp new_surface(opts) do
      device = new_device()

      model =
        Surface.new(
          [],
          Keyword.merge(
            [
              device: device,
              width: @width,
              rows: 20,
              footer_rows: 6,
              mode: :inline_log,
              capabilities: nil
            ],
            opts
          )
        )

      {model, device}
    end

    test "mid-screen guest boot: pinned at the bottom from frame one, shell rows untouched" do
      {_model, device} =
        new_surface(pin: :adaptive, boot: {:guest, {10, 1}})

      bytes = raw(device)
      # V ruling: input at the screen bottom always -- the region pins
      # at construction (20 rows / 6 footer -> split at 14) and the
      # footer paints at the true bottom rows; shell rows 1..9 are
      # never addressed.
      assert SealOracle.region_sets(bytes) == [{1, 14}]

      rows_addressed = cup_h_rows(bytes)
      assert rows_addressed != []
      assert Enum.min(rows_addressed) >= 10
    end

    test "bottom-row guest boot: bottom-anchored from the first frame" do
      {_model, device} =
        new_surface(pin: :adaptive, boot: {:guest, {20, 1}})

      bytes = raw(device)
      # Pinned at construction: today's exact split for 20 rows/6 footer.
      assert SealOracle.region_sets(bytes) == [{1, 14}]
      # Every addressed row is in our zone (content start 14, footer
      # 15..20); the shell rows that scrolled up are never touched.
      assert Enum.min(cup_h_rows(bytes)) >= 14
      refute SealOracle.emits_full_clear?(bytes)
    end

    test "boot: :top is the default and stays byte-identical" do
      {_m1, d1} = new_surface(pin: :adaptive)
      {_m2, d2} = new_surface(pin: :adaptive, boot: :top)
      assert raw(d1) == raw(d2)
    end

    test "guest boot without pin: :adaptive raises at the authority seam" do
      assert_raise ArgumentError, ~r/requires pin: :adaptive/, fn ->
        new_surface(boot: {:guest, {5, 1}})
      end
    end

    test "an unrecognized :boot value raises instead of silently becoming :top" do
      for bad <- [:guest, {:guest, {0, 1}}, {:guest, 5}, "top", nil] do
        assert_raise ArgumentError, ~r/:boot must be :top or/, fn ->
          new_surface(pin: :adaptive, boot: bad)
        end
      end
    end

    test "flat mode ignores the boot placement (flat IS guest boot by nature)" do
      {model, device} =
        new_surface(mode: :flat, boot: {:guest, {10, 1}})

      # No positioning vocabulary at all in flat mode.
      assert cup_h_rows(raw(device)) == []
      assert model.mode == :flat
    end
  end
end
