defmodule Raxol.Harness.AdaptivePinTest do
  @moduledoc """
  FOOTER-FOLLOWS-CONTENT: the adaptive pin (kill the first-load void).

  Doctrine ruling (harness-visual-doctrine.md §1.1 "guest, not occupier",
  §1.2 "charged minimum"): the harness must not claim the whole screen on
  an empty session. With `pin: :adaptive`, `InlineAuthority` starts in a
  FLOATING state -- no DECSTBM claimed, the footer painted directly below
  the last content row (the top of the screen on boot) -- and transitions
  ONE-WAY to today's bottom-pinned DECSTBM model exactly when content
  reaches the pinned footer position. From the transition on, behavior is
  byte-identical to today's model.

  The suite is organized around the falsifiers named in the unit spec:

    * boot frame writes NO bytes below the footer's floating position
      (no full-screen claim, no CUP to screen-bottom rows);
    * each seal while floating advances the footer down by the sealed
      row count;
    * the transition frame: old footer rows cleared via targeted EL,
      exactly one region set, zero content bytes rewritten -- proven by
      the SealOracle emulator-replay oracle (independent oracle rule),
      never by the module's own bookkeeping;
    * post-transition behavior byte-identical to the always-pinned model
      (`pin: :immediate`, the default);
    * resize during floating (stay-afloat = zero region bytes; a shrink
      past content transitions honestly);
    * degenerate refusal (the transition on a degenerate geometry emits
      the honest full-screen release, never a lying `1;1r`);
    * the default is `:immediate` -- every existing byte-golden world
      stays reachable unchanged (the compatibility decision).
  """

  # Deliberately NOT async: the emulator-replay oracle tests here are
  # heavy (full VT replay of multi-frame streams), and running them
  # inside the async pool starves the other replay-oracle suites'
  # 60s budgets on a loaded machine.
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

  # -- helpers -------------------------------------------------------------

  defp new_device do
    {:ok, device} = StringIO.open("")
    device
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # Runs `fun`, returns {result, bytes_emitted_by_fun}.
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

  defp new_auth(device, opts \\ []) do
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

  # Rows addressed by ABSOLUTE CUP (`CSI row;col H`) only -- the exact
  # vocabulary footer paints and the fill-down seal use. Narrower than
  # `SealOracle.cup_rows/2` (the fail-closed full walk, still used for
  # the "nothing below the footer" bound), which also records the row a
  # `\e8` restore lands on -- always row 1 here, since DECSC saves at the
  # walk's starting position, and that artifact is not an address this
  # module chose.
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

  defp history_texts(bytes, region_top, opts \\ []) do
    bytes
    |> SealOracle.replay(width: @width, height: @rows)
    |> SealOracle.history(region_top, opts)
    |> Enum.map(&row_text/1)
  end

  # ------------------------------------------------------------------
  # Boot: no full-screen claim
  # ------------------------------------------------------------------

  describe "adaptive boot (the charged minimum)" do
    test "constructing an adaptive authority emits zero bytes" do
      device = new_device()
      _auth = new_auth(device, pin: :adaptive)
      assert raw(device) == ""
    end

    test "the immediate default is byte-identical to today (compat pin)" do
      device = new_device()
      _auth = new_auth(device)
      assert raw(device) == "\e[1;#{@bottom}r"
    end

    test "floating footer paints at the top of the screen, never the bottom" do
      device = new_device()
      auth = new_auth(device, pin: :adaptive)

      {_auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.keyframe(auth, footer_lines())
        end)

      assert SealOracle.region_sets(bytes) == []

      rows_addressed = SealOracle.cup_rows(bytes, height: @rows)
      assert rows_addressed != []
      assert Enum.max(rows_addressed) <= @footer_rows

      # Not one byte addresses the pinned footer zone.
      refute Enum.any?(rows_addressed, &(&1 > @bottom))
    end
  end

  # ------------------------------------------------------------------
  # Floating seals: the footer follows content
  # ------------------------------------------------------------------

  describe "floating seals" do
    test "each seal advances the footer down by the sealed row count" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      # Seal 2 lines: content lands on rows 1..2 (the fill-down cursor).
      {auth, seal_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(2))
        end)

      assert SealOracle.region_sets(seal_bytes) == []

      # The next footer paint self-promotes to a keyframe at the new
      # position: rows 3..6 (directly below the 2 sealed rows).
      {auth, footer_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes))) == [3, 4, 5, 6]

      # One more seal of 3 lines: footer advances to rows 6..9.
      {auth, _bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(3, "more"))
        end)

      {_auth, footer_bytes2} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes2))) == [6, 7, 8, 9]

      # Still floating: not a single DECSTBM in the whole session so far.
      assert SealOracle.region_sets(raw(device)) == []
    end

    test "floating seal content rows are erased footer rows, then written once" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      {_auth, seal_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(2))
        end)

      # The rows converted from footer to content are EL-cleared before
      # the (EL-free) sealed content lands on them -- no footer residue
      # can survive into print-once history.
      assert seal_bytes =~ "\e[1;1H\e[K"
      assert seal_bytes =~ "\e[2;1H\e[K"
      refute SealOracle.emits_full_clear?(seal_bytes)
    end
  end

  # ------------------------------------------------------------------
  # The transition (float -> pin), one-way
  # ------------------------------------------------------------------

  describe "the float->pin transition" do
    test "content reaching the pinned position pins: one region set, honest scroll" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      # Fill the entire above-footer capacity in one seal: next_row goes
      # 1 -> 9 (> bottom 8), the footer lands on the pinned rows, and the
      # authority pins eagerly inside the same seal.
      {auth, transition_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(@bottom))
        end)

      # Exactly one DECSTBM, with today's exact bounds.
      assert SealOracle.region_sets(transition_bytes) == [{1, @bottom}]
      assert SealOracle.region_sets(raw(device)) == [{1, @bottom}]

      # The one-row scroll that restores the blank-row invariant is a
      # plain newline at the screen bottom -- native flow, never a
      # repaint, never a full clear.
      assert transition_bytes =~ "\e[#{@rows};1H\n"
      refute SealOracle.emits_full_clear?(raw(device))

      assert auth.pin_state == :pinned
      assert auth.next_row == @bottom
      assert auth.needs_keyframe

      # Post-transition footer paints land in the PINNED zone.
      {_auth, footer_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes))) ==
               Enum.to_list((@bottom + 1)..@rows)
    end

    test "sealed history survives the transition byte-for-byte (emulator oracle)" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      # Pre-transition prefix: 5 sealed rows, still floating.
      auth = InlineAuthority.seal(auth, seal_lines(5))
      auth = InlineAuthority.repaint(auth, footer_lines())
      prefix = raw(device)

      # Cross the transition, then keep sealing on the pinned side.
      auth = InlineAuthority.seal(auth, seal_lines(4, "cross"))
      auth = InlineAuthority.repaint(auth, footer_lines())
      auth = InlineAuthority.seal(auth, seal_lines(3, "after"))
      _auth = InlineAuthority.repaint(auth, footer_lines())
      final = raw(device)

      # Sealed rows are exactly the \r\n-terminated seal lines; the
      # transition's bare-\n scroll is not a sealed row.
      hw = fn bytes -> bytes |> :binary.matches("\r\n") |> length() end

      history_prefix = history_texts(prefix, @bottom, high_water: hw.(prefix))
      history_final = history_texts(final, @bottom, high_water: hw.(final))

      assert hw.(prefix) == 5
      assert hw.(final) == 12

      assert SealOracle.immutable_prefix?(history_prefix, history_final) == :ok

      assert history_final ==
               Enum.map(1..5, &"line-#{&1}") ++
                 Enum.map(1..4, &"cross-#{&1}") ++
                 Enum.map(1..3, &"after-#{&1}")
    end

    test "a block too large for the floating window pins BEFORE sealing" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      # 9 lines cannot fit above the floating footer (capacity 8): the
      # authority must pin first, then seal through the region's own
      # boundary scroll -- never overwrite a sealed row.
      {auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.seal(auth, seal_lines(@bottom + 1, "big"))
        end)

      assert SealOracle.region_sets(bytes) == [{1, @bottom}]
      assert auth.pin_state == :pinned

      history = history_texts(raw(device), @bottom, high_water: @bottom + 1)
      assert history == Enum.map(1..(@bottom + 1), &"big-#{&1}")
    end

    test "post-transition behavior is byte-identical to the always-pinned model" do
      adaptive_device = new_device()
      immediate_device = new_device()

      adaptive =
        adaptive_device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(@bottom))

      immediate =
        immediate_device
        |> new_auth()
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(@bottom))

      assert adaptive.pin_state == :pinned
      assert adaptive.next_row == immediate.next_row

      # Normalize the footer (the adaptive side owes a keyframe from the
      # transition; run one on both), then compare every subsequent
      # frame's bytes.
      adaptive = InlineAuthority.keyframe(adaptive, footer_lines())
      immediate = InlineAuthority.keyframe(immediate, footer_lines())

      {adaptive, adaptive_seal} =
        frame_bytes(adaptive_device, fn ->
          InlineAuthority.seal(adaptive, seal_lines(2, "post"))
        end)

      {immediate, immediate_seal} =
        frame_bytes(immediate_device, fn ->
          InlineAuthority.seal(immediate, seal_lines(2, "post"))
        end)

      assert adaptive_seal == immediate_seal

      {_adaptive, adaptive_footer} =
        frame_bytes(adaptive_device, fn ->
          InlineAuthority.repaint(adaptive, ["S2", "A2", "B2", "C2"])
        end)

      {_immediate, immediate_footer} =
        frame_bytes(immediate_device, fn ->
          InlineAuthority.repaint(immediate, ["S2", "A2", "B2", "C2"])
        end)

      assert adaptive_footer == immediate_footer
    end
  end

  # ------------------------------------------------------------------
  # Resize while floating
  # ------------------------------------------------------------------

  describe "resize while floating" do
    test "a resize the floating footer still fits emits zero bytes" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(2))

      {auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.resize(auth, @width, @rows + 8)
        end)

      assert bytes == ""
      assert auth.pin_state == :floating
      assert auth.needs_keyframe

      # The footer stays anchored to content, not the screen bottom: the
      # keyframe repaints at rows 3..6 exactly as before the resize.
      {_auth, footer_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, footer_lines())
        end)

      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes))) == [3, 4, 5, 6]
    end

    test "a shrink past the content transitions honestly at the new geometry" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(6))

      assert auth.pin_state == :floating

      new_rows = 8
      new_bottom = new_rows - @footer_rows

      {auth, bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.resize(auth, @width, new_rows)
        end)

      assert SealOracle.region_sets(bytes) == [{1, new_bottom}]
      assert auth.pin_state == :pinned
      assert auth.next_row == new_bottom
      refute SealOracle.emits_full_clear?(bytes)
    end
  end

  # ------------------------------------------------------------------
  # reassert / set_footer_rows while floating
  # ------------------------------------------------------------------

  describe "floating housekeeping" do
    test "reassert while floating emits zero bytes and latches the keyframe" do
      device = new_device()
      auth = new_auth(device, pin: :adaptive)

      {auth, bytes} =
        frame_bytes(device, fn -> InlineAuthority.reassert(auth) end)

      assert bytes == ""
      assert auth.pin_state == :floating
      assert auth.needs_keyframe
    end

    test "footer grow while floating claims rows below content, zero region bytes" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(2))

      {:ok, auth} = InlineAuthority.set_footer_rows(auth, @footer_rows + 2)
      assert auth.pin_state == :floating
      assert SealOracle.region_sets(raw(device)) == []

      {_auth, footer_bytes} =
        frame_bytes(device, fn ->
          InlineAuthority.repaint(auth, ["S", "A", "B", "C", "D", "E"])
        end)

      # Grown footer: rows 3..8 (content rows 1..2 untouched above).
      assert Enum.sort(Enum.uniq(cup_h_rows(footer_bytes))) ==
               [3, 4, 5, 6, 7, 8]
    end

    test "footer shrink while floating clears the vacated rows" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())

      {:ok, auth} = InlineAuthority.set_footer_rows(auth, 2)

      {_auth, bytes} =
        frame_bytes(device, fn ->
          {:ok, shrunk} = InlineAuthority.set_footer_rows(auth, 2)
          shrunk
        end)

      # Idempotent second call: zero bytes.
      assert bytes == ""

      # The first shrink cleared the two vacated rows (3 and 4) with
      # targeted ELs, never a full clear.
      all = raw(device)
      assert all =~ "\e[3;1H\e[K"
      assert all =~ "\e[4;1H\e[K"
      assert SealOracle.region_sets(all) == []
      refute SealOracle.emits_full_clear?(all)
    end

    test "a degenerate footer target is refused identically while floating" do
      device = new_device()
      auth = new_auth(device, pin: :adaptive)

      assert {:error, :degenerate} =
               InlineAuthority.set_footer_rows(auth, @rows - 1)

      assert raw(device) == ""
    end

    test "a grow past the floating window transitions, then hosts the claim" do
      device = new_device()

      auth =
        device
        |> new_auth(pin: :adaptive)
        |> InlineAuthority.keyframe(footer_lines())
        |> InlineAuthority.seal(seal_lines(7))

      assert auth.pin_state == :floating

      # next_row = 8; a 6-row footer no longer fits below content
      # (8 + 6 - 1 > 12): the authority pins at the new split, scrolling
      # exactly the overflow (2 rows) into native scrollback.
      {:ok, auth} = InlineAuthority.set_footer_rows(auth, 6)
      assert auth.pin_state == :pinned
      assert SealOracle.region_sets(raw(device)) == [{1, @rows - 6}]

      # Sealed content is intact: the reclaimed rows scrolled into native
      # scrollback, never painted over.
      history = history_texts(raw(device), @rows - 6, high_water: 7)
      assert history == Enum.map(1..7, &"line-#{&1}")
    end
  end

  # ------------------------------------------------------------------
  # Degenerate geometry
  # ------------------------------------------------------------------

  describe "degenerate geometry" do
    test "the transition on a degenerate geometry emits the honest release" do
      device = new_device()
      # rows 5 with a 6-row footer: DECSTBM can never pin here.
      auth = InlineAuthority.new(device, @width, 5, 6, pin: :adaptive)
      assert raw(device) == ""

      # First seal exhausts the (1-row) floating capacity and forces the
      # transition: the region write must be the full-screen release,
      # never a lying 1;1r.
      auth = InlineAuthority.seal(auth, seal_lines(2, "tiny"))
      assert auth.pin_state == :pinned
      assert raw(device) =~ "\e[r"
      refute raw(device) =~ "\e[1;1r"
      assert SealOracle.region_sets(raw(device)) == []
    end
  end

  # ------------------------------------------------------------------
  # Surface integration
  # ------------------------------------------------------------------

  describe "Surface with pin: :adaptive" do
    defp turn_events(turn_index) do
      base = (turn_index - 1) * 4

      [
        %{
          id: base + 1,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{prompt: "go"}
        },
        %{
          id: base + 2,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{item_id: "i#{turn_index}", item_type: "message"}
        },
        %{
          id: base + 3,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            item_id: "i#{turn_index}",
            item_type: "message",
            content: "block content #{turn_index}"
          }
        },
        %{
          id: base + 4,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{final: true}
        }
      ]
    end

    defp surface_events(turns), do: Enum.flat_map(1..turns, &turn_events/1)

    defp new_surface(events, opts) do
      device = new_device()

      model =
        Surface.new(
          events,
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

    defp drive_to_done(model) do
      case Surface.advance(model) do
        {model, :ok} -> drive_to_done(model)
        {model, :done} -> model
      end
    end

    test "the boot frame writes no bytes below the floating footer" do
      {_model, device} = new_surface([], pin: :adaptive)
      bytes = raw(device)

      assert SealOracle.region_sets(bytes) == []

      rows_addressed = SealOracle.cup_rows(bytes, height: 20)
      assert rows_addressed != []
      # Everything the boot frame paints lives in the floating footer at
      # the TOP of the screen -- rows 15..20 (the pinned zone today)
      # stay untouched: no first-load void.
      assert Enum.max(rows_addressed) <= 6
    end

    test "the default boot is unchanged (pinned from the first byte)" do
      {_model, device} = new_surface([], [])
      assert SealOracle.region_sets(raw(device)) == [{1, 14}]
    end

    # One combined drive for the two emulator-replay properties (parity
    # with the pinned model + immutable prefix across the transition):
    # full-emulator replay is expensive, so the geometry is small (the
    # unit-test geometry: 12 rows, 4 footer rows, split at 8) and the
    # replays are shared. 5 turns seal 11 rows -- comfortably past the
    # 8-row floating capacity, so the run crosses the transition.
    @tag timeout: 300_000
    test "a full session crosses the transition once, seals identically to the pinned model, and every prefix stays immutable" do
      events = surface_events(5)
      small = [rows: @rows, footer_rows: @footer_rows]

      {adaptive_model, adaptive_device} =
        new_surface(events, small ++ [pin: :adaptive])

      {immediate_model, immediate_device} = new_surface(events, small)

      {prefixes, _model} =
        Enum.reduce_while(1..1000, {[], adaptive_model}, fn _n, {acc, m} ->
          case Surface.advance(m) do
            {m, :ok} -> {:cont, {[raw(adaptive_device) | acc], m}}
            {m, :done} -> {:halt, {[raw(adaptive_device) | acc], m}}
          end
        end)

      _immediate_model = drive_to_done(immediate_model)

      adaptive_bytes = raw(adaptive_device)
      immediate_bytes = raw(immediate_device)

      # The transition happened exactly once, to today's exact split.
      assert SealOracle.region_sets(adaptive_bytes) == [{1, @bottom}]

      # Independent oracle: replaying both byte streams yields the SAME
      # sealed history (scrollback + rows above the split), row for row.
      hw = fn bytes -> bytes |> :binary.matches("\r\n") |> length() end
      assert hw.(adaptive_bytes) == hw.(immediate_bytes)

      adaptive_history =
        history_texts(adaptive_bytes, @bottom, high_water: hw.(adaptive_bytes))

      immediate_history =
        history_texts(immediate_bytes, @bottom,
          high_water: hw.(immediate_bytes)
        )

      assert adaptive_history == immediate_history

      # Immutable prefix across the whole run: sample checkpoints
      # (prefixes are in reverse frame order, so take_every over the
      # reversed list walks the session start-to-end -- the floating
      # phase, the transition frame, and the pinned tail all land in
      # the sample).
      checkpoints =
        prefixes
        |> Enum.reverse()
        |> Enum.take_every(6)
        |> Kernel.++([List.first(prefixes)])

      for prefix <- checkpoints do
        history_k = history_texts(prefix, @bottom, high_water: hw.(prefix))

        assert SealOracle.immutable_prefix?(history_k, adaptive_history) == :ok
      end
    end
  end
end
