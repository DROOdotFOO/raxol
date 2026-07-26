defmodule Raxol.Symphony.Worker.HostPoolTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Worker.{HostPool, HostSpec}

  defp specs(n) do
    for i <- 1..n, do: %HostSpec{host: "build-#{i}"}
  end

  describe "new/1" do
    test "an empty list yields nil (no gating)" do
      assert HostPool.new([]) == nil
    end

    test "a non-empty list yields a pool with all slots free" do
      pool = HostPool.new(specs(3))
      assert HostPool.size(pool) == 3
      assert HostPool.free_count(pool) == 3
      assert HostPool.busy_count(pool) == 0
    end
  end

  describe "claim/1 and release/2" do
    test "claim marks a host busy and returns the updated pool" do
      pool = HostPool.new(specs(2))

      assert {:ok, %HostSpec{host: "build-1"}, pool} = HostPool.claim(pool)
      assert HostPool.busy_count(pool) == 1
      assert HostPool.free_count(pool) == 1
    end

    test "claims hand out distinct hosts until exhausted, then :none_free" do
      pool = HostPool.new(specs(2))

      {:ok, h1, pool} = HostPool.claim(pool)
      {:ok, h2, pool} = HostPool.claim(pool)

      assert h1.host != h2.host
      assert HostPool.free_count(pool) == 0
      assert HostPool.claim(pool) == :none_free
    end

    test "release frees a host so it can be re-claimed" do
      pool = HostPool.new(specs(1))

      {:ok, host, pool} = HostPool.claim(pool)
      assert HostPool.claim(pool) == :none_free

      pool = HostPool.release(pool, host)
      assert HostPool.free_count(pool) == 1
      assert {:ok, ^host, _pool} = HostPool.claim(pool)
    end

    test "releasing an already-free or unknown host is a no-op" do
      pool = HostPool.new(specs(1))

      assert HostPool.release(pool, %HostSpec{host: "build-1"}) |> HostPool.free_count() == 1
      assert HostPool.release(pool, %HostSpec{host: "not-in-pool"}) |> HostPool.free_count() == 1
    end
  end
end
