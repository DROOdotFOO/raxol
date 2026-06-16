defmodule Raxol.UI.Rendering.RenderBatcher do
  @moduledoc """
  Batches multiple render requests within animation frames to optimize performance.
  Coalesces rapid UI updates into single render operations.

  ## Features
  - Frame-based batching (16ms default)
  - Priority-based processing
  - Damage accumulation
  - Adaptive batching based on complexity
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Core.Runtime.Log

  alias Raxol.UI.Rendering.DamageTracker

  @default_frame_interval_ms Raxol.Constants.default_frame_interval_ms()
  @max_batch_size 50
  @high_priority_threshold 5

  # Accessor function for module attributes (needed for nested modules)
  def default_frame_interval_ms, do: @default_frame_interval_ms

  defmodule BatchState do
    @moduledoc false

    @default_frame_interval_ms Raxol.Constants.default_frame_interval_ms()

    defstruct pending_updates: [],
              accumulated_damage: %{},
              batch_timer_ref: nil,
              frame_interval_ms: @default_frame_interval_ms,
              last_flush_time: nil,
              stats: %{batches_processed: 0, updates_batched: 0}
  end

  # Public API

  @doc """
  Submits a render update to the batcher.
  Updates are accumulated until the next frame flush.

  Uses `:drop_when_full` backpressure: when the batcher's
  mailbox exceeds the watermark, the update is dropped and the next
  non-dropped update's diff naturally subsumes it. Drops surface via
  `[:raxol, :runtime, :backpressure]` telemetry with
  `label: :render_batcher_submit`. The return value remains `:ok`
  regardless of the delivery decision.
  """
  @spec submit_update(
          tree :: map(),
          diff_result :: term(),
          priority :: :low | :medium | :high,
          pid() | atom()
        ) :: :ok
  def submit_update(
        tree,
        diff_result,
        priority \\ :medium,
        batcher \\ __MODULE__
      ) do
    _ =
      Backpressure.cast(
        batcher,
        {:submit_update, tree, diff_result, priority,
         System.monotonic_time(:millisecond)},
        label: :render_batcher_submit,
        policy: :drop_when_full
      )

    :ok
  end

  @doc """
  Performs batch rendering of a buffer with optimizations.
  This is a convenience function for benchmarking.
  """
  @spec batch_render(buffer :: term(), opts :: keyword()) :: {:ok, term()}
  def batch_render(buffer, _opts \\ []) do
    # For benchmarking purposes, simulate batch rendering
    # In a real implementation, this would batch multiple render operations
    {:ok, buffer}
  end

  @doc """
  Forces an immediate flush of all pending updates.
  Used for high-priority updates that can't wait for next frame.
  """
  @spec force_flush(pid() | atom()) :: :ok
  def force_flush(batcher \\ __MODULE__) do
    GenServer.call(batcher, :force_flush)
  end

  @doc """
  Gets current batching statistics.
  """
  @spec get_stats(pid() | atom()) :: map()
  def get_stats(batcher \\ __MODULE__) do
    GenServer.call(batcher, :get_stats)
  end

  @doc """
  Updates the frame interval for adaptive batching.
  """
  @spec set_frame_interval(pos_integer(), pid() | atom()) :: :ok
  def set_frame_interval(interval_ms, batcher \\ __MODULE__) do
    GenServer.cast(batcher, {:set_frame_interval, interval_ms})
  end

  # GenServer Implementation

  @impl true
  def init_manager(opts) do
    frame_interval =
      Keyword.get(opts, :frame_interval_ms, @default_frame_interval_ms)

    state = %BatchState{
      frame_interval_ms: frame_interval,
      last_flush_time: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_cast(
        {:submit_update, tree, diff_result, priority, timestamp},
        state
      ) do
    Raxol.Core.Runtime.Log.debug(
      "RenderBatcher: Received update with priority #{priority}"
    )

    # Compute damage for this update
    damage = DamageTracker.compute_damage(diff_result, tree)

    # Create update record
    update = %{
      tree: tree,
      diff_result: diff_result,
      priority: priority,
      timestamp: timestamp,
      damage: damage
    }

    # Accumulate damage and add to pending updates
    new_accumulated_damage =
      DamageTracker.merge_damage(state.accumulated_damage, damage)

    new_pending_updates = [update | state.pending_updates]

    new_state = %{
      state
      | pending_updates: new_pending_updates,
        accumulated_damage: new_accumulated_damage
    }

    # Determine if we should process immediately
    final_state = maybe_schedule_flush(new_state, priority)

    {:noreply, final_state}
  end

  @impl true
  def handle_manager_cast({:set_frame_interval, interval_ms}, state) do
    {:noreply, %{state | frame_interval_ms: interval_ms}}
  end

  @impl true
  def handle_manager_call(:force_flush, _from, state) do
    Raxol.Core.Runtime.Log.debug("RenderBatcher: Force flush requested")

    new_state = flush_pending_updates(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        pending_updates: length(state.pending_updates),
        accumulated_damage_regions: map_size(state.accumulated_damage)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_info(
        {:batch_flush, timer_ref},
        %{batch_timer_ref: timer_ref} = state
      ) do
    Raxol.Core.Runtime.Log.debug("RenderBatcher: Batch timer fired")

    new_state = flush_pending_updates(%{state | batch_timer_ref: nil})
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info({:batch_flush, _old_timer_ref}, state) do
    # Ignore stale timer messages
    {:noreply, state}
  end

  # Private Helper Functions

  defp maybe_schedule_flush(state, priority) do
    cond do
      should_flush_immediately?(state, priority) ->
        Raxol.Core.Runtime.Log.debug(
          "RenderBatcher: Flushing immediately due to conditions"
        )

        flush_pending_updates(state)

      state.batch_timer_ref == nil ->
        schedule_batch_flush(state)

      true ->
        state
    end
  end

  defp should_flush_immediately?(state, priority) do
    length(state.pending_updates) >= @max_batch_size or
      (priority == :high and
         count_high_priority_updates(state.pending_updates) >=
           @high_priority_threshold) or
      time_since_last_flush(state) > state.frame_interval_ms * 2
  end

  defp count_high_priority_updates(updates) do
    Enum.count(updates, fn update -> update.priority == :high end)
  end

  defp time_since_last_flush(state) do
    System.monotonic_time(:millisecond) - (state.last_flush_time || 0)
  end

  defp schedule_batch_flush(state) do
    timer_ref =
      Process.send_after(
        self(),
        {:batch_flush, make_ref()},
        state.frame_interval_ms
      )

    Raxol.Core.Runtime.Log.debug(
      "RenderBatcher: Scheduled flush in #{state.frame_interval_ms}ms"
    )

    %{state | batch_timer_ref: timer_ref}
  end

  defp flush_pending_updates(%{pending_updates: []} = state) do
    # No updates to flush
    state
  end

  defp flush_pending_updates(state) do
    # Process in submission order
    updates = Enum.reverse(state.pending_updates)

    Raxol.Core.Runtime.Log.debug(
      "RenderBatcher: Flushing #{length(updates)} updates with #{map_size(state.accumulated_damage)} damage regions"
    )

    # Group updates by priority
    grouped_updates = Enum.group_by(updates, & &1.priority)

    # Process high priority first, then medium, then low
    [:high, :medium, :low]
    |> Enum.each(fn priority ->
      priority_updates = Map.get(grouped_updates, priority, [])
      process_priority_batch(priority_updates, state.accumulated_damage)
    end)

    # Cancel existing timer if any
    _ = cancel_batch_timer(state.batch_timer_ref)

    # Update statistics
    new_stats = %{
      state.stats
      | batches_processed: state.stats.batches_processed + 1,
        updates_batched: state.stats.updates_batched + length(updates)
    }

    # Reset state
    %{
      state
      | pending_updates: [],
        accumulated_damage: %{},
        batch_timer_ref: nil,
        last_flush_time: System.monotonic_time(:millisecond),
        stats: new_stats
    }
  end

  defp process_priority_batch([], _accumulated_damage), do: :ok

  defp process_priority_batch(updates, accumulated_damage) do
    # For now, just take the latest tree from the batch
    # More sophisticated merging could be implemented here
    latest_update = List.last(updates)

    # Optimize damage regions
    optimized_damage = DamageTracker.optimize_damage_regions(accumulated_damage)

    Raxol.Core.Runtime.Log.info(
      "RenderBatcher: Processing batch of #{length(updates)} updates with optimized damage"
    )

    # Send to pipeline for actual rendering
    # This would integrate with the main rendering pipeline
    send_to_pipeline(
      latest_update.tree,
      latest_update.diff_result,
      optimized_damage
    )
  end

  defp send_to_pipeline(tree, _diff_result, damage_regions) do
    # This would call the main rendering pipeline
    # For now, just log the action
    Log.debug(
      "RenderBatcher: Would send to pipeline - tree nodes: #{count_tree_nodes(tree)}, damage regions: #{map_size(damage_regions)}"
    )
  end

  defp cancel_batch_timer(nil), do: :ok
  defp cancel_batch_timer(timer_ref), do: _ = Process.cancel_timer(timer_ref)

  defp count_tree_nodes(%{children: children}) when is_list(children) do
    1 + Enum.sum(Enum.map(children, &count_tree_nodes/1))
  end

  defp count_tree_nodes(_), do: 1
end
