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
end
