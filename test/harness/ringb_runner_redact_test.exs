t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBRunnerRedactTest do
  @moduledoc """
  `T0.RingB.Runner.redact_evidence/3` is what keeps an operator's home
  directory and checkout path out of the tracked `ringb-*.txt` evidence
  files. Pure text in, text out: no terminal is driven, so unlike the
  rest of `test/harness/ringb_*` this runs in the default suite.
  """

  use ExUnit.Case, async: true

  alias T0.RingB.Runner

  @home "/Users/someone"
  @repo "/Users/someone/src/raxol/.claude/worktrees/agent-1"

  test "replaces the repo root with <repo> in a single-line capture" do
    text =
      "$ T0_HOLD_SECONDS=8 bash '#{@repo}/scripts/harness/t0/probes/p01_region_footer.sh' " <>
        "24 3 40 ringb-iterm2-C1-6850 \n \n"

    assert Runner.redact_evidence(text, @repo, @home) ==
             "$ T0_HOLD_SECONDS=8 bash '<repo>/scripts/harness/t0/probes/p01_region_footer.sh' " <>
               "24 3 40 ringb-iterm2-C1-6850 \n \n"
  end

  test "redacts a path the terminal wrapped across lines and keeps the line count" do
    full =
      "$ T0_HOLD_SECONDS=8 bash '#{@repo}/scripts/harness/t0/probes/p01_region_footer.sh'" <>
        " 24 3 40 ringb-wezterm-C1-14786"

    wrapped =
      full
      |> String.graphemes()
      |> Enum.chunk_every(80)
      |> Enum.map_join("\n", &Enum.join/1)

    text = "For more details\n" <> wrapped <> "\n\nSTATUS: idle\n"
    redacted = Runner.redact_evidence(text, @repo, @home)

    refute redacted =~ "someone"
    assert redacted =~ "bash '<repo>"

    assert length(String.split(redacted, "\n")) ==
             length(String.split(text, "\n"))

    assert String.starts_with?(redacted, "For more details\n")
    assert String.ends_with?(redacted, "\n\nSTATUS: idle\n")
  end

  test "replaces $HOME with ~ outside the repo root" do
    text = "cat #{@home}/.zshrc\n#{@repo}/mix.exs\n"

    assert Runner.redact_evidence(text, @repo, @home) ==
             "cat ~/.zshrc\n<repo>/mix.exs\n"
  end

  test "redacts Windows paths with either separator style" do
    repo = ~S(C:\Users\someone\src\raxol)
    home = ~S(C:\Users\someone)
    text = ~S(C:\Users\someone\src\raxol\mix.exs C:/Users/someone/notes.txt)

    assert Runner.redact_evidence(text, repo, home) ==
             ~S(<repo>\mix.exs ~/notes.txt)
  end

  test "a sibling path sharing the root as a prefix is not taken for the root" do
    text = "#{@repo}_other/x #{@home}2/y"

    assert Runner.redact_evidence(text, @repo, @home) ==
             "~/src/raxol/.claude/worktrees/agent-1_other/x #{@home}2/y"
  end

  test "an unset or root HOME redacts nothing beyond the repo root" do
    text = "#{@home}/a #{@repo}/b"

    assert Runner.redact_evidence(text, @repo, nil) == "#{@home}/a <repo>/b"
    assert Runner.redact_evidence(text, @repo, "/") == "#{@home}/a <repo>/b"
  end
end
