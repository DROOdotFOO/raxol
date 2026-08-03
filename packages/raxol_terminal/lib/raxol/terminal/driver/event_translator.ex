defmodule Raxol.Terminal.Driver.EventTranslator do
  @moduledoc """
  Translates termbox NIF events into Raxol.Core.Events.Event structs.

  ## Keycode source of truth

  `key_code` values below are the REAL `TB_KEY_*` constants vendored at
  `packages/raxol_terminal/lib/termbox2_nif/c_src/termbox2/termbox2.h`, not
  assumed. Two earlier bugs, found by review, are fixed here:

    * Arrow keys were mapped from 65/66/67/68 -- the ANSI CSI *final
      bytes* for `A`/`B`/`C`/`D` -- instead of the real
      `TB_KEY_ARROW_{UP,DOWN,LEFT,RIGHT}` values (`0xffff - {18,19,20,21}`
      = 65517/65516/65515/65514).
    * F1/F2 were mapped from 265/266 -- ncurses' `KEY_F(1)`/`KEY_F(2)`
      (`KEY_F0 + n`, `KEY_F0 = 264`) -- instead of the real `TB_KEY_F1`/
      `TB_KEY_F2` (`0xffff - {0,1}` = 65535/65534).

  Both bugs meant a REAL termbox event for an arrow key or F1/F2 would
  have normalized to `key: :unknown` while the ANSI parser
  (`input_parser.ex`) correctly produced `:up`/`:down`/.../`:f1`/`:f2` for
  the same physical keypress -- exactly the cross-shape divergence
  `Raxol.UI.Harness.InputEvent`'s normalizer is supposed to make
  impossible. See `@key_codes` below for the full corrected table
  (nav keys, F1-F12) plus the control-key-code handling for
  Enter/Tab/Escape/Backspace.

  Control keys (Enter/Tab/Escape/Backspace) share their numeric value with
  a plain ASCII control byte (`TB_KEY_ENTER = 0x0d`, same as a raw `\\r`).
  Since it is not settled by inspection alone whether a real termbox
  integration reports these via `char_code` (raw byte) or `key_code`
  (`TB_KEY_*` constant, numerically identical for these), `translate_key/3`
  checks BOTH: `char_code` is checked for a known control byte before the
  generic "printable char" branch (so a control byte can never leak
  through as `char:` on a `kind: :char` event), and `key_code` is checked
  against the same values as a fallback. Either wiring convention lands on
  the correct special-key atom.
  """

  alias Raxol.Core.Events.Event

  # Real TB_KEY_* values (see moduledoc). Control-key codes double as their
  # ASCII byte value (TB_KEY_ENTER clashes with CTRL_M, etc. -- see
  # termbox2.h's own "clash with" comments); nav/function key codes are
  # `0xffff - n` per the vendored header's codegen block.
  @key_codes %{
    # control keys -- checked against BOTH char_code and key_code (see
    # moduledoc); LF (10) is treated as Enter same as input_parser.ex does.
    8 => :backspace,
    127 => :backspace,
    9 => :tab,
    13 => :enter,
    10 => :enter,
    27 => :escape,
    # arrows: TB_KEY_ARROW_{UP,DOWN,LEFT,RIGHT} = 0xffff - {18,19,20,21}
    65517 => :up,
    65516 => :down,
    65515 => :left,
    65514 => :right,
    # nav: TB_KEY_{HOME,END,INSERT,DELETE,PGUP,PGDN} = 0xffff - {14,15,12,13,16,17}
    65521 => :home,
    65520 => :end,
    65523 => :insert,
    65522 => :delete,
    65519 => :page_up,
    65518 => :page_down,
    # F1-F12: TB_KEY_F1..F12 = 0xffff - {0..11}
    65535 => :f1,
    65534 => :f2,
    65533 => :f3,
    65532 => :f4,
    65531 => :f5,
    65530 => :f6,
    65529 => :f7,
    65528 => :f8,
    65527 => :f9,
    65526 => :f10,
    65525 => :f11,
    65524 => :f12
  }

  # TB_KEY_BACK_TAB = 0xffff - 22. termbox reports Shift+Tab as this
  # distinct key rather than TAB + a shift modifier bit; recover the shift
  # bit here so shift+tab normalizes identically to input_parser.ex's CSI
  # `Z` handling (`key_event(:tab, shift: true)`).
  @back_tab_code 65_535 - 22

  @doc """
  Translates a termbox event map into an Event struct.
  Returns {:ok, event}, :ignore, or {:error, reason}.
  """
  def translate(event_map) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           translate_event_map(event_map)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_event_map(%{
         type: :key,
         key: key_code,
         char: char_code,
         mod: mod_code
       }) do
    translated_key = translate_key(key_code, char_code, mod_code)
    {:ok, %Event{type: :key, data: translated_key}}
  end

  defp translate_event_map(%{type: :resize, width: w, height: h}) do
    {:ok, %Event{type: :resize, data: %{width: w, height: h}}}
  end

  defp translate_event_map(%{type: :mouse, x: x, y: y, button: btn_code}) do
    translated_button = translate_mouse_button(btn_code)
    {:ok, %Event{type: :mouse, data: %{x: x, y: y, button: translated_button}}}
  end

  defp translate_event_map(_other), do: :ignore

  defp translate_key(key_code, char_code, mod_code) do
    shift = Bitwise.&&&(mod_code, 1) != 0
    ctrl = Bitwise.&&&(mod_code, 2) != 0
    alt = Bitwise.&&&(mod_code, 4) != 0
    meta = Bitwise.&&&(mod_code, 8) != 0

    data = %{
      shift: shift,
      ctrl: ctrl,
      alt: alt,
      meta: meta,
      char: nil,
      key: nil
    }

    translate_key_or_char(data, char_code, key_code)
  end

  # Control byte arriving via char_code (see moduledoc): resolve it to the
  # special-key atom BEFORE the generic char_code > 0 branch below, so a
  # control byte can never leak through as `char:` on a `kind: :char`
  # event no matter which field the eventual real wiring populates it in.
  defp translate_key_or_char(data, char_code, _key_code)
       when is_map_key(@key_codes, char_code) and char_code > 0 do
    Map.put(data, :key, Map.fetch!(@key_codes, char_code))
  end

  defp translate_key_or_char(data, char_code, _key_code) when char_code > 0 do
    Map.put(data, :char, <<char_code::utf8>>)
  end

  defp translate_key_or_char(data, _char_code, @back_tab_code) do
    data |> Map.put(:key, :tab) |> Map.put(:shift, true)
  end

  defp translate_key_or_char(data, _char_code, key_code) do
    Map.put(data, :key, Map.get(@key_codes, key_code, :unknown))
  end

  defp translate_mouse_button(btn_code) do
    case btn_code do
      0 -> :left
      1 -> :right
      2 -> :middle
      3 -> :wheel_up
      4 -> :wheel_down
      _ -> :unknown
    end
  end
end
