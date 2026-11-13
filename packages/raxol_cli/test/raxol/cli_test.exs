defmodule Raxol.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.CLI

  describe "main/1 dispatch" do
    test "help lists every command" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      for command <- CLI.commands() do
        assert out =~ ~r/^\s+#{command}\b/m, "#{command} missing from the help text"
      end
    end

    test "bare raxol prints the help" do
      bare = capture_io(fn -> assert CLI.main([]) == 0 end)
      help = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert bare == help
    end

    test "--version prints the CLI version and returns 0" do
      out = capture_io(fn -> assert CLI.main(["--version"]) == 0 end)

      assert out == "raxol #{CLI.version()}\n"
    end

    test "help lists acp, and it is a declared command" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert out =~ "acp"
      assert out =~ "Agent Client Protocol"
      assert "acp" in CLI.commands()
    end

    test "every command in the help text is also a declared command" do
      for command <- ~w(acp mcp doctor update playground new help) do
        assert command in CLI.commands(), "#{command} missing from commands/0"
      end
    end

    # The banner carries the build commit so a stale packaged binary is visible
    # without diffing its behaviour.
    test "the banner reports a version" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert out =~ ~r/raxol \d+\.\d+\.\d+/
      assert CLI.version() =~ ~r/^\d+\.\d+\.\d+|^dev/
    end

    test "help labels new apps as Elixir/Mix projects" do
      out = capture_io(fn -> assert CLI.main(["help"]) == 0 end)

      assert out =~ "new [name]"
      assert out =~ "Elixir/Mix"
    end
  end

  describe "acp subcommand" do
    test "acp --help prints the shared serve usage" do
      out = capture_io(fn -> assert CLI.main(["acp", "--help"]) == 0 end)

      assert out =~ "Usage: raxol acp"
      assert out =~ "--agent"
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
      for argv <- [["acp", "--nonsense"], ["acp", "--backend", "mock"]] do
        stderr = capture_io(:stderr, fn -> assert CLI.main(argv) == 64 end)

        assert stderr =~ "unknown arguments"
      end
    end

    test "an unknown command prints help and returns 1" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.main(["bogus"]) == 1 end)
        end)

      assert stderr =~ "unknown command"
    end
  end

  describe "interactive?/1" do
    test "the Burrito arm ignores the group leader" do
      # Burrito's launcher puts the BEAM's stdout on a pipe, so the group leader
      # reports a non-terminal on every packaged run. Reading it there vetoed
      # `raxol playground` unconditionally -- the packaged binary could not
      # open it. Under a StringIO group leader, which is
      # the strongest "no terminal" signal a test can produce, the non-Burrito
      # arm must still veto while the Burrito arm must not consult it at all.
      {{burrito, plain}, _io} =
        with_io(fn -> {CLI.interactive?(true), CLI.interactive?(false)} end)

      refute plain
      assert burrito == (:prim_tty.isatty(:stdin) == true)
    end
  end
end
