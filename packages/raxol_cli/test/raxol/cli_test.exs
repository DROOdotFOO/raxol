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

    # `login` shipped in the help text but not in `commands/0`, so anything
    # driving the declared list (completions, docs) could not see it.
    test "every command in the help text is also a declared command" do
      for command <- ~w(agent code p acp login setup doctor playground new help) do
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

  describe "setup subcommand" do
    test "setup --help prints its own usage, not the agent's" do
      out = capture_io(fn -> assert CLI.main(["setup", "--help"]) == 0 end)

      assert out =~ "Usage: raxol setup"
      assert out =~ "--provider"
    end

    test "setup status prints next actions" do
      out = capture_io(fn -> assert CLI.main(["setup"]) == 0 end)

      assert out =~ "providers:"
      assert out =~ "next:"
      assert out =~ "raxol doctor"
    end

    test "doctor prints an onboarding next block" do
      out = capture_io(fn -> assert CLI.main(["doctor"]) == 0 end)

      assert out =~ "packaging"
      assert out =~ "next:"
      assert out =~ "raxol setup"
      assert out =~ "raxol new counter"
    end

    # 64 is the usage-error code the Mix task already used; the shared front
    # end has to keep returning it now that two shims depend on the value.
    test "an unknown setup option is a usage error, not a crash" do
      capture_io(:stderr, fn ->
        assert CLI.main(["setup", "--definitely-not-a-flag"]) == 64
      end)
    end

    test "providerless default explains mock mode and connection commands" do
      with_agent_resolver(:error, fn ->
        out =
          capture_io([input: "/exit\n"], fn ->
            assert CLI.main([]) == 0
          end)

        assert out =~ "No provider connected. Mock mode is active."
        assert out =~ "raxol login openrouter"

        assert out =~
                 "raxol setup --provider anthropic --op op://Vault/Item/api_key"

        assert out =~ "type a prompt, or /exit"
      end)
    end

    test "configured providers skip mock mode" do
      executor =
        Raxol.Agent.ExecutorConfig.new(
          harness: :openai,
          auth: %{api_key: "sk-test"}
        )

      with_agent_resolver({:ok, executor}, fn ->
        out =
          capture_io([input: "/exit\n"], fn ->
            assert CLI.main([]) == 0
          end)

        refute out =~ "Mock mode is active"
      end)
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
      # `interactive?/0` reads this process's GROUP LEADER, not stdin, so
      # capturing :stderr alone leaves a real tty in place and the full-screen
      # TUI boots over it. The outer `with_io/1` swaps the group leader for a
      # StringIO, which is what makes the veto path deterministic whether or
      # not the suite was launched from a terminal. --backend mock keeps
      # provider resolution hermetic (keyless).
      {stderr, _stdout} =
        with_io(fn ->
          capture_io(:stderr, fn ->
            assert CLI.main(["code", "--backend", "mock"]) == 1
          end)
        end)

      assert stderr =~ "interactive terminal"
    end

    test "the Burrito arm ignores the group leader" do
      # Burrito's launcher puts the BEAM's stdout on a pipe, so the group leader
      # reports a non-terminal on every packaged run. Reading it there vetoed
      # `raxol code` and `raxol playground` unconditionally -- the packaged
      # binary could not open either. Under a StringIO group leader, which is
      # the strongest "no terminal" signal a test can produce, the non-Burrito
      # arm must still veto while the Burrito arm must not consult it at all.
      {{burrito, plain}, _io} =
        with_io(fn -> {CLI.interactive?(true), CLI.interactive?(false)} end)

      refute plain
      assert burrito == (:prim_tty.isatty(:stdin) == true)
    end

    test "code --ssh is NOT vetoed for a missing tty (serving needs none)" do
      # Without --authorized-keys the launcher rejects --ssh as a usage error
      # (64), which proves the tty veto (exit 1, "interactive terminal") did
      # NOT fire first -- the SSH path skips the local-terminal check. The
      # group-leader swap is what gives the refute its meaning: under a real
      # tty the veto could not have fired anyway.
      {stderr, _stdout} =
        with_io(fn ->
          capture_io(:stderr, fn ->
            assert CLI.main(["code", "--ssh"]) == 64
          end)
        end)

      assert stderr =~ "authorized-keys"
      refute stderr =~ "interactive terminal"
    end
  end

  defp with_agent_resolver(result, fun) do
    previous = Application.get_env(:raxol_cli, :agent_executor_resolver)
    Application.put_env(:raxol_cli, :agent_executor_resolver, fn -> result end)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:raxol_cli, :agent_executor_resolver, previous)
      else
        Application.delete_env(:raxol_cli, :agent_executor_resolver)
      end
    end
  end
end
