defmodule Raxol.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.CLI

  describe "main/1 dispatch" do
    test "help lists every command, including code" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert out =~ "code"
      assert out =~ "coding-agent TUI"
      assert out =~ "playground"
    end

    test "an unknown command prints help and returns 1" do
      stderr =
        capture_io(:stderr, fn -> capture_io(fn -> assert CLI.main(["bogus"]) == 1 end) end)

      assert stderr =~ "unknown command"
    end
  end

  describe "code subcommand" do
    test "code --help prints the shared launcher usage" do
      out = capture_io(fn -> assert CLI.main(["code", "--help"]) == 0 end)

      assert out =~ "Usage: raxol code"
      assert out =~ "--continue"
    end

    test "code with a bad backend is a usage error before boot" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.main(["code", "--backend", "nonsense"]) == 64
        end)

      assert stderr =~ ~s(unknown backend "nonsense")
    end

    test "code without an interactive terminal vetoes with exit 1" do
      # The test VM has no tty on stdin, so the boot veto path is the real
      # one; --backend mock keeps provider resolution hermetic (keyless).
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.main(["code", "--backend", "mock"]) == 1
        end)

      assert stderr =~ "interactive terminal"
    end
  end
end
