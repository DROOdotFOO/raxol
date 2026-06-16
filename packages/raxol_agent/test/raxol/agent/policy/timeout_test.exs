defmodule Raxol.Agent.Policy.TimeoutTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Policy.Timeout

  describe "new/1" do
    test "from a positive integer" do
      t = Timeout.new(5_000)
      assert t.wall_ms == 5_000
    end

    test "from keyword opts" do
      t = Timeout.new(wall_ms: 30_000)
      assert t.wall_ms == 30_000
    end

    test "raises on zero / negative" do
      assert_raise ArgumentError, fn -> Timeout.new(0) end
      assert_raise ArgumentError, fn -> Timeout.new(-1) end
    end

    test "raises on keyword with bad value" do
      assert_raise ArgumentError, fn -> Timeout.new(wall_ms: 0) end
    end

    test "raises on garbage input" do
      assert_raise ArgumentError, fn -> Timeout.new(:nope) end
    end
  end
end
