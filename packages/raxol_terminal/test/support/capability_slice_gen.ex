defmodule Raxol.Test.CapabilitySliceGen do
  @moduledoc """
  Deterministic seeded generators for the T1 capability fuzz suite
  (CAP-F-*, 04 design §4).

  raxol_terminal does not depend on `stream_data` (and the package
  `mix.exs` is outside the T1 write-set), so the fuzz properties are
  driven by an explicit seeded PRNG: same properties, same generator
  shapes (`G-noise`, `G-reply`, `G-interleave`), fully reproducible runs.
  Each iteration seeds `:rand` with `{@seed_a, @seed_b, i}` so a failure
  reports the exact iteration to replay.
  """

  @seed_a 1337
  @seed_b 424_242

  @doc "Seeds the PRNG for iteration `i` (call at the top of each run)."
  def seed(i), do: :rand.seed(:exsss, {@seed_a, @seed_b, i})

  @doc "G-noise: arbitrary bytes, length 0..max."
  def noise(max_len \\ 128) do
    len = :rand.uniform(max_len + 1) - 1
    for _ <- 1..len//1, into: <<>>, do: <<:rand.uniform(256) - 1>>
  end

  @doc "Printable keystroke run (0x20..0x7E -- never contains ESC)."
  def printable do
    len = :rand.uniform(12)
    for _ <- 1..len, into: <<>>, do: <<0x1F + :rand.uniform(0x5F)>>
  end

  @doc """
  G-reply: one well-formed reply from the bank. Returns `{bytes, tag}`.
  """
  def reply do
    case :rand.uniform(6) do
      1 -> decrqm()
      2 -> osc11()
      3 -> xtversion()
      4 -> da1()
      5 -> kitty_kbd()
      6 -> cpr()
    end
  end

  @doc "DECRQM reply: CSI ? <mode> ; <0..4> $ y."
  def decrqm do
    mode = Enum.random([2026, 2027, 2048, 69, 2031, :rand.uniform(9999)])
    value = :rand.uniform(5) - 1
    {"\e[?#{mode};#{value}$y", :decrqm}
  end

  @doc "OSC 11 color reply, BEL- or ST-terminated."
  def osc11 do
    hex = fn -> Enum.map_join(1..4, fn _ -> Enum.random(~w(0 4 8 a f)) end) end

    {"\e]11;rgb:#{hex.()}/#{hex.()}/#{hex.()}" <> terminator(), :osc11}
  end

  @doc "XTVERSION DCS reply."
  def xtversion do
    name = Enum.random(~w(kitty WezTerm ghostty Alacritty iTerm2 VTE))
    {"\eP>|#{name}(#{:rand.uniform(99)}.#{:rand.uniform(99)})" <> "\e\\", :xtversion}
  end

  @doc "DA1 reply (the sentinel)."
  def da1 do
    attrs = Enum.take_random([1, 2, 4, 6, 9, 15, 18, 21, 22], :rand.uniform(4))
    {"\e[?#{Enum.join([62 | attrs], ";")}c", :da1}
  end

  @doc "Kitty keyboard flags reply."
  def kitty_kbd, do: {"\e[?#{:rand.uniform(31)}u", :kitty_kbd}

  @doc """
  Cursor position report. Row is always >= 2: `CSI 1 ; <n> R` is
  wire-ambiguous with xterm's modified-F3 key encoding, which is exactly
  why the ReplyScanner consumes CPR before the key parser ever sees it.
  """
  def cpr, do: {"\e[#{1 + :rand.uniform(59)};#{:rand.uniform(200)}R", :cpr}

  defp terminator, do: Enum.random(["\a", "\e\\"])

  @doc """
  G-interleave: replies interleaved with printable keystrokes. Returns
  `{full_binary, expected_leak_free}` -- the leak is exactly the
  concatenated keystroke segments; every reply (CPR included) is
  consumed by the scanner.
  """
  def interleave do
    segments =
      for _ <- 1..:rand.uniform(8) do
        if :rand.uniform(2) == 1 do
          {:keys, printable()}
        else
          {bytes, kind} = reply()
          {kind, bytes}
        end
      end

    full = Enum.map_join(segments, fn {_kind, bytes} -> bytes end)

    expected_leak =
      segments
      |> Enum.filter(fn {kind, _} -> kind == :keys end)
      |> Enum.map_join(fn {_kind, bytes} -> bytes end)

    {full, expected_leak}
  end
end
