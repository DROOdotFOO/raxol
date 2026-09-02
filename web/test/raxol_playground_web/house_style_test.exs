defmodule RaxolPlaygroundWeb.HouseStyleTest do
  @moduledoc """
  The rules a design audit found, held from inside the build.

  Each of these was a real defect on raxol.io, and each is the kind that comes
  back quietly: an em-dash in a demo label, a colour picked one rung too dim, a
  caption class reached for because it was the only tier below body. Reviewing
  for them again every time is how they get missed, so they are asserted.

  These check the SOURCE, not a rendered page. A LiveView render would cover
  more, but it would also only cover the routes someone remembered to list,
  and the defects being guarded here arrive in whatever component is written
  next. Grepping the tree catches those.
  """
  use ExUnit.Case, async: true

  @web_root Path.expand("../../lib", __DIR__)
  @css Path.expand("../../assets/css/app.css", __DIR__)
  @tailwind Path.expand("../../assets/tailwind.config.js", __DIR__)

  defp web_sources do
    Path.wildcard(Path.join(@web_root, "**/*.{ex,heex}"))
  end

  describe "punctuation" do
    # The rule is binary because "use sparingly" has never once held. It
    # applies to strings the page renders; a comment explaining an em-dash is
    # not itself a page.
    test "no em-dash or en-dash in any rendered string" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            String.match?(line, ~r/\x{2014}|\x{2013}/u),
            not comment_line?(line),
            do: "#{Path.relative_to(path, @web_root)}:#{n}: #{String.trim(line)}"

      assert offenders == [],
             "em/en dashes belong to no visible string on this site.\n" <>
               "Use a colon, a comma, or two sentences:\n  " <>
               Enum.join(offenders, "\n  ")
    end
  end

  describe "contrast floor" do
    # The pearl scale stops at 60 because that is where WCAG AA stops: 0.6
    # alpha over --obsidian is 5.96:1, 0.5 is 4.43:1. The playground used to
    # reach past it for a help button at 3.26:1 and a status message at 2.78:1.
    test "no text colour below the AA rung exists to be typed" do
      config = File.read!(@tailwind)
      rungs = Regex.scan(~r/^\s{10}(\d+): 'rgba\(232/m, config, capture: :all_but_first)
      below = for [n] <- rungs, String.to_integer(n) < 60, do: n

      assert below == [],
             "pearl-#{Enum.join(below, ", pearl-")} is below the AA floor. " <>
               "A rung that exists gets used; delete it instead."
    end

    test "no markup reaches for a pearl rung below 60" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            [_, rung] <- Regex.scan(~r/text-pearl-(\d+)/, line),
            String.to_integer(rung) < 60,
            do: "#{Path.relative_to(path, @web_root)}:#{n}"

      assert offenders == [], Enum.join(offenders, "\n")
    end
  end

  describe "type floor" do
    # 8.8px was the old bottom of the xs clamp, and eighteen rules sat on it.
    # The gallery card thumbnail is exempt and says so in place: it is a 60
    # column terminal shrunk to fit a card, not copy.
    test "no font-size under 11px outside the documented character grids" do
      css = File.read!(@css)

      # Both shapes: a plain value, and the FLOOR of a clamp. Only checking
      # plain values missed `.surface-bucket__label`, whose clamp bottomed out
      # at 9.6px on a phone while every plain rule beside it had been raised.
      literals = Regex.scan(~r/font-size:\s*([0-9.]+)(rem|px)\s*;/, css)
      clamps = Regex.scan(~r/font-size:\s*clamp\(\s*([0-9.]+)(rem|px)/, css)

      offenders =
        for [whole, value, unit] <- literals ++ clamps,
            px = if(unit == "rem", do: to_f(value) * 16, else: to_f(value)),
            px < 11,
            not grid_rule?(css, whole),
            do: "#{whole} (#{Float.round(px, 2)}px)"

      assert offenders == [],
             "below the 11px floor; use var(--text-xs):\n  " <>
               Enum.join(offenders, "\n  ")
    end

    test "inline styles do not undercut the floor either" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            [_, value, unit] <- Regex.scan(~r/font-size:\s*([0-9.]+)(rem|px)/, line),
            px = if(unit == "rem", do: to_f(value) * 16, else: to_f(value)),
            px < 11,
            do: "#{Path.relative_to(path, @web_root)}:#{n} (#{px}px)"

      assert offenders == [], Enum.join(offenders, "\n")
    end
  end

  describe "decoration" do
    # `terminal_chrome/1` dropped the fake mac window dots on the grounds that
    # they carry no information; the hero had quietly put them back.
    test "no fake window dots" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            String.match?(line, ~r/class="(hd-dot|hero-browser__dot)"/),
            do: "#{Path.relative_to(path, @web_root)}:#{n}"

      assert offenders == [], Enum.join(offenders, "\n")
    end

    # Every topic page is one section behind its own URL and opens with a
    # breadcrumb, which is the job an eyebrow does. Six pages carried both.
    test "no section eyebrows" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            String.contains?(line, ~s(class="section-eyebrow")),
            do: "#{Path.relative_to(path, @web_root)}:#{n}"

      assert offenders == [], Enum.join(offenders, "\n")
    end
  end

  describe "viewport units" do
    # `100vh` includes the iOS Safari address bar. Paired with overflow-hidden
    # it puts content behind the browser chrome with no way to scroll to it.
    test "no h-screen or 100vh" do
      offenders =
        for path <- web_sources(),
            {line, n} <- Enum.with_index(File.stream!(path), 1),
            String.match?(line, ~r/class="[^"]*\b(min-)?h-screen\b|:\s*100vh\b/),
            do: "#{Path.relative_to(path, @web_root)}:#{n}"

      assert offenders == [], "use 100dvh:\n" <> Enum.join(offenders, "\n")
    end
  end

  # Float.parse handles "13" as well as "0.65"; String.to_float does not.
  defp to_f(v), do: v |> Float.parse() |> elem(0)

  # A HEEx comment, an Elixir comment, or a CSS comment line.
  defp comment_line?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "<%!--") or
      String.starts_with?(trimmed, "/*") or String.starts_with?(trimmed, "*") or
      String.starts_with?(trimmed, "--")
  end

  # The documented exemptions, identified by the selector a declaration sits
  # under rather than by its value, so changing a value cannot silently widen
  # the exemption. All of them render a character GRID -- a terminal recording,
  # a code listing, an agent's tree -- sized so a fixed column count fits its
  # box. They are pictures of a terminal, not copy, and each says so in place.
  @grid_selectors [
    ".gallery-preview .raxol-terminal",
    ".hero-code",
    ".hero-src",
    ".hero-frames",
    ".hero-ansi"
  ]

  # Everything after the last rule terminator is the rule the declaration is
  # inside: its selector and the part of its body already seen. Simpler and
  # more accurate than peeking at a fixed window of preceding text, which
  # `.hero-code` defeats by carrying a paragraph of comment between its
  # selector and its font-size.
  defp grid_rule?(css, declaration) do
    case String.split(css, declaration, parts: 2) do
      [before | _] ->
        current_rule = before |> String.split("}") |> List.last() |> to_string()
        Enum.any?(@grid_selectors, &String.contains?(current_rule, &1))

      _ ->
        false
    end
  end
end
