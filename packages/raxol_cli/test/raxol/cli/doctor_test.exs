defmodule Raxol.CLI.DoctorTest do
  use ExUnit.Case, async: true

  alias Raxol.CLI.Doctor

  describe "the acp surface row" do
    test "says available where an agent can be started" do
      assert Doctor.acp_surface({:unix, :linux}) == "available (raxol acp --agent <app>)"
    end

    test "does not say available on Windows, where every session/new is refused" do
      row = Doctor.acp_surface({:win32, :nt})

      refute row =~ "available ("
      assert row =~ "NOT available"
      assert row =~ "not available on Windows"
    end
  end
end
