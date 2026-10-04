defmodule Mix.Tasks.RaxolPayments.AnvilPathTest do
  # Rewrites PATH, which is VM-global: async modules running alongside would
  # lose `System.find_executable/1`. Kept out of the async AnvilTest for that.
  use ExUnit.Case, async: false

  alias Mix.Tasks.RaxolPayments.Anvil

  test "check_anvil_available/0 returns {:error, :anvil_not_found} when anvil is missing from $PATH" do
    original = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

    try do
      assert {:error, :anvil_not_found} = Anvil.check_anvil_available()
    after
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end
  end
end
