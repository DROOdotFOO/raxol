defmodule Raxol.Terminal.Capabilities.ReplyScanner do
  @moduledoc """
  Pure reply scanner: raw input chunk in, `{parsed_replies_acc,
  leak_free_residual}` out (test-suite design 04 §1a).

  Generalizes `Raxol.Terminal.Driver.BackgroundQuery.scan/1` to all F0 §3
  reply framings. Replies are classified **by grammar and echoed
  parameters** (`?2026` in `CSI ? 2026 ; 1 $ y`), never by position.

  Invariants (pinned by the CAP-F fuzz suite):

    * **Conservation** -- every input byte is either consumed as a
      recognized reply/control frame or returned in `leak_free`, in the
      original order. User keystrokes are never eaten; reply bytes never
      leak to the key parser.
    * **Both terminators** -- OSC/DCS/APC close on BEL (`0x07`) *or* ST
      (`ESC \\`).
    * **Chunk-split invariance** -- a chunk ending mid-reply parks the
      fragment in `partial`; the next `scan/2` resumes byte-identically.

  The scanner is a pure function; it has no process, no clock, and no
  side effects. The driver-facing shim (`BackgroundQuery`) and the probe
  reducer (`Probe`) compose it.
  """

  alias Raxol.Terminal.Driver.BackgroundQuery

  @type mode_value :: integer() | nil

  @type t :: %__MODULE__{
          osc11: {:ok, BackgroundQuery.rgb()} | {:invalid, binary()} | nil,
          kitty_kbd: non_neg_integer() | nil,
          mode: %{optional(non_neg_integer()) => mode_value()},
          xtversion: {String.t(), String.t() | nil} | nil,
          xtversion_raw: String.t() | nil,
          xtgettcap: %{optional(String.t()) => String.t() | true},
          da1: [non_neg_integer()] | nil,
          da2: [non_neg_integer()] | nil,
          cpr: {pos_integer(), pos_integer()} | nil,
          cell_px: {pos_integer(), pos_integer()} | nil,
          sixel_regs: non_neg_integer() | nil,
          kitty_graphics: boolean() | nil,
          sentinel_seen?: boolean(),
          partial: binary()
        }

  defstruct osc11: nil,
            kitty_kbd: nil,
            mode: %{},
            xtversion: nil,
            xtversion_raw: nil,
            xtgettcap: %{},
            da1: nil,
            da2: nil,
            cpr: nil,
            cell_px: nil,
            sixel_regs: nil,
            kitty_graphics: nil,
            sentinel_seen?: false,
            partial: <<>>

  @doc "Fresh scanner accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Scans a raw input chunk, resuming from any parked partial reply.

  Returns `{acc, leak_free}` where `leak_free` is safe to hand to the
  key-event parser.
  """
  @spec scan(binary(), t()) :: {t(), binary()}
  def scan(chunk, %__MODULE__{} = acc) when is_binary(chunk) do
    data = acc.partial <> chunk
    do_scan(data, %{acc | partial: <<>>}, [])
  end

  defp do_scan(<<>>, acc, leak), do: {acc, flush_leak(leak)}

  defp do_scan(<<0x1B, _::binary>> = data, acc, leak) do
    case match_reply(data) do
      {:reply, kind, payload, rest} ->
        do_scan(rest, absorb(acc, kind, payload), leak)

      {:drain, rest} ->
        do_scan(rest, acc, leak)

      :partial ->
        {%{acc | partial: data}, flush_leak(leak)}

      {:leak, n} ->
        <<leaked::binary-size(^n), rest::binary>> = data
        do_scan(rest, acc, [leaked | leak])
    end
  end

  defp do_scan(<<byte, rest::binary>>, acc, leak) do
    do_scan(rest, acc, [<<byte>> | leak])
  end

  defp flush_leak(leak), do: leak |> Enum.reverse() |> IO.iodata_to_binary()

  # ---- grammar dispatch (by opening framing) ----

  defp match_reply(<<0x1B>>), do: :partial
  defp match_reply(<<0x1B, ?], rest::binary>>), do: match_osc(rest)
  defp match_reply(<<0x1B, ?P, rest::binary>>), do: match_string(rest, :dcs)
  defp match_reply(<<0x1B, ?_, rest::binary>>), do: match_string(rest, :apc)
  defp match_reply(<<0x1B, ?[, rest::binary>>), do: match_csi(rest)
  # ESC followed by anything else (Alt+key, SS3, ...) is input: leak the
  # ESC byte alone; the loop leaks the following bytes individually, so
  # the concatenated leak_free is byte-identical to the input.
  defp match_reply(_data), do: {:leak, 1}

  # ---- CSI replies: ESC [ <marker?> <params> <intermediates?> <final> ----

  defp match_csi(rest) do
    case take_csi_body(rest, [], []) do
      :partial -> :partial
      :abort -> {:leak, 1}
      {body, final, after_seq} -> classify_csi(body, final, after_seq, rest)
    end
  end

  # Walk the CSI body: params 0x30-0x3F, intermediates 0x20-0x2F,
  # final 0x40-0x7E. Any other byte aborts (stray ESC / control byte).
  defp take_csi_body(<<>>, _body, _inter), do: :partial

  defp take_csi_body(<<byte, rest::binary>>, body, inter)
       when byte in 0x30..0x3F do
    take_csi_body(rest, [byte | body], inter)
  end

  defp take_csi_body(<<byte, rest::binary>>, body, inter)
       when byte in 0x20..0x2F do
    take_csi_body(rest, body, [byte | inter])
  end

  defp take_csi_body(<<final, rest::binary>>, body, inter)
       when final in 0x40..0x7E do
    {%{
       raw: body |> Enum.reverse() |> :erlang.list_to_binary(),
       intermediates: inter |> Enum.reverse() |> :erlang.list_to_binary()
     }, final, rest}
  end

  defp take_csi_body(<<_other, _::binary>>, _body, _inter), do: :abort

  defp classify_csi(%{raw: raw, intermediates: inter}, final, rest, whole) do
    marker_and_params = split_marker(raw)

    case {marker_and_params, inter, final} do
      # DECRQM reply: CSI ? <mode> ; <value> $ y
      {{"?", params}, "$", ?y} ->
        {:reply, :decrqm, parse_decrqm_params(params), rest}

      # our own DECRQM *query* echoed back verbatim: CSI ? <mode> $ p --
      # recognized as a non-reply, drained (CAP-N-07)
      {{"?", _params}, "$", ?p} ->
        {:drain, rest}

      # DA1 reply (THE sentinel): CSI ? <params> c
      {{"?", params}, "", ?c} ->
        {:reply, :da1, parse_int_params(params), rest}

      # kitty keyboard flags reply: CSI ? <flags> u  (a bare echoed
      # "CSI ? u" query carries no digits and is drained, not a reply)
      {{"?", params}, "", ?u} ->
        if params =~ ~r/\d/ do
          {:reply, :kitty_kbd, params |> parse_int_params() |> List.first(0), rest}
        else
          {:drain, rest}
        end

      # XTSMGRAPHICS reply: CSI ? <Pi> ; <Ps> ; <Pv> S
      {{"?", params}, "", ?S} ->
        {:reply, :xtsmgraphics, parse_int_params(params), rest}

      # DA2 reply: CSI > <params> c
      {{">", params}, "", ?c} ->
        {:reply, :da2, parse_int_params(params), rest}

      # cursor position report: CSI <row> ; <col> R. Consumed here
      # because CPR is wire-ambiguous with xterm's modified-F3 key
      # encoding (CSI 1 ; mod R): during a probe window the reply must
      # be stripped before it can masquerade as a keypress.
      {{"", params}, "", ?R} ->
        case parse_int_params(params) do
          [row, col] -> {:reply, :cpr, {row, col}, rest}
          _ -> leak_whole(whole, rest)
        end

      # window/cell-size report: CSI 4|6|8 ; <h> ; <w> t
      {{"", params}, "", ?t} ->
        case parse_int_params(params) do
          [kind | _] = ints when kind in [4, 6, 8] ->
            {:reply, :size_report, ints, rest}

          _ ->
            leak_whole(whole, rest)
        end

      # anything else (arrow keys, mouse, focus, unknown) is input --
      # leak the whole sequence untouched for the key parser
      _ ->
        leak_whole(whole, rest)
    end
  end

  # leak "ESC [" + everything up to and including the final byte
  defp leak_whole(body_and_rest, rest) do
    {:leak, 2 + byte_size(body_and_rest) - byte_size(rest)}
  end

  defp split_marker(<<marker, params::binary>>) when marker in ~c"<=>?" do
    {<<marker>>, params}
  end

  defp split_marker(params), do: {"", params}

  defp parse_decrqm_params(params) do
    case String.split(params, ";") do
      [mode] -> {to_int(mode, nil), nil}
      [mode, value | _] -> {to_int(mode, nil), to_int(value, nil)}
    end
  end

  defp parse_int_params(""), do: []

  defp parse_int_params(params) do
    params
    |> String.split(";")
    |> Enum.map(&to_int(&1, 0))
  end

  defp to_int(s, default) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> default
    end
  end

  # ---- OSC replies: ESC ] <payload> (BEL | ST) ----

  defp match_osc(rest) do
    case take_string_body(rest, []) do
      :partial ->
        :partial

      :abort ->
        {:leak, 1}

      {payload, after_seq} ->
        case payload do
          "11;" <> color -> {:reply, :osc11, color, after_seq}
          _ -> {:drain, after_seq}
        end
    end
  end

  # ---- DCS / APC replies: ESC P|_ <payload> (ST | BEL) ----

  defp match_string(rest, kind) do
    case take_string_body(rest, []) do
      :partial -> :partial
      :abort -> {:leak, 1}
      {payload, after_seq} -> classify_string(kind, payload, after_seq)
    end
  end

  defp classify_string(:dcs, ">|" <> version, rest),
    do: {:reply, :xtversion, version, rest}

  defp classify_string(:dcs, "1+r" <> pairs, rest),
    do: {:reply, :xtgettcap, {:ok, pairs}, rest}

  defp classify_string(:dcs, "0+r" <> _, rest),
    do: {:reply, :xtgettcap, :invalid, rest}

  defp classify_string(:dcs, _payload, rest), do: {:drain, rest}

  defp classify_string(:apc, "G" <> body, rest),
    do: {:reply, :kitty_graphics, String.contains?(body, ";OK"), rest}

  defp classify_string(:apc, _payload, rest), do: {:drain, rest}

  # Collect a string-frame body up to BEL or ST. A stray ESC not followed
  # by `\\` aborts; ESC as the last byte stays :partial (could become ST).
  defp take_string_body(<<>>, _seen), do: :partial
  defp take_string_body(<<0x07, rest::binary>>, seen), do: finish(seen, rest)

  defp take_string_body(<<0x1B, ?\\, rest::binary>>, seen),
    do: finish(seen, rest)

  defp take_string_body(<<0x1B>>, _seen), do: :partial
  defp take_string_body(<<0x1B, _, _::binary>>, _seen), do: :abort

  defp take_string_body(<<byte, rest::binary>>, seen),
    do: take_string_body(rest, [byte | seen])

  defp finish(seen, rest),
    do: {seen |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  # ---- absorb parsed replies into the accumulator ----

  defp absorb(acc, :decrqm, {nil, _value}), do: acc

  defp absorb(acc, :decrqm, {mode, value}),
    do: %{acc | mode: Map.put(acc.mode, mode, value)}

  defp absorb(acc, :da1, params),
    do: %{acc | da1: params, sentinel_seen?: true}

  defp absorb(acc, :da2, params), do: %{acc | da2: params}

  defp absorb(acc, :cpr, {row, col}), do: %{acc | cpr: {row, col}}

  defp absorb(acc, :kitty_kbd, flags), do: %{acc | kitty_kbd: flags}

  defp absorb(acc, :xtsmgraphics, [1, 0, regs | _]),
    do: %{acc | sixel_regs: regs}

  defp absorb(acc, :xtsmgraphics, _params), do: acc

  defp absorb(acc, :size_report, [6, h, w | _]) when h > 0 and w > 0,
    do: %{acc | cell_px: {w, h}}

  defp absorb(acc, :size_report, _params), do: acc

  defp absorb(acc, :osc11, color) do
    case BackgroundQuery.parse_color(color) do
      {:ok, rgb} -> %{acc | osc11: {:ok, rgb}}
      :error -> %{acc | osc11: {:invalid, color}}
    end
  end

  defp absorb(acc, :xtversion, version) do
    %{acc | xtversion_raw: version, xtversion: parse_identity(version)}
  end

  defp absorb(acc, :xtgettcap, {:ok, pairs}) do
    %{acc | xtgettcap: Map.merge(acc.xtgettcap, decode_tcap_pairs(pairs))}
  end

  defp absorb(acc, :xtgettcap, :invalid), do: acc

  defp absorb(acc, :kitty_graphics, ok?), do: %{acc | kitty_graphics: ok?}

  # ---- XTVERSION identity: "kitty(0.32.2)" | "iTerm2 3.5.0" | "name" ----

  defp parse_identity(raw) do
    trimmed = String.trim(raw)

    case Regex.run(~r/^(.+?)\(([^)]*)\)$/, trimmed) do
      [_, name, version] ->
        {String.trim(name), version}

      nil ->
        case String.split(trimmed, " ", parts: 2) do
          [name, version] -> {name, version}
          [name] -> {name, nil}
        end
    end
  end

  # ---- XTGETTCAP payload: hex(name)=hex(value) pairs joined by ';' ----

  defp decode_tcap_pairs(pairs) do
    pairs
    |> String.split(";")
    |> Enum.reduce(%{}, fn pair, out ->
      case String.split(pair, "=", parts: 2) do
        [name_hex, value_hex] ->
          with {:ok, name} <- decode_hex(name_hex),
               {:ok, value} <- decode_hex(value_hex) do
            Map.put(out, name, value)
          else
            _ -> out
          end

        [name_hex] ->
          case decode_hex(name_hex) do
            {:ok, name} -> Map.put(out, name, true)
            _ -> out
          end
      end
    end)
  end

  defp decode_hex(hex) do
    Base.decode16(hex, case: :mixed)
  end
end
