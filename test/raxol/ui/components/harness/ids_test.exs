defmodule Raxol.UI.Components.Harness.IdsTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Ids

  describe "default_id/2" do
    test "returns the caller-supplied :id from a keyword list" do
      assert Ids.default_id([id: "x"], "p") == "x"
    end

    test "returns the caller-supplied :id from a map" do
      assert Ids.default_id(%{id: "x"}, "p") == "x"
    end

    test "generates a prefixed id from an empty keyword list" do
      id = Ids.default_id([], "p")
      assert String.starts_with?(id, "p-")
    end

    test "generates a prefixed id from a map without :id" do
      id = Ids.default_id(%{}, "p")
      assert String.starts_with?(id, "p-")
    end
  end

  describe "determinism" do
    # The committed harness recording used to carry ids like "tool-call-293":
    # whatever the VM-global counter happened to hold at boot, so no two
    # recordings agreed and the artifact named ids no agent would see again.
    # Ids need uniqueness within one rendered tree, and a tree is rendered by
    # one process, so identical boots must mint identical sequences.
    test "two fresh processes mint identical id sequences" do
      mint = fn ->
        [
          Ids.default_id([], "tool-call"),
          Ids.default_id(%{}, "tool-call"),
          Ids.default_id([], "toast")
        ]
      end

      [a, b] = Enum.map([Task.async(mint), Task.async(mint)], &Task.await/1)

      assert a == b
      assert a == ["tool-call-1", "tool-call-2", "toast-1"]
    end

    test "siblings in one process never collide" do
      ids = for _ <- 1..5, do: Ids.default_id([], "sib")
      assert Enum.uniq(ids) == ids
    end

    test "a supplied :id consumes no counter" do
      base = Ids.default_id([], "gap")
      _supplied = Ids.default_id([id: "mine"], "gap")
      assert Ids.default_id([], "gap") != base
      assert Ids.default_id(%{id: "mine"}, "gap") == "mine"
    end
  end
end
