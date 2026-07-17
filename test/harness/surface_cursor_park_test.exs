defmodule Raxol.Harness.SurfaceCursorParkTest do
  @moduledoc """
  Byte-level pins for the composer cursor-park protocol (the live-demo
  defect: a blinking box parked at (1,1) for the whole session).

  Root cause being pinned: `ScrollRegionManager.start/3`'s DECSTBM set
  homes the terminal cursor to (1,1) (a documented VT100 side effect --
  see that module's moduledoc), and every subsequent paint runs inside
  `InlineAuthority.with_cursor/3`'s `\\e7`/`\\e8` save/restore bracket --
  which faithfully RESTORES the cursor to that home position, forever.
  Nothing ever parked the visible cursor anywhere meaningful.

  The protocol these tests pin:

    * after every footer paint that emits rows, the paint tail is a CUP
      to the composer's edit point (end of the typed draft), optionally
      followed by a cursor-show when the paint was a hidden burst;
    * a multi-row repaint burst is wrapped in `\\e[?25l` ... `\\e[?25h`
      (cursor hidden while rows are rewritten) -- UNLESS the frame is
      already inside a DEC 2026 synchronized-update bracket, which makes
      intermediate states invisible without hiding (verified: the two
      shipped demos run with `capabilities: nil`, so 2026 is inactive
      there and the hide path is the one they exercise);
    * a frame that changes nothing and moves no park emits zero bytes
      (the substrate's pinned no-op property, unchanged);
    * `repaint/2`-arity callers (no `:cursor` opt) get byte-identical
      behavior to before -- the park is strictly opt-in.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Capabilities
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # Footer layout for an empty session at this geometry: the status
  # strip yields to silence at boot (nothing true to say yet -- see
  # `Surface`'s strip-visibility gate), so the composer's chevron row IS
  # the first footer row.
  @composer_row @region_top + 1

  # The chevron prefix ("❯ ") shifts every draft column right by two
  # cells; the park col for an empty draft is therefore 3, not 1.
  @sigil_cols 2

  @hide "\e[?25l"
  @show "\e[?25h"

  defp cup(row, col), do: "\e[#{row};#{col}H"

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp delta(device, prior_size) do
    all = raw(device)
    binary_part(all, prior_size, byte_size(all) - prior_size)
  end

  defp new_model(opts \\ []) do
    {:ok, device} = StringIO.open("")

    defaults = [
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log
    ]

    model = Surface.new([], Keyword.merge(defaults, opts))
    {model, device}
  end

  # The paint tail contract: ends with the park CUP, optionally followed
  # by the burst's trailing cursor-show.
  defp assert_parked_at(bytes, row, col) do
    expected = cup(row, col)

    assert String.ends_with?(bytes, expected) or
             String.ends_with?(bytes, expected <> @show),
           "paint tail does not end with the park CUP #{inspect(expected)} " <>
             "(optionally + cursor-show): tail was " <>
             inspect(
               binary_part(
                 bytes,
                 max(byte_size(bytes) - 40, 0),
                 min(byte_size(bytes), 40)
               )
             )
  end

  describe "the park protocol through Surface (the live-demo defect)" do
    test "the initial paint parks the cursor at the composer's edit point, not (1,1)" do
      {_model, device} = new_model()
      bytes = raw(device)

      assert_parked_at(bytes, @composer_row, @sigil_cols + 1)
    end

    test "typing advances the parked column to the end of the draft" do
      {model, device} = new_model()

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, Event.key("h"))
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 2)

      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, Event.key("i"))
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 3)
    end

    test "typing a space advances the park too (the spacebar defect)" do
      # A space is invisible: the parked cursor advancing is the ONLY
      # visible feedback for typing one. The word-wrapper trims trailing
      # whitespace from the visual line, so this pins the edit point's
      # logical-draft compensation end-to-end through the paint path.
      {model, device} = new_model()

      model =
        InputParser.parse("ab")
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      prior = byte_size(raw(device))
      [space] = InputParser.parse(" ")
      model = Surface.handle_input(model, space)
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 4)

      prior = byte_size(raw(device))
      [space] = InputParser.parse(" ")
      _model = Surface.handle_input(model, space)
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 5)
    end

    test "a real ANSI backspace moves the park back with the draft" do
      {model, device} = new_model()

      model =
        InputParser.parse("hi")
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      prior = byte_size(raw(device))
      [backspace] = InputParser.parse(<<127>>)
      _model = Surface.handle_input(model, backspace)

      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 2)
    end

    test "a multi-row repaint burst hides the cursor and re-shows it after the park" do
      # The charged-minimum boot frame is a SINGLE content row (chevron
      # composer; strip and hint gone), so construction no longer bursts.
      # A lane notice appearing above the composer rewrites two rows in
      # one frame -- that IS a burst, and with no 2026 capability it must
      # be wrapped in hide ... park-CUP + show.
      {model, device} = new_model()

      prior = byte_size(raw(device))
      _model = Surface.put_lane_notice(model, "» reconnecting to session")
      bytes = delta(device, prior)

      assert bytes =~ @hide,
             "multi-row lane-notice repaint did not hide the cursor"

      assert String.ends_with?(
               bytes,
               cup(@region_top + 2, @sigil_cols + 1) <> @show
             ),
             "burst tail must be park CUP then cursor-show"
    end

    test "a leading-space draft parks honestly through backspace (V's field repro)" do
      {model, device} = new_model()

      model =
        [" ", "a", "b"]
        |> Enum.flat_map(&InputParser.parse/1)
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      # " ab" = 3 cells -> park one past its end.
      assert_parked_at(raw(device), @composer_row, @sigil_cols + 4)

      [backspace] = InputParser.parse(<<127>>)

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, backspace)
      assert Raxol.UI.Components.Harness.Composer.value(model.composer) == " a"
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 3)

      # The second backspace deletes the 'a', never the leading space.
      prior = byte_size(raw(device))
      model = Surface.handle_input(model, backspace)
      assert Raxol.UI.Components.Harness.Composer.value(model.composer) == " "
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 2)
    end

    test "a mid-draft left arrow parks the cursor inside the draft" do
      {model, device} = new_model()

      model =
        InputParser.parse("ab")
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      [left] = InputParser.parse("\e[D")

      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, left)

      # Cursor now sits between 'a' and 'b' -> cell 1 -> col 2.
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 2)
    end

    test "a readline word-left (Alt+Left) parks at the word start" do
      {model, device} = new_model()

      model =
        InputParser.parse("foo bar")
        |> Enum.reduce(model, &Surface.handle_input(&2, &1))

      # Alt+Left over the raw-ANSI wire: CSI 1;3D.
      [alt_left] = InputParser.parse("\e[1;3D")

      prior = byte_size(raw(device))
      model = Surface.handle_input(model, alt_left)

      # Cursor jumps to the start of "bar" (logical col 4) -> park col 5.
      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 5)

      # Ctrl+W with the cursor before "bar" deletes everything back to the
      # line start ("foo "), leaving "bar"; the park follows to col 1.
      [ctrl_w] = InputParser.parse(<<0x17>>)
      prior = byte_size(raw(device))
      model = Surface.handle_input(model, ctrl_w)

      assert Raxol.UI.Components.Harness.Composer.value(model.composer) ==
               "bar"

      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 1)
    end

    test "a wide grapheme (CJK) advances the park by two cells" do
      {model, device} = new_model()

      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, Event.key("你"))

      assert_parked_at(delta(device, prior), @composer_row, @sigil_cols + 3)
    end

    test "a no-op input frame emits zero bytes (park included)" do
      {model, device} = new_model()

      # Up with no history and cursor already at row 0 changes neither the
      # footer content nor the edit point.
      prior = byte_size(raw(device))
      _model = Surface.handle_input(model, Event.key(:up))

      assert delta(device, prior) == "",
             "an input frame that changed nothing must stay byte-free"
    end
  end

  describe "InlineAuthority park/burst mechanics" do
    defp new_authority(opts \\ []) do
      {:ok, device} = StringIO.open("")
      caps = Keyword.get(opts, :capabilities)

      authority =
        InlineAuthority.new(device, @width, @rows, @footer_rows,
          capabilities: caps
        )

      {authority, device}
    end

    test "cursor-less repaint (2-arity callers) is byte-identical to before: no park, no hide/show" do
      {authority, device} = new_authority()
      prior = byte_size(raw(device))

      _authority = InlineAuthority.repaint(authority, ["a", "b"])
      bytes = delta(device, prior)

      refute bytes =~ @hide
      refute bytes =~ @show
      assert String.ends_with?(bytes, "\e8")
    end

    test "a single-row diff with a cursor parks without hiding" do
      {authority, device} = new_authority()
      authority = InlineAuthority.repaint(authority, ["a", "b"])

      prior = byte_size(raw(device))

      _authority =
        InlineAuthority.repaint(authority, ["a", "c"], cursor: {1, 4})

      bytes = delta(device, prior)
      refute bytes =~ @hide
      assert String.ends_with?(bytes, cup(@region_top + 2, 4))
    end

    test "a park-only change (no row diff) emits just the CUP" do
      {authority, device} = new_authority()

      authority =
        InlineAuthority.repaint(authority, ["a", "b"], cursor: {1, 2})

      prior = byte_size(raw(device))

      _authority =
        InlineAuthority.repaint(authority, ["a", "b"], cursor: {1, 5})

      assert delta(device, prior) == cup(@region_top + 2, 5)
    end

    test "an unchanged frame with an unchanged park emits zero bytes" do
      {authority, device} = new_authority()

      authority =
        InlineAuthority.repaint(authority, ["a", "b"], cursor: {1, 2})

      prior = byte_size(raw(device))

      _authority =
        InlineAuthority.repaint(authority, ["a", "b"], cursor: {1, 2})

      assert delta(device, prior) == ""
    end

    test "inside an open DEC 2026 bracket, a burst does not hide/show (sync makes it unnecessary)" do
      caps = %Capabilities{sync_output: true}
      {authority, device} = new_authority(capabilities: caps)

      authority = InlineAuthority.sync_open(authority)
      prior = byte_size(raw(device))

      authority =
        InlineAuthority.keyframe(authority, ["x", "y", "z"], cursor: {1, 1})

      bytes = delta(device, prior)
      refute bytes =~ @hide
      refute bytes =~ @show
      assert String.ends_with?(bytes, cup(@region_top + 2, 1))

      _authority = InlineAuthority.sync_close(authority)
    end

    test "the park row is clamped inside the footer range" do
      {authority, device} = new_authority()
      prior = byte_size(raw(device))

      _authority =
        InlineAuthority.repaint(authority, ["a"], cursor: {99, 999})

      bytes = delta(device, prior)

      # Clamped to the footer's last row and the authority width.
      assert String.ends_with?(bytes, cup(@rows, @width)) or
               String.ends_with?(bytes, cup(@rows, @width) <> @show)
    end
  end
end
