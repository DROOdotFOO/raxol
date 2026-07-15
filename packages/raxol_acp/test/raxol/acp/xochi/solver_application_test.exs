defmodule Raxol.ACP.Xochi.SolverApplicationTest do
  # async: false -- enabled?/0 reads app env, which the cases override.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.SolverApplication

  describe "enabled?/0" do
    test "off by default" do
      Application.delete_env(:raxol_acp, :xochi_solver_enabled)
      refute SolverApplication.enabled?()
    end

    test "on only when the flag is explicitly true" do
      Application.put_env(:raxol_acp, :xochi_solver_enabled, true)
      assert SolverApplication.enabled?()

      Application.put_env(:raxol_acp, :xochi_solver_enabled, false)
      refute SolverApplication.enabled?()
    after
      Application.delete_env(:raxol_acp, :xochi_solver_enabled)
    end
  end
end
