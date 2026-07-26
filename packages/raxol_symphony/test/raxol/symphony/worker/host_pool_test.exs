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

      assert HostPool.release(pool, %HostSpec{host: "build-1"})
             |> HostPool.free_count() == 1

      assert HostPool.release(pool, %HostSpec{host: "not-in-pool"})
             |> HostPool.free_count() == 1
    end

    test "duplicate-id hosts stay independent: N identical slots give N workers" do
      # Two entries that resolve the SAME HostSpec.id/1 must not collapse:
      # claiming one flips exactly one slot, so both remain usable.
      dup = %HostSpec{host: "build-1", user: "ci"}
      pool = HostPool.new([dup, dup])

      {:ok, ^dup, pool} = HostPool.claim(pool)
      assert HostPool.busy_count(pool) == 1
      assert HostPool.free_count(pool) == 1

      # The second identical host is still claimable (not collapsed busy).
      {:ok, ^dup, pool} = HostPool.claim(pool)
      assert HostPool.busy_count(pool) == 2
      assert HostPool.claim(pool) == :none_free
    end

    test "release frees exactly one of two busy duplicate-id slots" do
      dup = %HostSpec{host: "build-1", user: "ci"}
      pool = HostPool.new([dup, dup])

      {:ok, _, pool} = HostPool.claim(pool)
      {:ok, _, pool} = HostPool.claim(pool)
      assert HostPool.busy_count(pool) == 2

      pool = HostPool.release(pool, dup)
      assert HostPool.busy_count(pool) == 1
      assert HostPool.free_count(pool) == 1
    end
  end

  describe "reconcile/2 (config hot-reload)" do
    test "nil pool gains slots for newly-configured hosts" do
      pool = HostPool.reconcile(nil, specs(2))
      assert HostPool.size(pool) == 2
      assert HostPool.free_count(pool) == 2
    end

    test "an added host becomes a fresh free slot, busy slots untouched" do
      pool = HostPool.new(specs(2))
      {:ok, claimed, pool} = HostPool.claim(pool)

      pool = HostPool.reconcile(pool, specs(3))

      assert HostPool.size(pool) == 3
      assert HostPool.busy_count(pool) == 1
      assert HostPool.free_count(pool) == 2
      # The claimed host is still held (busy), not re-freed by the reconcile.
      assert HostSpec.id(claimed) in HostPool.host_ids(pool)
      assert HostPool.draining_count(pool) == 0
    end

    test "a removed free host disappears from the pool" do
      pool = HostPool.new(specs(3))
      pool = HostPool.reconcile(pool, specs(2))

      assert HostPool.size(pool) == 2
      assert HostPool.host_ids(pool) == ["build-1", "build-2"]
    end

    test "a removed busy host is marked draining, kept out of allocation" do
      [s1, s2] = specs(2)
      pool = HostPool.new([s1, s2])
      {:ok, ^s1, pool} = HostPool.claim(pool)

      # build-1 is busy; drop it from config, keep build-2.
      pool = HostPool.reconcile(pool, [s2])

      assert HostPool.size(pool) == 2
      assert HostPool.draining_count(pool) == 1
      assert HostPool.busy_count(pool) == 1
      assert HostPool.free_count(pool) == 1

      # The draining host is not handed out; only the surviving free slot is.
      {:ok, ^s2, pool} = HostPool.claim(pool)
      assert HostPool.claim(pool) == :none_free
    end

    test "releasing a draining slot drops it entirely" do
      [s1, s2] = specs(2)
      pool = HostPool.new([s1, s2])
      {:ok, ^s1, pool} = HostPool.claim(pool)
      pool = HostPool.reconcile(pool, [s2])
      assert HostPool.draining_count(pool) == 1

      pool = HostPool.release(pool, s1)
      assert HostPool.size(pool) == 1
      assert HostPool.draining_count(pool) == 0
      assert HostPool.host_ids(pool) == ["build-2"]
    end

    test "re-adding a still-draining host un-drains it" do
      [s1, s2] = specs(2)
      pool = HostPool.new([s1, s2])
      {:ok, ^s1, pool} = HostPool.claim(pool)
      pool = HostPool.reconcile(pool, [s2])
      assert HostPool.draining_count(pool) == 1

      pool = HostPool.reconcile(pool, [s1, s2])
      assert HostPool.draining_count(pool) == 0
      assert HostPool.busy_count(pool) == 1
    end

    test "reconcile to an empty desired set drops free slots to nil" do
      pool = HostPool.new(specs(2))
      assert HostPool.reconcile(pool, []) == nil
    end
  end

  describe "hold/2 (re-hold across pause/resume or restart)" do
    test "claims a matching free slot (restart rebuilt the pool)" do
      [s1, s2] = specs(2)
      pool = HostPool.new([s1, s2])

      pool = HostPool.hold(pool, s1)
      assert HostPool.busy_count(pool) == 1
      # The held host is no longer free; the other stays claimable.
      {:ok, ^s2, pool} = HostPool.claim(pool)
      assert HostPool.claim(pool) == :none_free
    end

    test "is idempotent when a matching slot is already busy" do
      [s1, s2] = specs(2)
      pool = HostPool.new([s1, s2])
      {:ok, ^s1, pool} = HostPool.claim(pool)

      held = HostPool.hold(pool, s1)
      assert HostPool.busy_count(held) == 1
    end

    test "is a no-op for an absent host or a nil pool" do
      pool = HostPool.new(specs(1))
      assert HostPool.hold(pool, %HostSpec{host: "gone"}) == pool
      assert HostPool.hold(nil, %HostSpec{host: "x"}) == nil
    end
  end

  describe "reserve/2 (slot-precise boot rehold)" do
    test "N reserves on a duplicated host take N distinct slots" do
      # Two paused entries on a host that appears twice in the config must
      # rehold TWO slots at boot. `hold/2` would short-circuit on the first
      # busy match and under-reserve; `reserve/2` takes a distinct free slot.
      dup = %HostSpec{host: "build-1", user: "ci"}
      pool = HostPool.new([dup, dup])

      pool = HostPool.reserve(pool, dup)
      assert HostPool.busy_count(pool) == 1

      pool = HostPool.reserve(pool, dup)
      assert HostPool.busy_count(pool) == 2
      # Both slots reserved -> no fresh worker can claim the physical host.
      assert HostPool.claim(pool) == :none_free
    end

    test "returns the pool unchanged when no free matching slot exists" do
      dup = %HostSpec{host: "build-1", user: "ci"}
      pool = HostPool.new([dup, dup])
      pool = pool |> HostPool.reserve(dup) |> HostPool.reserve(dup)

      assert HostPool.reserve(pool, dup) == pool
    end

    test "is a no-op for an absent host or a nil pool" do
      pool = HostPool.new(specs(1))
      assert HostPool.reserve(pool, %HostSpec{host: "gone"}) == pool
      assert HostPool.reserve(nil, %HostSpec{host: "x"}) == nil
    end
  end
end
