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
end
