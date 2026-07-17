defmodule Raxol.Harness.ScrollEntryTest do
  @moduledoc """
  SCROLL-ENTRY sealing (V field ruling: chat semantics): once pinned,
  sealed content enters at the region BOTTOM and scrolls upward -- never
  fills downward from `next_row` leaving a void between the conversation
  and the footer.

  The under-filled phase (`next_row < history_bottom` -- a guest boot
  pinned mid-screen with shell content above) is where the two models
  diverge: fill-down (the default, every byte-golden world) CUPs to
  `next_row`; scroll-entry CUPs to the region's bottom row and lets each
  `\\r\\n`'s index-at-region-boundary scroll do the entry. Consequences
  pinned here, per the field brief:

    * (a) rows above (shell content, then blanks) scroll up and evict
      into native scrollback -- shell content preserved IN ORDER, blank
      rows evicted as blanks (the dirty-scrollback cost, bounded by one
      screenful -- accepted and documented);
    * (b) immutable prefix: sealed bytes are never re-addressed -- the
      terminal relocates rows, we never rewrite (emulator-replay oracle
      proves sealed content reads back intact across the under-filled
      phase);
    * (c) after the first scroll-entry seal `next_row` IS the region
      bottom -- steady state -- and every subsequent seal is
      byte-identical to the always-filled fill-down model at the same
      state (the seamless-seam byte test);
    * (d) the boot greeting transient is erased (targeted EL) BEFORE the
      first seal's scroll in the same frame, so its pixels never scroll
      into print-once history.

  Default is `:fill_down` everywhere -- the compat rule this lane's
  adaptive-pin unit set: existing byte-golden suites stay untouched;
  the guest bottom-pin boot (and the demos) ride `:scroll_entry`.
  """

  # Not async: shares the emulator-replay oracle cost profile of
  # adaptive_pin_test (see that module's note).
  use ExUnit.Case, async: false

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 60
  @rows 24
  @footer_rows 6
  @bottom @rows - @footer_rows

  # -- helpers -------------------------------------------------------------

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

  # Absolute-CUP rows only (`CSI row;col H`) -- the entry-position walk.
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

  # Combined terminal-owned history: scrollback ++ on-screen rows above
  # the split, as row texts.
  defp combined_history(bytes) do
    emu = SealOracle.replay(bytes, width: @width, height: @rows)

    rows =
      Emulator.get_scrollback(emu) ++
        SealOracle.rows_above_footer(emu, @bottom)

    Enum.map(rows, &row_text/1)
  end

  defp seal_lines(n, prefix) do
    Enum.map(1..n, &"#{prefix}-#{&1}\r\n")
  end

  defp shell_preamble(device, count) do
    Enum.each(1..count, fn i -> IO.write(device, "shell-#{i}\r\n") end)
  end

  # A guest bottom-pin boot over `shell_rows` rows of shell content:
  # probe row = shell_rows + 1.
  defp guest_auth(device, shell_rows, opts \\ []) do
    shell_preamble(device, shell_rows)

    InlineAuthority.new(
      device,
      @width,
      @rows,
      @footer_rows,
      Keyword.merge(
        [
          capabilities: nil,
          pin: :adaptive,
          boot_cursor: {shell_rows + 1, 1}
        ],
        opts
      )
    )
  end

  # ------------------------------------------------------------------
  # Entry position (the CUP walk)
  # ------------------------------------------------------------------

  describe "entry position" do
    test "an under-filled scroll-entry seal enters at the region bottom, never next_row" do
      device = new_device()
      auth = guest_auth(device, 10)

      assert auth.pin_state == :pinned
      assert auth.next_row == 11

      {auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(2, "line"))
        end)

      # The seal's one CUP is the region bottom -- chat entry.
      assert cup_h_rows(bytes) == [@bottom]
      # Steady state reached after the first scroll-entry seal.
      assert auth.next_row == @bottom
    end

    test "the default stays fill-down: an under-filled pinned seal enters at next_row" do
      device = new_device()

      auth =
        InlineAuthority.new(device, @width, @rows, @footer_rows,
          capabilities: nil
        )

      {_auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(2, "line"))
        end)

      assert cup_h_rows(bytes) == [1]
    end

    test "entry: :scroll_entry is honored on an explicit :immediate pin (the probe-failed fallback)" do
      device = new_device()

      auth =
        InlineAuthority.new(device, @width, @rows, @footer_rows,
          capabilities: nil,
          entry: :scroll_entry
        )

      {_auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(1, "line"))
        end)

      assert cup_h_rows(bytes) == [@bottom]
    end
  end

  # ------------------------------------------------------------------
  # Scrollback accounting + immutable prefix (the emulator oracle)
  # ------------------------------------------------------------------

  describe "eviction accounting and the immutable prefix" do
    test "shell content evicts in order, blanks evict as blanks, sealed content reads back intact" do
      device = new_device()
      auth = guest_auth(device, 10)

      auth = InlineAuthority.seal(auth, seal_lines(3, "one"))
      mid = raw(device)
      auth = InlineAuthority.seal(auth, seal_lines(4, "two"))
      _auth = InlineAuthority.seal(auth, seal_lines(2, "three"))
      final = raw(device)

      history = combined_history(final)

      # The junk prefix is FIXED at (bottom - 1) rows: everything that
      # sat above the region-bottom entry row at the first seal -- 10
      # shell rows then (bottom - 1 - 10) blanks. Bounded by one
      # screenful, never more.
      junk = Enum.take(history, @bottom - 1)
      assert Enum.take(junk, 10) == Enum.map(1..10, &"shell-#{&1}")
      assert Enum.drop(junk, 10) == List.duplicate("", @bottom - 1 - 10)

      sealed = Enum.slice(history, @bottom - 1, 9)

      assert sealed ==
               Enum.map(1..3, &"one-#{&1}") ++
                 Enum.map(1..4, &"two-#{&1}") ++
                 Enum.map(1..2, &"three-#{&1}")

      # Immutable prefix across the under-filled phase: the mid-run
      # replay's sealed window is a prefix of the final one.
      sealed_mid = mid |> combined_history() |> Enum.slice(@bottom - 1, 3)

      assert SealOracle.immutable_prefix?(sealed_mid, sealed) == :ok
    end

    test "sealed content sits flush above the footer split (no void)" do
      device = new_device()
      auth = guest_auth(device, 10)
      _auth = InlineAuthority.seal(auth, seal_lines(2, "chat"))

      emu = SealOracle.replay(raw(device), width: @width, height: @rows)

      screen =
        emu
        |> Emulator.get_screen_buffer()
        |> Map.get(:cells)
        |> Enum.map(&row_text/1)

      # Rows bottom-2..bottom-1 hold the freshly sealed lines; row
      # `bottom` is the region's always-blank scroll row. Nothing
      # between the conversation and the footer.
      assert Enum.at(screen, @bottom - 3) == "chat-1"
      assert Enum.at(screen, @bottom - 2) == "chat-2"
      assert Enum.at(screen, @bottom - 1) == ""
    end
  end

  # ------------------------------------------------------------------
  # The under-filled -> steady-state seam
  # ------------------------------------------------------------------

  describe "the steady-state seam" do
    test "after the first scroll-entry seal, seal bytes are identical to the filled fill-down model" do
      scroll_device = new_device()
      fill_device = new_device()

      scroll = guest_auth(scroll_device, 10)
      scroll = InlineAuthority.seal(scroll, seal_lines(1, "warm"))
      assert scroll.next_row == @bottom

      # Drive a default fill-down authority to the same steady state
      # (region full, next_row == bottom).
      fill =
        InlineAuthority.new(fill_device, @width, @rows, @footer_rows,
          capabilities: nil
        )

      fill = InlineAuthority.seal(fill, seal_lines(@bottom, "warm"))
      assert fill.next_row == @bottom

      {_scroll, scroll_bytes} =
        frame_bytes(scroll_device, fn ->
          InlineAuthority.seal(scroll, seal_lines(3, "steady"))
        end)

      {_fill, fill_bytes} =
        frame_bytes(fill_device, fn ->
          InlineAuthority.seal(fill, seal_lines(3, "steady"))
        end)

      assert scroll_bytes == fill_bytes
    end
  end

  # ------------------------------------------------------------------
  # Surface: greeting coherence + the echo/answer rhythm
  # ------------------------------------------------------------------

  describe "Surface integration" do
    defp new_surface(device, opts) do
      Surface.new(
        [],
        Keyword.merge(
          [
            device: device,
            width: @width,
            rows: @rows,
            footer_rows: @footer_rows,
            mode: :inline_log,
            capabilities: nil,
            pin: :adaptive,
            boot: {:guest, {11, 1}},
            stream_open: true
          ],
          opts
        )
      )
    end

    test "the greeting is erased before the first seal's scroll, in the same frame" do
      device = new_device()
      shell_preamble(device, 10)
      model = new_surface(device, greeting: true)

      assert [greeting_row] = model.greeting_rows

      {_model, bytes} =
        frame_bytes(device, fn ->
          model = %{model | pending_submit: %{text: "hello"}}
          Surface.submit_accepted(model)
        end)

      # Erase-then-scroll: the greeting row's EL precedes the seal's
      # bottom-entry CUP in the same frame's bytes.
      erase_at = :binary.match(bytes, "\e[#{greeting_row};1H\e[K")
      seal_at = :binary.match(bytes, "\e[#{@bottom};1H")
      assert {erase_pos, _} = erase_at
      assert {seal_pos, _} = seal_at
      assert erase_pos < seal_pos

      # And the greeting text never enters terminal-owned history.
      refute Enum.any?(
               combined_history(raw(device)),
               &String.contains?(&1, "welcome back")
             )
    end

    test "echo and answer sit tight above the footer: one separator blank, no void" do
      device = new_device()
      shell_preamble(device, 10)
      model = new_surface(device, greeting: true)

      model = %{model | pending_submit: %{text: "hello"}}
      model = Surface.submit_accepted(model)

      events = [
        %{
          id: 1,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{prompt: "hello"}
        },
        %{
          id: 2,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{item_id: "a1", item_type: :message}
        },
        %{
          id: 3,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            item_id: "a1",
            item_type: :message,
            role: :assistant,
            content: "the answer"
          }
        },
        %{
          id: 4,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{final: true}
        }
      ]

      model = Surface.append_events(model, events)

      model =
        Enum.reduce(1..4, model, fn _n, m ->
          {m, _} = Surface.advance(m)
          m
        end)

      _model = Surface.flush_held(model)

      emu = SealOracle.replay(raw(device), width: @width, height: @rows)

      screen =
        emu
        |> Emulator.get_screen_buffer()
        |> Map.get(:cells)
        |> Enum.map(&row_text/1)

      # Bottom-anchored transcript, top-down: echo, separator blank,
      # answer block (mirrored-chevron contour + its evidence row),
      # then ONLY the region's always-blank scroll row before the
      # footer -- no void, no stray blanks between the conversation
      # and the footer. Row text pins ride the dialogue-chevron contour
      # (one sigil per speaker); the structural claim is the blank
      # accounting.
      transcript = Enum.slice(screen, @bottom - 5, 5)

      assert ["❯ hello", "", "❮ the answer", "  no evidence provided", ""] =
               transcript

      # Shell content is intact above (still on screen -- nothing ever
      # repainted it).
      assert Enum.at(screen, 0) =~ "shell-"
    end
  end
end
