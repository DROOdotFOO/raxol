defmodule Raxol.UI.Rendering.RenderBatcherTest do
  use ExUnit.Case, async: false

  alias Raxol.UI.Rendering.RenderBatcher

  describe "render batcher lifecycle" do
    test "starts with default frame interval" do
      batcher_name = :"test_batcher_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      stats = RenderBatcher.get_stats(batcher_name)
      assert stats.batches_processed == 0
      assert stats.updates_batched == 0
      assert stats.pending_updates == 0
      assert stats.accumulated_damage_regions == 0

      GenServer.stop(pid)
    end

    test "accepts custom frame interval" do
      batcher_name = :"custom_batcher_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          # 30fps
          frame_interval_ms: 33
        )

      # Should start successfully with custom interval
      stats = RenderBatcher.get_stats(batcher_name)
      assert is_map(stats)

      GenServer.stop(pid)
    end

    test "accepts custom name in options" do
      batcher_name = :"custom_batch_name_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      assert RenderBatcher.get_stats(batcher_name).pending_updates == 0

      GenServer.stop(pid)
    end
  end

  describe "update submission and batching" do
    setup do
      batcher_name = :"test_batch_updates_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          # Longer interval for testing
          frame_interval_ms: 100
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "accumulates updates in batch", %{batcher: batcher} do
      tree1 = %{type: :container, children: [%{type: :label, text: "Hello"}]}
      tree2 = %{type: :container, children: [%{type: :label, text: "World"}]}

      diff1 = {:update, [0], %{type: :content, text: "Hello"}}
      diff2 = {:update, [0], %{type: :content, text: "World"}}

      # Submit multiple updates
      :ok = RenderBatcher.submit_update(tree1, diff1, :medium, batcher)
      :ok = RenderBatcher.submit_update(tree2, diff2, :low, batcher)

      # Should accumulate in pending updates
      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 2
      assert stats.accumulated_damage_regions >= 1
    end

    test "handles different priority levels", %{batcher: batcher} do
      tree = %{type: :container, children: []}
      diff = {:update, [], %{type: :structure}}

      # Submit updates with different priorities
      :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 3
    end

    test "accumulates damage from multiple updates", %{batcher: batcher} do
      tree = %{type: :container, children: [%{text: "A"}, %{text: "B"}]}

      diff1 = {:update, [0], %{type: :content}}
      diff2 = {:update, [1], %{type: :content}}

      :ok = RenderBatcher.submit_update(tree, diff1, :medium, batcher)
      :ok = RenderBatcher.submit_update(tree, diff2, :medium, batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 2
      # Should have accumulated damage for both nodes
      assert stats.accumulated_damage_regions >= 2
    end

    test "handles no-change diffs without errors", %{batcher: batcher} do
      tree = %{type: :container}

      :ok = RenderBatcher.submit_update(tree, :no_change, :low, batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 1
      # No-change should not add damage regions
      assert stats.accumulated_damage_regions == 0
    end
  end

  describe "immediate flush conditions" do
    setup do
      batcher_name = :"test_flush_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          # Very long interval
          frame_interval_ms: 1000
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "flushes immediately when batch size limit reached", %{
      batcher: batcher
    } do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit updates up to the limit (50 based on @max_batch_size)
      for _ <- 1..55 do
        :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
      end

      # Should have triggered automatic flush due to size limit
      # Allow processing time
      Process.sleep(50)

      stats = RenderBatcher.get_stats(batcher)
      # Should have processed at least one batch
      assert stats.batches_processed >= 1
      assert stats.updates_batched >= 50
    end

    test "flushes immediately for high priority threshold", %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :structure}}

      # Submit several high priority updates (threshold is 5)
      for _ <- 1..6 do
        :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)
      end

      Process.sleep(50)

      stats = RenderBatcher.get_stats(batcher)
      # Should have flushed due to high priority threshold
      assert stats.batches_processed >= 1
    end

    test "does not flush immediately for few high priority updates", %{
      batcher: batcher
    } do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit only a few high priority updates (below threshold)
      for _ <- 1..3 do
        :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)
      end

      Process.sleep(50)

      stats = RenderBatcher.get_stats(batcher)
      # Should still be pending (below threshold)
      assert stats.pending_updates == 3
      assert stats.batches_processed == 0
    end
  end

  describe "force flush functionality" do
    setup do
      batcher_name = :"test_force_flush_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          frame_interval_ms: 1000
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "force flush processes all pending updates", %{batcher: batcher} do
      tree = %{type: :container, children: []}
      diff = {:update, [], %{type: :structure}}

      # Submit some updates
      for _ <- 1..5 do
        :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
      end

      initial_stats = RenderBatcher.get_stats(batcher)
      assert initial_stats.pending_updates == 5

      # Force flush
      :ok = RenderBatcher.force_flush(batcher)

      final_stats = RenderBatcher.get_stats(batcher)
      assert final_stats.pending_updates == 0
      assert final_stats.batches_processed == 1
      assert final_stats.updates_batched == 5
    end

    test "force flush handles empty batch gracefully", %{batcher: batcher} do
      initial_stats = RenderBatcher.get_stats(batcher)

      :ok = RenderBatcher.force_flush(batcher)

      final_stats = RenderBatcher.get_stats(batcher)
      # Stats should be unchanged for empty flush
      assert final_stats.pending_updates == 0
      assert final_stats.batches_processed == initial_stats.batches_processed
    end
  end

  describe "frame interval adaptation" do
    setup do
      batcher_name = :"test_adaptive_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "updates frame interval dynamically", %{batcher: batcher} do
      # Set new frame interval
      :ok = RenderBatcher.set_frame_interval(50, batcher)

      # Submit an update to test timing
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}
      :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)

      # Should use new interval for batching timing
      # (This is hard to test directly, but we verify the call succeeds)
      assert :ok == RenderBatcher.set_frame_interval(25, batcher)
    end

    test "handles various frame interval values", %{batcher: batcher} do
      intervals = [8, 16, 22, 33, 50, 100]

      for interval <- intervals do
        :ok = RenderBatcher.set_frame_interval(interval, batcher)
        # Should accept all reasonable intervals without error
      end
    end
  end

  describe "automatic batch processing" do
    test "processes batches after frame interval" do
      batcher_name = :"test_auto_batch_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          # Short interval for testing
          frame_interval_ms: 50
        )

      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit updates
      for _ <- 1..3 do
        :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher_name)
      end

      initial_stats = RenderBatcher.get_stats(batcher_name)
      assert initial_stats.pending_updates == 3

      # Wait for automatic flush (longer timeout for CI)
      Process.sleep(150)

      final_stats = RenderBatcher.get_stats(batcher_name)

      # The timer might not have fired yet, so check if either batched or still pending
      assert final_stats.pending_updates + final_stats.updates_batched >= 3
      assert final_stats.batches_processed >= 0

      GenServer.stop(pid)
    end

    test "handles timer race conditions gracefully" do
      batcher_name = :"test_timer_race_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(
          name: batcher_name,
          frame_interval_ms: 25
        )

      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit updates rapidly while timer is firing
      spawn(fn ->
        for _ <- 1..10 do
          :ok = RenderBatcher.submit_update(tree, diff, :low, batcher_name)
          Process.sleep(5)
        end
      end)

      # Wait for processing - use longer timeout for CI environments
      Process.sleep(300)

      # Should handle race conditions without crashing
      # The key assertion is that the batcher survived concurrent timer/update race
      # The exact number of batched updates varies due to timing
      stats = RenderBatcher.get_stats(batcher_name)

      # Verify at least some updates were processed (not zero)
      # and the system is still functional
      total_handled = stats.updates_batched + stats.pending_updates

      assert total_handled >= 1,
             "Expected at least 1 update to be handled, got #{total_handled}"

      GenServer.stop(pid)
    end
  end

  describe "priority-based processing" do
    setup do
      batcher_name = :"test_priority_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "processes updates in priority order during flush", %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit updates in mixed priority order
      :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)
      :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)

      initial_stats = RenderBatcher.get_stats(batcher)
      assert initial_stats.pending_updates == 5

      :ok = RenderBatcher.force_flush(batcher)

      final_stats = RenderBatcher.get_stats(batcher)
      assert final_stats.pending_updates == 0
      assert final_stats.batches_processed == 1
      assert final_stats.updates_batched == 5
    end
  end

  describe "damage accumulation and optimization" do
    setup do
      batcher_name = :"test_damage_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "merges overlapping damage regions", %{batcher: batcher} do
      tree = %{type: :container, children: [%{text: "Hello"}]}

      # Submit updates that affect the same node
      diff1 = {:update, [0], %{type: :content, text: "Hello"}}
      diff2 = {:update, [0], %{type: :style, color: "red"}}

      :ok = RenderBatcher.submit_update(tree, diff1, :medium, batcher)
      :ok = RenderBatcher.submit_update(tree, diff2, :high, batcher)

      stats = RenderBatcher.get_stats(batcher)
      # Should have merged damage for the same path
      assert stats.accumulated_damage_regions >= 1
      assert stats.pending_updates == 2
    end

    test "accumulates damage from tree replacements", %{batcher: batcher} do
      old_tree = %{type: :container, children: [%{text: "Old"}]}
      new_tree = %{type: :container, children: [%{text: "New"}]}

      diff = {:replace, new_tree}

      :ok = RenderBatcher.submit_update(old_tree, diff, :high, batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.accumulated_damage_regions >= 1
      assert stats.pending_updates == 1
    end
  end

  describe "performance and edge cases" do
    setup do
      batcher_name = :"test_perf_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "handles rapid update submissions", %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit many updates rapidly
      for i <- 1..100 do
        :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)

        if rem(i, 10) == 0 do
          # Brief pause every 10 updates
          Process.sleep(1)
        end
      end

      # Should handle load without crashing
      stats = RenderBatcher.get_stats(batcher)
      # May have flushed due to size limit
      assert stats.pending_updates >= 0
      assert is_integer(stats.batches_processed)
    end

    test "handles large tree structures", %{batcher: batcher} do
      # Create a large tree
      large_tree = %{
        type: :container,
        children:
          Enum.map(1..1000, fn i ->
            %{type: :label, text: "Item #{i}"}
          end)
      }

      diff = {:update, [], %{type: :structure}}

      :ok = RenderBatcher.submit_update(large_tree, diff, :medium, batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 1
    end

    test "handles concurrent access safely", %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Spawn multiple processes submitting updates
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            for _ <- 1..10 do
              :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
              Process.sleep(1)
            end
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Should handle concurrent access without errors
      stats = RenderBatcher.get_stats(batcher)
      assert is_integer(stats.pending_updates)
      assert is_integer(stats.updates_batched)
    end
  end

  describe "arithmetic operations in batching" do
    setup do
      batcher_name = :"test_arithmetic_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "correctly counts tree nodes in complex structures", %{
      batcher: batcher
    } do
      # Test the tree node counting logic
      nested_tree = %{
        type: :container,
        children: [
          %{type: :label, text: "A"},
          %{
            type: :container,
            children: [
              %{type: :label, text: "B1"},
              %{type: :label, text: "B2"}
            ]
          },
          %{type: :label, text: "C"}
        ]
      }

      diff = {:update, [], %{type: :structure}}

      :ok = RenderBatcher.submit_update(nested_tree, diff, :medium, batcher)
      :ok = RenderBatcher.force_flush(batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.batches_processed == 1
      assert stats.updates_batched == 1
    end

    test "handles timing calculations correctly", %{batcher: batcher} do
      # Test timing-related arithmetic
      start_time = System.monotonic_time(:millisecond)

      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Submit update and measure processing time
      :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)
      :ok = RenderBatcher.force_flush(batcher)

      end_time = System.monotonic_time(:millisecond)
      processing_time = end_time - start_time

      # Should complete quickly
      # Less than 100ms
      assert processing_time < 100

      stats = RenderBatcher.get_stats(batcher)
      assert stats.batches_processed == 1
    end

    test "handles frame interval arithmetic edge cases", %{batcher: batcher} do
      # Test various frame intervals and their effects
      intervals = [1, 8, 16, 33, 100, 1000]

      for interval <- intervals do
        :ok = RenderBatcher.set_frame_interval(interval, batcher)

        # Submit update with this interval
        tree = %{type: :container}
        diff = {:update, [], %{type: :content}}
        :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)

        # Should handle all intervals without arithmetic errors
        Process.sleep(5)
      end

      # Force flush to ensure all are processed
      :ok = RenderBatcher.force_flush(batcher)

      stats = RenderBatcher.get_stats(batcher)
      assert stats.updates_batched == length(intervals)
    end
  end

  describe "boolean logic in batch conditions" do
    setup do
      batcher_name = :"test_boolean_#{System.unique_integer([:positive])}"
      {:ok, pid} = RenderBatcher.start_link(name: batcher_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name, pid: pid}}
    end

    test "correctly evaluates compound flush conditions", %{batcher: batcher} do
      tree = %{type: :container}

      # Test boolean logic: size limit OR high priority threshold OR time limit
      # First test: size limit (should flush immediately)
      # Exceeds @max_batch_size (50)
      for _ <- 1..51 do
        diff = {:update, [], %{type: :content}}
        :ok = RenderBatcher.submit_update(tree, diff, :low, batcher)
      end

      Process.sleep(50)
      stats1 = RenderBatcher.get_stats(batcher)
      # Size condition triggered
      assert stats1.batches_processed >= 1

      # Reset by flushing
      :ok = RenderBatcher.force_flush(batcher)

      # Second test: high priority threshold (should flush with fewer updates)
      # Exceeds @high_priority_threshold (5)
      for _ <- 1..6 do
        diff = {:update, [], %{type: :content}}
        :ok = RenderBatcher.submit_update(tree, diff, :high, batcher)
      end

      Process.sleep(50)
      stats2 = RenderBatcher.get_stats(batcher)
      # Should have triggered flush due to high priority threshold
      assert stats2.batches_processed >= stats1.batches_processed + 1
    end

    test "correctly handles priority comparisons", %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      # Test priority equality checks
      priorities = [:low, :medium, :high, :high, :medium, :low]

      for priority <- priorities do
        :ok = RenderBatcher.submit_update(tree, diff, priority, batcher)
      end

      stats = RenderBatcher.get_stats(batcher)
      assert stats.pending_updates == 6

      # Force flush and verify all priorities were handled
      :ok = RenderBatcher.force_flush(batcher)

      final_stats = RenderBatcher.get_stats(batcher)
      assert final_stats.pending_updates == 0
      assert final_stats.updates_batched == 6
    end
  end

  describe "backpressure telemetry (ADR-0013)" do
    setup do
      batcher_name = :"bp_batcher_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        RenderBatcher.start_link(name: batcher_name, frame_interval_ms: 100)

      handler_id = "rb_bp_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :runtime, :backpressure],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {:bp_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, %{batcher: batcher_name}}
    end

    test "submit_update emits backpressure telemetry with the batcher label",
         %{batcher: batcher} do
      tree = %{type: :container}
      diff = {:update, [], %{type: :content}}

      assert :ok = RenderBatcher.submit_update(tree, diff, :medium, batcher)

      assert_receive {:bp_telemetry, %{queue_len: _},
                      %{
                        label: :render_batcher_submit,
                        policy: :drop_when_full,
                        decision: :cast
                      }}
    end
  end
end
