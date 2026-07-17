defmodule Raxol.Harness.StreamCadenceTest do
  # CPU-contention flake class (see harness CI-honesty rules): coalescing
  # windows + receive deadlines starve under loaded shared runners when
  # sibling suites compete for cores. Serial keeps the timing world honest.
  use ExUnit.Case, async: false

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

      assert_receive {:render_batch, ["a"]}, 2_000
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
      assert_receive {:render_batch, ["a"]}, 2_000

      StreamCadence.ingest(server, "b")
      StreamCadence.ingest(server, "c")
      StreamCadence.ingest(server, "d")

      refute_receive {:render_batch, _}, 10

      assert_receive {:render_batch, ["b", "c", "d"]}, 2_000
    end
  end

  describe "input yield" do
    test "token flushes hold while input is pending, resume on the retry timer" do
      {:ok, input_pending} = Agent.start_link(fn -> true end)

      server =
        start(input_check: fn -> Agent.get(input_pending, & &1) end)

      StreamCadence.ingest(server, "x")

      # 10ms of 1ms retries stays under the 16-yield budget, so the
      # flush is still held here.
      refute_receive {:render_batch, _}, 10

      Agent.update(input_pending, fn _ -> false end)

      assert_receive {:render_batch, ["x"]}, 2_000
    end
  end

  describe "forced progress under permanent input" do
    test "yield budget forces a flush even when input never releases" do
      server = start(input_check: fn -> true end)

      StreamCadence.ingest(server, "x")

      # The default 16-yield budget exhausts after ~16 x 1ms retries and
      # the decision falls through to the cadence rules -> flush.
      assert_receive {:render_batch, ["x"]}, 2_000
    end

    test ":max_consecutive_yields config seam shortens the hold" do
      server = start(input_check: fn -> true end, max_consecutive_yields: 3)

      StreamCadence.ingest(server, "x")

      assert_receive {:render_batch, ["x"]}, 2_000
    end
  end

  describe "overflow: drop-oldest at the :max_pending watermark" do
    test "sheds oldest, emits telemetry, marks loss in-band at the next flush" do
      handler_id = "stream-cadence-overflow-#{inspect(self())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :stream_cadence, :overflow],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:overflow, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      server = start(flush_interval_ms: 60_000, max_pending: 5)

      StreamCadence.ingest(server, "seed")
      assert_receive {:render_batch, ["seed"]}, 2_000

      for i <- 1..10, do: StreamCadence.ingest(server, "d#{i}")

      # d6..d10 push the queue past the watermark; d1..d5 are shed.
      dropped_total =
        Enum.reduce(1..5, 0, fn _, acc ->
          assert_receive {:overflow, %{dropped: n}, %{max_pending: 5}}, 2_000
          acc + n
        end)

      assert dropped_total == 5
      refute_receive {:overflow, _, _}, 20

      StreamCadence.flush_now(server)

      assert_receive {:render_batch,
                      [{:cadence_dropped, 5}, "d6", "d7", "d8", "d9", "d10"]},
                     100
    end

    test "loss marker resets after the flush that reported it" do
      server = start(flush_interval_ms: 60_000, max_pending: 2)

      StreamCadence.ingest(server, "seed")
      assert_receive {:render_batch, ["seed"]}, 2_000

      for i <- 1..3, do: StreamCadence.ingest(server, "d#{i}")

      StreamCadence.flush_now(server)
      assert_receive {:render_batch, [{:cadence_dropped, 1}, "d2", "d3"]}, 2_000

      StreamCadence.ingest(server, "z")
      StreamCadence.flush_now(server)

      # No marker: the counter reset at the previous flush.
      assert_receive {:render_batch, ["z"]}, 2_000
    end

    test "marker prepends without displacing a delta: batch may be max_drain + 1" do
      server = start(flush_interval_ms: 60_000, max_pending: 32)

      StreamCadence.ingest(server, "seed")
      assert_receive {:render_batch, ["seed"]}, 2_000

      deltas = for i <- 1..33, do: "d#{i}"
      Enum.each(deltas, &StreamCadence.ingest(server, &1))

      # d1 was shed at the watermark; d2..d33 (32 items, a full drain)
      # remain. The marker rides along as element 33 -- it is not
      # counted against the drain bound, so no delta is displaced.
      StreamCadence.flush_now(server)

      assert_receive {:render_batch, batch}, 2_000
      assert length(batch) == 33
      assert hd(batch) == {:cadence_dropped, 1}
      assert tl(batch) == Enum.drop(deltas, 1)
    end
  end

  describe "flush_now/1 forced drain" do
    test "delivers everything pending, in order, in bounded batches" do
      # A very long interval keeps the cadence gate closed for the
      # remainder after the first (always-immediate) flush.
      server = start(flush_interval_ms: 60_000)

      StreamCadence.ingest(server, "first")
      assert_receive {:render_batch, ["first"]}, 2_000

      deltas = for i <- 1..40, do: "e#{i}"
      Enum.each(deltas, &StreamCadence.ingest(server, &1))

      refute_receive {:render_batch, _}, 10

      StreamCadence.flush_now(server)

      assert_receive {:render_batch, batch1}, 2_000
      assert_receive {:render_batch, batch2}, 2_000
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
      assert_receive {:render_batch, ["a"]}, 2_000

      send(server, :flush_due)

      assert Process.alive?(server)

      StreamCadence.ingest(server, "b")
      assert_receive {:render_batch, ["b"]}, 2_000
    end
  end
end
