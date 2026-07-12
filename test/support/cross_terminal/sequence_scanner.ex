defmodule Raxol.Test.CrossTerminal.SequenceScanner do
  @moduledoc """
  Minimal ANSI sequence linter. Scans a raw output byte stream, extracts
  escape sequences, classifies them, and checks them against a terminal
  capability profile.

  Purpose: assert that what Raxol *emits* stays within what a target
  terminal can *interpret* — without needing the terminal.
  """

  @type token ::
          {:csi, params :: String.t(), final :: String.t()}
          | {:osc, String.t()}
          | {:dcs, String.t()}
          | {:esc, String.t()}
          | {:text, String.t()}

  @doc "Tokenizes a binary into text runs and escape sequences."
  @spec scan(binary()) :: [token()]
  def scan(bytes) when is_binary(bytes), do: scan(bytes, [])

  defp scan(<<>>, acc), do: Enum.reverse(acc)

  defp scan(<<0x1B, ?[, rest::binary>>, acc) do
    {params, final, rest} = take_csi(rest, "")
    scan(rest, [{:csi, params, final} | acc])
  end

  defp scan(<<0x1B, ?], rest::binary>>, acc) do
    {body, rest} = take_until_st(rest, "")
    scan(rest, [{:osc, body} | acc])
  end

  defp scan(<<0x1B, ?P, rest::binary>>, acc) do
    {body, rest} = take_until_st(rest, "")
    scan(rest, [{:dcs, body} | acc])
  end

  defp scan(<<0x1B, char, rest::binary>>, acc) do
    scan(rest, [{:esc, <<char>>} | acc])
  end

  defp scan(bytes, acc) do
    case :binary.match(bytes, <<0x1B>>) do
      :nomatch ->
        scan(<<>>, [{:text, bytes} | acc])

      {pos, _} ->
        <<text::binary-size(^pos), rest::binary>> = bytes
        scan(rest, [{:text, text} | acc])
    end
  end

  defp take_csi(<<char, rest::binary>>, acc) when char in 0x40..0x7E do
    {acc, <<char>>, rest}
  end

  defp take_csi(<<char, rest::binary>>, acc),
    do: take_csi(rest, acc <> <<char>>)

  defp take_csi(<<>>, acc), do: {acc, "", <<>>}

  defp take_until_st(<<0x07, rest::binary>>, acc), do: {acc, rest}
  defp take_until_st(<<0x1B, ?\\, rest::binary>>, acc), do: {acc, rest}

  defp take_until_st(<<char, rest::binary>>, acc),
    do: take_until_st(rest, acc <> <<char>>)

  defp take_until_st(<<>>, acc), do: {acc, <<>>}

  @doc """
  Classifies a token into a capability requirement, or `:basic` when any
  VT100-era terminal handles it.
  """
  def capability({:csi, params, "m"}) do
    cond do
      String.contains?(params, "38;2;") or String.contains?(params, "48;2;") ->
        :truecolor

      String.contains?(params, "38;5;") or String.contains?(params, "48;5;") ->
        :color256

      true ->
        :basic
    end
  end

  def capability({:csi, "?" <> params, final}) when final in ["h", "l"] do
    modes = params |> String.split(";") |> Enum.map(&String.trim/1)

    cond do
      Enum.any?(modes, &(&1 in ~w(1000 1002 1003 1005 1006 1015))) -> :mouse
      "1049" in modes or "47" in modes -> :alt_screen
      "2004" in modes -> :bracketed_paste
      "2026" in modes -> :synchronized_output
      "25" in modes -> :basic
      true -> :private_mode
    end
  end

  def capability({:osc, "52;" <> _}), do: :osc52_clipboard
  def capability({:osc, _}), do: :osc
  def capability({:dcs, _}), do: :dcs
  def capability(_), do: :basic

  @profiles %{
    # Bare VT100/dumb-ish: no color extensions, no mouse, no modes beyond basics
    vt100: MapSet.new([:basic]),
    # xterm-256color without truecolor (Terminal.app)
    xterm_256color:
      MapSet.new([
        :basic,
        :color256,
        :mouse,
        :alt_screen,
        :bracketed_paste,
        :osc
      ]),
    # Modern terminal (iTerm2, kitty, WezTerm, Ghostty, Windows Terminal)
    modern:
      MapSet.new([
        :basic,
        :color256,
        :truecolor,
        :mouse,
        :alt_screen,
        :bracketed_paste,
        :synchronized_output,
        :osc,
        :osc52_clipboard,
        :dcs,
        :private_mode
      ])
  }

  @doc "Known capability profiles."
  def profiles, do: Map.keys(@profiles)

  @doc """
  Returns the list of `{token, capability}` violations: sequences in the
  stream that the given profile's terminal cannot interpret.
  """
  def violations(bytes, profile) when is_atom(profile) do
    allowed = Map.fetch!(@profiles, profile)

    bytes
    |> scan()
    |> Enum.map(&{&1, capability(&1)})
    |> Enum.reject(fn {_token, cap} -> MapSet.member?(allowed, cap) end)
  end
end
