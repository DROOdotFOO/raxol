defmodule Raxol.Harness.StreamCadenceTest do
  use ExUnit.Case, async: true

  alias Raxol.Harness.StreamCadence

  defp start(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    start_supervised!({StreamCadence, opts})
  end

  describe "construction" do
    test "requires at least one of :sink / :owner" do
      Process.flag(:trap_exit, true)

      assert {:error, _} = start_supervised({StreamCadence, []})
    end
  end

  describe "first delta" do
    test "flushes immediately with no waiting" do
      server = start([])

      StreamCadence.ingest(server, "a")

      assert_receive {:render_batch, ["a"]}, 50
    end
  end

  describe "1000-delta burst, no token loss" do
    test "every batch <= 32, order preserved, none dropped" do
      # flush_interval_ms: 0 keeps the policy at :flush_now for every
      # decision, so this test drives zero sleeps/timers.
      server = start(flush_interval_ms: 0)

      deltas = for i <- 0..999, do: "d#{i}"
      Enum.each(deltas, &StreamCadence.ingest(server, &1))

      {batches, total} = collect_batches(0, [])

      assert total == 1000
      assert Enum.all?(batches, &(length(&1) <= 32))
      assert Enum.concat(Enum.reverse(batches)) == deltas
    end

    defp collect_batches(total, acc) when total >= 1000, do: {acc, total}

    defp collect_batches(total, acc) do
      receive do
        {:render_batch, batch} ->
          collect_batches(total + length(batch), [batch | acc])
      after
        1_000 -> {acc, total}
      end
    end
  end

  describe "burst coalescing under cadence" do
    test "deltas within one window arrive as a single coalesced batch" do
      server = start(flush_interval_ms: 30)

      StreamCadence.ingest(server, "a")
      assert_receive {:render_batch, ["a"]}, 50

      StreamCadence.ingest(server, "b")
      StreamCadence.ingest(server, "c")
      StreamCadence.ingest(server, "d")

      refute_receive {:render_batch, _}, 10

      assert_receive {:render_batch, ["b", "c", "d"]}, 50
    end
  end

  describe "input yield" do
    test "token flushes hold while input is pending, resume on the retry timer" do
      {:ok, input_pending} = Agent.start_link(fn -> true end)

      server =
        start(input_check: fn -> Agent.get(input_pending, & &1) end)

      StreamCadence.ingest(server, "x")

      refute_receive {:render_batch, _}, 30

      Agent.update(input_pending, fn _ -> false end)

      assert_receive {:render_batch, ["x"]}, 50
    end
  end

  describe "flush_now/1 forced drain" do
    test "delivers everything pending, in order, in bounded batches" do
      # A very long interval keeps the cadence gate closed for the
      # remainder after the first (always-immediate) flush.
      server = start(flush_interval_ms: 60_000)

      StreamCadence.ingest(server, "first")
      assert_receive {:render_batch, ["first"]}, 50

      deltas = for i <- 1..40, do: "e#{i}"
      Enum.each(deltas, &StreamCadence.ingest(server, &1))

      refute_receive {:render_batch, _}, 10

      StreamCadence.flush_now(server)

      assert_receive {:render_batch, batch1}, 50
      assert_receive {:render_batch, batch2}, 50
      refute_receive {:render_batch, _}, 20

      assert length(batch1) == 32
      assert length(batch2) == 8
      assert batch1 ++ batch2 == deltas
    end
  end

  describe "manual :flush_due safety" do
    test "is a no-op with zero pending and the server stays alive" do
      server = start([])

      StreamCadence.ingest(server, "a")
      assert_receive {:render_batch, ["a"]}, 50

      send(server, :flush_due)

      assert Process.alive?(server)

      StreamCadence.ingest(server, "b")
      assert_receive {:render_batch, ["b"]}, 50
    end
  end
end
