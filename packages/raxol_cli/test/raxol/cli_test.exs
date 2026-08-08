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

    test "help lists acp, and it is a declared command" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert out =~ "acp"
      assert out =~ "Agent Client Protocol"
      assert "acp" in CLI.commands()
    end
  end

  describe "acp subcommand" do
    test "acp --help prints the shared serve usage" do
      out = capture_io(fn -> assert CLI.main(["acp", "--help"]) == 0 end)

      assert out =~ "Usage: raxol acp"
      assert out =~ "--backend"
    end

    # The packaged binary must not merely accept `acp` -- the surface behind it
    # is compile-gated on the (unpublished) ACP package, so a build that ships
    # the subcommand without the agent would fail only at runtime, on the wire.
    #
    # This also catches a stale _build: adding the ACP dep does not change
    # raxol_agent's own sources, so Mix will happily reuse a raxol_agent
    # compiled before the package existed, with "absent" baked into the gate.
    # Remedy: `mix deps.compile raxol_agent --force`.
    test "the ACP agent surface is compiled into this build" do
      assert Raxol.Agent.ClientProtocol.Serve.available?()
    end

    test "an unknown acp option is a usage error, not a boot" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.main(["acp", "--nonsense"]) == 64
        end)

      assert stderr =~ "unknown options"
    end

    test "an unknown command prints help and returns 1" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.main(["bogus"]) == 1 end)
        end)

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

    test "code --ssh is NOT vetoed for a missing tty (serving needs none)" do
      # Without --authorized-keys the launcher rejects --ssh as a usage error
      # (64), which proves the tty veto (exit 1, "interactive terminal") did
      # NOT fire first — the SSH path skips the local-terminal check.
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.main(["code", "--ssh"]) == 64
        end)

      assert stderr =~ "authorized-keys"
      refute stderr =~ "interactive terminal"
    end
  end
end
