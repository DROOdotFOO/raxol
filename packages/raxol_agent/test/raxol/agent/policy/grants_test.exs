defmodule Raxol.Agent.Policy.GrantsTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Policy.Grants
  alias Raxol.Agent.Sandbox

  describe "shell_jail_allow/1" do
    test "refuses a jailed context" do
      assert {:error, :shell_disabled_in_jail} =
               Grants.shell_jail_allow(%{jail: true})
    end

    test "allows a non-jailed context" do
      assert :ok = Grants.shell_jail_allow(%{})
      assert :ok = Grants.shell_jail_allow(%{jail: false})
    end

    test "a lexical sandbox is not evidence of confinement" do
      for sandbox <- [
            Sandbox.Shell.none(),
            Sandbox.Shell.allowlist(["echo"]),
            Sandbox.Shell.denylist(["rm"])
          ] do
        assert {:error, :shell_disabled_in_jail} =
                 Grants.shell_jail_allow(%{jail: true, shell_sandbox: sandbox})
      end
    end
  end

  describe "shell_allow/2" do
    test "honors a shell sandbox denylist in context" do
      sandbox = Sandbox.Shell.denylist(["rm"])

      assert {:error, {:shell_denied, "rm -rf /"}} =
               Grants.shell_allow(%{shell_sandbox: sandbox}, "rm -rf /")
    end

    test "allows a command permitted by the sandbox allowlist" do
      sandbox = Sandbox.Shell.allowlist(["echo"])

      assert :ok = Grants.shell_allow(%{shell_sandbox: sandbox}, "echo ok")
    end

    test "allows any command when the context carries no sandbox" do
      assert :ok = Grants.shell_allow(%{}, "rm -rf /")
    end

    # With an `echo` allowlist configured, no wrapper in the corpus may chain,
    # substitute or redirect its way to a second command.
    test "an allowlisted binary cannot be used to run anything else" do
      sandbox = Sandbox.Shell.allowlist(["echo"])
      outside = "/tmp/raxol-sentinel"

      attempts = [
        "echo x; cat #{outside}",
        "echo x && cat #{outside}",
        "echo x | cat #{outside}",
        "echo $(cat #{outside})",
        "echo `cat #{outside}`",
        "echo x\ncat #{outside}",
        "echo pwned > #{outside}",
        "echo x; rm -f #{outside}",
        "echo x; sh -c 'cat #{outside}'"
      ]

      for command <- attempts do
        assert {:error, {:shell_denied, ^command}} =
                 Grants.shell_allow(%{shell_sandbox: sandbox}, command),
               "expected a denial for: #{inspect(command)}"
      end
    end

    # The cwd jail does not confine a shell command line, and a lexical
    # policy does not re-enable it.
    test "refuses a jailed session before the sandbox is consulted" do
      assert {:error, :shell_disabled_in_jail} =
               Grants.shell_allow(%{jail: true}, "cat ../../other/secret")

      sandbox = Sandbox.Shell.allowlist(["echo"])

      assert {:error, :shell_disabled_in_jail} =
               Grants.shell_allow(%{jail: true, shell_sandbox: sandbox}, "echo ok")
    end
  end

  describe "network_allow/1" do
    test "is on by default" do
      assert :ok = Grants.network_allow(%{})
      assert :ok = Grants.network_allow(%{jail: false})
    end

    test "is off in a jail unless the context unlocks it" do
      assert {:error, :network_disabled} = Grants.network_allow(%{jail: true})
      assert :ok = Grants.network_allow(%{jail: true, network: true})
    end

    test "network: false disables it anywhere" do
      assert {:error, :network_disabled} = Grants.network_allow(%{network: false})
      assert {:error, :network_disabled} = Grants.network_allow(%{jail: true, network: false})
    end
  end
end
