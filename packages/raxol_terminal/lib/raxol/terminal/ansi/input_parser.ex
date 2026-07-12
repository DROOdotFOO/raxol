defmodule Raxol.Terminal.ANSI.InputParser do
  @moduledoc """
  Parses raw ANSI terminal input bytes into Raxol Event structs.

  Handles:
  - Arrow keys, Enter, Backspace, Tab, Escape
  - Function keys F1-F12 (SS3 and CSI variants)
  - Navigation keys (Home, End, Insert, Delete, PageUp, PageDown)
  - Modifier combos (Shift+Tab, Ctrl+Arrow, Alt+key, etc.)
  - Ctrl+A through Ctrl+Z
  - Mouse SGR and X10/normal mode events
  - Focus in/out events
  - Bracketed paste
  - Printable ASCII and UTF-8 characters
  """

  alias Raxol.Core.Events.Event

  import Bitwise

  @doc """
  Parses a binary of raw terminal input into a list of Event structs.

  Returns a list because a single read may contain multiple events
  (e.g., pasted text or buffered input).
  """
  @spec parse(binary()) :: [Event.t()]
  def parse(data) when is_binary(data), do: parse_loop(data, [])

  defp parse_loop(<<>>, acc), do: Enum.reverse(acc)

  defp parse_loop(data, acc) do
    case parse_one(data) do
      {nil, <<>>} ->
        Enum.reverse(acc)

      {:consumed, rest} ->
        # A well-formed sequence with no event mapping (secondary DA reply,
        # CPR, DECRQM response, ...) was consumed whole. Emit nothing.
        parse_loop(rest, acc)

      {nil, _rest} ->
        # Unrecognized byte -- skip it and continue
        <<_, rest::binary>> = data
        parse_loop(rest, acc)

      {event, rest} ->
        parse_loop(rest, [event | acc])
    end
  end

  # --- parse_one/1: consume one event from the front, return {event, rest} ---

  # --- CSI sequences: ESC [ ... ---

  # Bracketed paste: ESC [ 200 ~
  defp parse_one(<<27, 91, 50, 48, 48, 126, rest::binary>>) do
    case :binary.split(rest, <<27, 91, 50, 48, 49, 126>>) do
      [pasted, remaining] ->
        {%Event{type: :paste, data: %{text: pasted}}, remaining}

      [_no_end] ->
        {%Event{type: :paste, data: %{text: rest}}, <<>>}
    end
  end

  # Mouse SGR mode: ESC [ < params M/m
  defp parse_one(<<27, 91, 60, rest::binary>>) do
    parse_sgr_mouse_one(rest)
  end

  # Mouse X10/normal mode: ESC [ M <3 bytes>
  defp parse_one(<<27, 91, 77, button, x, y, rest::binary>>) do
    {parse_x10_mouse_event(button, x, y), rest}
  end

  # Arrow keys
  defp parse_one(<<27, 91, 65, rest::binary>>), do: {key_event(:up), rest}
  defp parse_one(<<27, 91, 66, rest::binary>>), do: {key_event(:down), rest}
  defp parse_one(<<27, 91, 67, rest::binary>>), do: {key_event(:right), rest}
  defp parse_one(<<27, 91, 68, rest::binary>>), do: {key_event(:left), rest}

  # Navigation keys (CSI letter variants)
  defp parse_one(<<27, 91, 72, rest::binary>>), do: {key_event(:home), rest}
  defp parse_one(<<27, 91, 70, rest::binary>>), do: {key_event(:end), rest}

  # Shift+Tab (backtab)
  defp parse_one(<<27, 91, 90, rest::binary>>),
    do: {key_event(:tab, shift: true), rest}

  # Focus events
  defp parse_one(<<27, 91, 73, rest::binary>>),
    do: {%Event{type: :focus, data: %{focused: true}}, rest}

  defp parse_one(<<27, 91, 79, rest::binary>>),
    do: {%Event{type: :focus, data: %{focused: false}}, rest}

  # Modified keys: ESC [ 1 ; <mod> <letter>
  defp parse_one(<<27, 91, 49, 59, mod, letter, rest::binary>>)
       when letter in [65, 66, 67, 68, 70, 72, 80, 81, 82, 83] do
    {shift, alt, ctrl} = decode_modifier(mod - ?0)
    key = csi_letter_to_key(letter)
    {key_event(key, shift: shift, alt: alt, ctrl: ctrl), rest}
  end

  # CSI tilde/letter sequences: ESC [ <params...> <final>
  defp parse_one(<<27, 91, rest::binary>>) do
    parse_csi_tilde_one(rest)
  end

  # --- SS3 sequences: ESC O ... ---

  # F1-F4 SS3 variants
  defp parse_one(<<27, 79, 80, rest::binary>>), do: {key_event(:f1), rest}
  defp parse_one(<<27, 79, 81, rest::binary>>), do: {key_event(:f2), rest}
  defp parse_one(<<27, 79, 82, rest::binary>>), do: {key_event(:f3), rest}
  defp parse_one(<<27, 79, 83, rest::binary>>), do: {key_event(:f4), rest}

  # SS3 Home/End (some terminals)
  defp parse_one(<<27, 79, 72, rest::binary>>), do: {key_event(:home), rest}
  defp parse_one(<<27, 79, 70, rest::binary>>), do: {key_event(:end), rest}

  # --- Alt+key: ESC <char> (must come after ESC[ and ESC O) ---

  defp parse_one(<<27, char, rest::binary>>) when char >= 32 and char <= 126 do
    {key_event(:char, char: <<char>>, alt: true), rest}
  end

  # --- Bare escape ---
  defp parse_one(<<27>>), do: {key_event(:escape), <<>>}

  # --- Control characters ---
  # Enter (CR)
  defp parse_one(<<13, rest::binary>>), do: {key_event(:enter), rest}
  # Linefeed (LF) - also treat as enter
  defp parse_one(<<10, rest::binary>>), do: {key_event(:enter), rest}
  # Backspace
  defp parse_one(<<127, rest::binary>>), do: {key_event(:backspace), rest}
  # Tab
  defp parse_one(<<9, rest::binary>>), do: {key_event(:tab), rest}
  # Ctrl+Space / Null
  defp parse_one(<<0, rest::binary>>),
    do: {key_event(:char, char: " ", ctrl: true), rest}

  # Ctrl+A through Ctrl+Z (bytes 1-26, excluding special cases above)
  defp parse_one(<<byte, rest::binary>>) when byte >= 1 and byte <= 26 do
    char = <<byte + 96>>
    {key_event(:char, char: char, ctrl: true), rest}
  end

  # --- Printable ASCII ---
  defp parse_one(<<char, rest::binary>>) when char >= 32 and char <= 126 do
    {key_event(:char, char: <<char>>), rest}
  end

  # --- Multi-byte UTF-8 ---
  # 2-byte: 110xxxxx 10xxxxxx
  defp parse_one(<<a, b, rest::binary>>)
       when a >= 0xC0 and a <= 0xDF and b >= 0x80 and b <= 0xBF do
    {key_event(:char, char: <<a, b>>), rest}
  end

  # 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
  defp parse_one(<<a, b, c, rest::binary>>)
       when a >= 0xE0 and a <= 0xEF and b >= 0x80 and b <= 0xBF and
              c >= 0x80 and c <= 0xBF do
    {key_event(:char, char: <<a, b, c>>), rest}
  end

  # 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
  defp parse_one(<<a, b, c, d, rest::binary>>)
       when a >= 0xF0 and a <= 0xF7 and b >= 0x80 and b <= 0xBF and
              c >= 0x80 and c <= 0xBF and d >= 0x80 and d <= 0xBF do
    {key_event(:char, char: <<a, b, c, d>>), rest}
  end

  # --- Unrecognized ---
  defp parse_one(<<>>), do: {nil, <<>>}
  defp parse_one(_data), do: {nil, :skip}

  # --- CSI tilde sequence parser (returns {event, rest}) ---

  defp parse_csi_tilde_one(data) do
    case parse_csi_params(data) do
      {[n], ?~, rest} ->
        {key_event(tilde_key(n)), rest}

      {[n, mod], ?~, rest} ->
        {shift, alt, ctrl} = decode_modifier(mod)
        {key_event(tilde_key(n), shift: shift, alt: alt, ctrl: ctrl), rest}

      {[1, mod], letter, rest} when letter in [80, 81, 82, 83] ->
        {shift, alt, ctrl} = decode_modifier(mod)
        key = csi_letter_to_key(letter)
        {key_event(key, shift: shift, alt: alt, ctrl: ctrl), rest}

      {_params, final_byte, rest} when is_integer(final_byte) ->
        # Well-formed CSI sequence with no event mapping (secondary DA
        # reply, cursor position report, DECRQM response, ...). Consume it
        # whole -- {nil, data} would make parse_loop skip only the ESC and
        # re-parse the rest as printable char keys.
        {:consumed, rest}

      {_params, nil, <<>>} ->
        # Chunk ended mid-CSI (e.g. the input buffer flushed an incomplete
        # sequence after its timeout). Drop the fragment rather than leak
        # its bytes as char keys.
        {:consumed, <<>>}
    end
  end

  # Parse semicolon-separated numeric params ending with a final byte.
  # Returns {params, final_byte, rest}.
  defp parse_csi_params(data) do
    parse_csi_params(data, [], [])
  end

  defp parse_csi_params(<<byte, rest::binary>>, current_digits, params)
       when byte >= ?0 and byte <= ?9 do
    parse_csi_params(rest, [byte | current_digits], params)
  end

  defp parse_csi_params(<<?;, rest::binary>>, current_digits, params) do
    num = digits_to_integer(current_digits)
    parse_csi_params(rest, [], params ++ [num])
  end

  defp parse_csi_params(<<final_byte, rest::binary>>, current_digits, params)
       when final_byte >= 64 and final_byte <= 126 do
    num = digits_to_integer(current_digits)
    {params ++ [num], final_byte, rest}
  end

  defp parse_csi_params(<<>>, current_digits, params) do
    num = digits_to_integer(current_digits)
    {params ++ [num], nil, <<>>}
  end

  # Catch-all for CSI parameter/intermediate bytes with no special meaning
  # (private markers `<` `=` `>` `?` `:`, ECMA-48 intermediates 0x20-0x2F).
  # Without this clause, an unrecognized byte is a FunctionClauseError that
  # crashes the Driver GenServer. Skip it and keep scanning for the final
  # byte, keeping parsing total.
  defp parse_csi_params(<<_byte, rest::binary>>, current_digits, params) do
    parse_csi_params(rest, current_digits, params)
  end

  defp digits_to_integer([]), do: 0

  defp digits_to_integer(digits) do
    digits |> Enum.reverse() |> List.to_string() |> String.to_integer()
  end

  # Tilde key mapping
  defp tilde_key(1), do: :home
  defp tilde_key(2), do: :insert
  defp tilde_key(3), do: :delete
  defp tilde_key(4), do: :end
  defp tilde_key(5), do: :page_up
  defp tilde_key(6), do: :page_down
  defp tilde_key(11), do: :f1
  defp tilde_key(12), do: :f2
  defp tilde_key(13), do: :f3
  defp tilde_key(14), do: :f4
  defp tilde_key(15), do: :f5
  defp tilde_key(17), do: :f6
  defp tilde_key(18), do: :f7
  defp tilde_key(19), do: :f8
  defp tilde_key(20), do: :f9
  defp tilde_key(21), do: :f10
  defp tilde_key(23), do: :f11
  defp tilde_key(24), do: :f12
  defp tilde_key(_), do: :unknown

  # CSI letter to key mapping (catch-all kept intentionally for future CSI codes)
  @dialyzer {:nowarn_function, csi_letter_to_key: 1}
  defp csi_letter_to_key(65), do: :up
  defp csi_letter_to_key(66), do: :down
  defp csi_letter_to_key(67), do: :right
  defp csi_letter_to_key(68), do: :left
  defp csi_letter_to_key(70), do: :end
  defp csi_letter_to_key(72), do: :home
  defp csi_letter_to_key(80), do: :f1
  defp csi_letter_to_key(81), do: :f2
  defp csi_letter_to_key(82), do: :f3
  defp csi_letter_to_key(83), do: :f4
  defp csi_letter_to_key(_), do: :unknown

  # Decode xterm modifier parameter (mod-1 is bitmask: bit0=shift, bit1=alt, bit2=ctrl)
  defp decode_modifier(mod) when is_integer(mod) do
    bits = mod - 1
    shift = (bits &&& 1) != 0
    alt = (bits &&& 2) != 0
    ctrl = (bits &&& 4) != 0
    {shift, alt, ctrl}
  end

  # --- SGR mouse parsing (returns {event, rest}) ---

  defp parse_sgr_mouse_one(data) do
    case Regex.run(~r/^(\d+);(\d+);(\d+)([mM])/, data, return: :index) do
      [{0, full_len} | captures] ->
        [
          {bs, bl},
          {xs, xl},
          {ys, yl},
          {ks, _kl}
        ] = captures

        button_code =
          binary_part(data, bs, bl) |> String.to_integer()

        x = binary_part(data, xs, xl) |> String.to_integer()
        y = binary_part(data, ys, yl) |> String.to_integer()
        kind = binary_part(data, ks, 1)

        rest = binary_part(data, full_len, byte_size(data) - full_len)

        {button, motion} = decode_sgr_button(button_code)

        action =
          case {kind, motion} do
            {_, true} -> :move
            {"M", _} -> :press
            {"m", _} -> :release
          end

        {shift, alt, ctrl} = decode_sgr_modifiers(button_code)

        event = %Event{
          type: :mouse,
          data: %{
            button: button,
            x: x,
            y: y,
            action: action,
            shift: shift,
            alt: alt,
            ctrl: ctrl
          }
        }

        {event, rest}

      _ ->
        # Not a complete SGR mouse report (malformed or truncated after a
        # buffer flush). Consume through the final byte -- or drop the
        # fragment -- instead of leaking the bytes as char key events.
        case parse_csi_params(data) do
          {_params, final_byte, rest} when is_integer(final_byte) ->
            {:consumed, rest}

          _ ->
            {:consumed, <<>>}
        end
    end
  end

  defp decode_sgr_button(code) do
    motion = (code &&& 32) != 0
    base = code &&& 0x03

    button =
      cond do
        (code &&& 64) != 0 and base == 0 -> :wheel_up
        (code &&& 64) != 0 and base == 1 -> :wheel_down
        (code &&& 128) != 0 -> :extra
        base == 0 -> :left
        base == 1 -> :middle
        base == 2 -> :right
        base == 3 -> :release
        true -> :unknown
      end

    {button, motion}
  end

  defp decode_sgr_modifiers(code) do
    shift = (code &&& 4) != 0
    alt = (code &&& 8) != 0
    ctrl = (code &&& 16) != 0
    {shift, alt, ctrl}
  end

  # --- X10/normal mouse event ---

  defp parse_x10_mouse_event(button_byte, x_byte, y_byte) do
    button_code = button_byte - 32
    x = x_byte - 32
    y = y_byte - 32

    {button, motion} = decode_sgr_button(button_code)

    action =
      case motion do
        true -> :move
        false -> :press
      end

    %Event{
      type: :mouse,
      data: %{
        button: button,
        x: x,
        y: y,
        action: action
      }
    }
  end

  # --- Event constructors ---

  defp key_event(key, opts \\ []) do
    data =
      %{key: key}
      |> maybe_put(:char, Keyword.get(opts, :char))
      |> maybe_put_bool(:shift, Keyword.get(opts, :shift, false))
      |> maybe_put_bool(:alt, Keyword.get(opts, :alt, false))
      |> maybe_put_bool(:ctrl, Keyword.get(opts, :ctrl, false))

    %Event{type: :key, data: data}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bool(map, _key, false), do: map
  defp maybe_put_bool(map, key, true), do: Map.put(map, key, true)
end
