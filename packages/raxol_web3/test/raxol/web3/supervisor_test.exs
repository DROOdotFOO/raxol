defmodule Raxol.Web3.SupervisorTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Supervisor

  describe "the boot-time client assertion" do
    test "refuses a build whose bounded read is missing, naming the cause and the fix" do
      # The real module is loadable in any build that runs this suite -- the
      # application would not have started otherwise -- so the refusal is
      # exercised with a module name that cannot exist. What is under test is
      # that a missing bounded read stops the boot rather than the first
      # request, and that the message says why and what to do.
      error =
        assert_raise RuntimeError, fn ->
          Supervisor.assert_client!(Raxol.Web3.NoSuchBoundedExchange)
        end

      assert error.message =~ "Raxol.Web3.NoSuchBoundedExchange is not available"
      assert error.message =~ "mint"
      assert error.message =~ "mix deps.clean raxol_mcp mint --build"
    end

    test "passes on the module the package actually dials through" do
      assert :ok = Supervisor.assert_client!()
    end
  end
end
