defmodule Raxol.Workflow.Runtime do
  @moduledoc """
  Execution runtime for `Raxol.Workflow.Compiled` graphs.

  Implements the synchronous `invoke/3` and `resume/4` paths.
  Walks the graph from `:__start__` to `:__end__`,
  executes each node according to its descriptor type, dispatches any
  returned directives through `Raxol.Core.Runtime.Directive.Executor`,
  and emits per-node telemetry with full trace context
  (trace_id, span_id, parent_span_id, causation_id) propagated through
  `TraceContext`.

  ## Capabilities

    * Per-attempt span + telemetry, with retry under
      `failure_policy: :retry` (configurable `max_attempts` and
      `retry_backoff_ms`).
    * Saga-style compensation under `failure_policy: :compensate`,
      walking executed nodes in reverse and emitting `node.compensated`
      events.
    * Optional `Checkpoint.Saver`-backed durability. Fresh runs
      pre-checkpoint the initial state at step 0 so resumes work even
      when the very first node interrupts.
    * Human-in-the-loop pauses via `Workflow.interrupt/1` and
      `Compiled.resume/4`.

  Async wrappers (`async_invoke`, `stream_events`, `async_resume`,
  `resume_events`) live in `Raxol.Workflow.Async`. Joins
  (`add_join/4`) and channel reducers (`add_channel/4`) are still
  follow-ups: the runtime is single-branch sequential today.
  """

  alias Raxol.Core.Runtime.Directive
  alias Raxol.Core.Telemetry.TraceContext
  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Edge.ConditionalEdge
  alias Raxol.Workflow.Edge.Edge, as: StaticEdge
  alias Raxol.Workflow.Edge.GuardedEdge
  alias Raxol.Workflow.Edge.JoinEdge
  alias Raxol.Workflow.Execution.Scratchpad
  alias Raxol.Workflow.Node, as: WorkflowNode
  alias Raxol.Workflow.Node.{BehaviourNode, FunctionNode, TypedNode}
  alias Raxol.Workflow.Runtime.BranchMerge

  @executed_key :__raxol_workflow_executed__
  @branch_id_key :__raxol_workflow_branch_id__
  @fan_out_key :__raxol_workflow_fan_out__

  # Per-branch step offset so concurrent checkpoints don't collide on
  # the saver's `(thread_id, step)` key.
  @branch_step_stride 1_000_000

  @start :__start__
  @end_ :__end__

  @default_run_timeout_ms 60_000
  @default_max_attempts 3
  @default_retry_backoff_ms 100

  @type result ::
          {:ok, state :: any(), meta :: map()}
          | {:interrupted, run_id :: binary(), state :: any(), value :: any()}
          | {:error, reason :: any(), state :: any()}

  @doc """
  Run the compiled graph synchronously.

  `opts` may include `:run_timeout_ms` (default 60_000) to bound the
  total wall-clock time. Returns one of:

    * `{:ok, final_state, %{run_id, nodes_executed}}`
    * `{:interrupted, run_id, state, value}` when a node returns `{:interrupt, value}`
    * `{:error, reason, state}` on node failure, raised exception, or walltime exceeded
  """
  @spec invoke(Compiled.t(), any(), keyword()) :: result()
  def invoke(%Compiled{} = compiled, initial_state, opts \\ []) do
    %{
      run_id: run_id,
      deadline_us: deadline_us,
      resume_from: resume_from,
      resume_mode: resume_mode,
      start_count: start_count,
      count_offset: count_offset
    } = prepare_invocation(compiled, initial_state, opts)

    Process.put(@executed_key, [])

    try do
      emit_run_event(:started, %{run_id: run_id, graph_id: compiled.id})

      compiled
      |> start_or_resume(
        initial_state,
        run_id,
        deadline_us,
        start_count,
        resume_from,
        resume_mode
      )
      |> maybe_compensate_on_error(compiled, run_id)
      |> wrap_outcome(run_id, compiled.id, count_offset)
    after
      _ = TraceContext.clear()
      Scratchpad.clear()
      Process.delete(@executed_key)
    end
  end

  defp prepare_invocation(compiled, initial_state, opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &generate_run_id/0)
    deadline_us = monotonic_us() + resolve_timeout(opts, compiled) * 1_000
    resume_from = Keyword.get(opts, :resume_from)
    resume_mode = Keyword.get(opts, :resume_mode, :traverse)
    initial_count = Keyword.get(opts, :initial_step, 0)
    resume_values = Keyword.get(opts, :resume_values, [])

    _ = TraceContext.start_trace()
    maybe_seed_scratchpad(run_id, resume_values)

    start_count =
      maybe_persist_initial_checkpoint(
        compiled,
        initial_state,
        run_id,
        resume_from,
        initial_count
      )

    %{
      run_id: run_id,
      deadline_us: deadline_us,
      resume_from: resume_from,
      resume_mode: resume_mode,
      start_count: start_count,
      count_offset: start_count - initial_count
    }
  end

  # Fresh runs pre-checkpoint the initial state at step 0 with
  # node_id: :__start__. This lets `resume/4` work when the very first
  # node interrupts (otherwise there would be no predecessor checkpoint
  # to hydrate). Resumes (resume_from != nil or initial_count > 0) skip
  # this so the existing step 0 checkpoint is not overwritten.
  defp maybe_persist_initial_checkpoint(
         compiled,
         initial_state,
         run_id,
         nil,
         0
       ) do
    persist_initial_checkpoint(compiled, initial_state, run_id)
    1
  end

  defp maybe_persist_initial_checkpoint(_, _, _, _, initial_count),
    do: initial_count

  defp persist_initial_checkpoint(compiled, state, run_id) do
    case Saver.normalize(Map.get(compiled.opts, :saver)) do
      nil ->
        :ok

      {saver_module, saver_config} ->
        checkpoint =
          Checkpoint.new(
            thread_id: run_id,
            step: 0,
            state: state,
            parent_step: nil,
            metadata: %{
              node_id: @start,
              run_id: run_id,
              graph_id: compiled.id,
              branch_id: nil
            }
          )

        saver_module.put(saver_config, run_id, checkpoint)
    end
  end

  defp start_or_resume(compiled, state, run_id, deadline_us, count, nil, _mode) do
    step(compiled, @start, state, run_id, deadline_us, count)
  end

  defp start_or_resume(
         compiled,
         state,
         run_id,
         deadline_us,
         count,
         resume_node,
         :traverse
       )
       when is_atom(resume_node) or is_binary(resume_node) do
    # The resume node already executed successfully on the prior run; just
    # traverse outgoing edges to find the next node to execute.
    traverse(compiled, resume_node, state, run_id, deadline_us, count)
  end

  defp start_or_resume(
         compiled,
         state,
         run_id,
         deadline_us,
         count,
         resume_node,
         :reenter
       )
       when is_atom(resume_node) or is_binary(resume_node) do
    # The resume node interrupted on the prior run; the scratchpad has
    # been seeded with the resume value, so re-execute the node and let
    # `Workflow.interrupt/1` return that value instead of throwing.
    step(compiled, resume_node, state, run_id, deadline_us, count)
  end

  defp maybe_seed_scratchpad(_run_id, []), do: :ok

  defp maybe_seed_scratchpad(run_id, values),
    do: Scratchpad.init(run_id, values)

  @doc """
  Resume an interrupted run from its latest checkpoint.

  Reads the latest checkpoint for `run_id` via the configured Saver,
  hydrates the state, seeds the scratchpad with `resume_value`, and
  continues execution from the node *after* the checkpoint's node
  (which is the node that interrupted on the prior run). Re-invokes
  `interrupt/1` from inside that node returns the resume value
  instead of throwing.

  Returns the same result tuple shape as `invoke/3`.

  ## Errors

    * `{:error, :no_saver_configured, nil}` when the graph has no Saver
    * `{:error, :no_checkpoint, nil}` when the thread has no recorded
      checkpoints
  """
  @spec resume(Compiled.t(), binary(), any(), keyword()) ::
          result() | {:error, :no_saver_configured | :no_checkpoint, nil}
  def resume(%Compiled{} = compiled, run_id, resume_value, opts \\ [])
      when is_binary(run_id) do
    case preflight_resume(compiled, run_id) do
      {:ok, checkpoint} ->
        resume_with_checkpoint(
          compiled,
          checkpoint,
          resume_value,
          run_id,
          opts
        )

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  @doc """
  Look up the latest checkpoint for `run_id` via the configured Saver,
  without applying it. Used by `Raxol.Workflow.Async` to surface
  resume preconditions synchronously before spawning a worker.

  Returns `{:ok, checkpoint}` when a checkpoint is found,
  `{:error, :no_saver_configured}` when the graph has no Saver, or
  `{:error, :no_checkpoint}` when no checkpoint exists for `run_id`.
  """
  @spec preflight_resume(Compiled.t(), binary()) ::
          {:ok, Checkpoint.t()}
          | {:error, :no_saver_configured | :no_checkpoint}
  def preflight_resume(%Compiled{} = compiled, run_id) when is_binary(run_id) do
    case Saver.normalize(Map.get(compiled.opts, :saver)) do
      nil ->
        {:error, :no_saver_configured}

      {saver_module, saver_config} ->
        case saver_module.get_latest(saver_config, run_id) do
          {:ok, %Checkpoint{} = checkpoint} -> {:ok, checkpoint}
          {:error, :not_found} -> {:error, :no_checkpoint}
        end
    end
  end

  defp resume_with_checkpoint(compiled, checkpoint, resume_value, run_id, opts) do
    resume_mode = resume_mode_for(checkpoint)
    interrupt_reason = Map.get(checkpoint.metadata, :interrupt_reason)
    branch_id = Map.get(checkpoint.metadata, :branch_id)

    emit_run_event(:resumed, %{
      run_id: run_id,
      graph_id: compiled.id,
      node_id: checkpoint.metadata.node_id,
      branch_id: branch_id,
      interrupt_reason: interrupt_reason,
      resume_mode: resume_mode
    })

    if branch_id != nil do
      resume_in_branch(
        compiled,
        checkpoint,
        branch_id,
        resume_value,
        run_id,
        opts
      )
    else
      resume_opts =
        opts
        |> Keyword.put(:run_id, run_id)
        |> Keyword.put(:resume_from, checkpoint.metadata.node_id)
        |> Keyword.put(:resume_mode, resume_mode)
        |> Keyword.put(:initial_step, checkpoint.step + 1)
        |> Keyword.put(:resume_values, [resume_value])

      invoke(compiled, checkpoint.state, resume_opts)
    end
  end

  defp resume_in_branch(
         compiled,
         checkpoint,
         {join_target, paused_index},
         resume_value,
         run_id,
         opts
       ) do
    augmented_state = checkpoint.state
    continuation = Map.get(augmented_state, @fan_out_key)
    paused_node_id = checkpoint.metadata.node_id

    deadline_us = monotonic_us() + resolve_timeout(opts, compiled) * 1_000
    initial_count = checkpoint.step + 1

    Process.put(@executed_key, [])
    _ = TraceContext.start_trace()
    maybe_seed_scratchpad(run_id, [resume_value])

    try do
      finish_branch_then_continue(
        compiled,
        continuation,
        {join_target, paused_index},
        paused_node_id,
        run_id,
        deadline_us,
        initial_count
      )
      |> maybe_compensate_on_error(compiled, run_id)
      |> wrap_outcome(run_id, compiled.id, 0)
    after
      _ = TraceContext.clear()
      Scratchpad.clear()
      Process.delete(@executed_key)
      Process.delete(@branch_id_key)
    end
  end

  defp finish_branch_then_continue(
         compiled,
         continuation,
         {join_target, paused_index},
         paused_node_id,
         run_id,
         deadline_us,
         count
       ) do
    {:paused, ^paused_node_id, state_at_interrupt, _reason} =
      Enum.at(continuation.slots, paused_index)

    result =
      with_branch_id({join_target, paused_index}, fn ->
        step_branch(
          compiled,
          paused_node_id,
          state_at_interrupt,
          run_id,
          deadline_us,
          count,
          join_target
        )
      end)

    case result do
      {:branch_done, branch_state, new_count} ->
        updated = update_slot(continuation, paused_index, {:done, branch_state})

        process_next_after_resume(
          compiled,
          updated,
          run_id,
          deadline_us,
          new_count
        )

      {:branch_paused, value, state_at_interrupt2, paused_node_id2, new_count} ->
        new_slot = {:paused, paused_node_id2, state_at_interrupt2, value}
        updated = update_slot(continuation, paused_index, new_slot)
        re_interrupt_for_branch_pause(compiled, updated, run_id, new_count)

      {:error, _reason, _state, _count} = err ->
        err
    end
  end

  defp process_next_after_resume(
         compiled,
         continuation,
         run_id,
         deadline_us,
         count
       ) do
    case first_paused_slot(continuation.slots) do
      nil ->
        finalize_join(compiled, continuation, run_id, deadline_us, count)

      _ ->
        re_interrupt_for_branch_pause(compiled, continuation, run_id, count)
    end
  end

  defp finalize_join(compiled, continuation, run_id, deadline_us, count) do
    branch_states = Enum.map(continuation.slots, fn {:done, st} -> st end)
    join = Map.fetch!(compiled.joins_by_node, continuation.join_target)
    merged = BranchMerge.merge(branch_states, join, compiled.channels)

    # Continuation served its purpose; strip it before continuing from
    # the join so downstream sequential nodes don't see runtime
    # bookkeeping.
    cleaned = Map.delete(merged, @fan_out_key)

    step(
      compiled,
      continuation.join_target,
      cleaned,
      run_id,
      deadline_us,
      count
    )
  end

  defp re_interrupt_for_branch_pause(compiled, continuation, run_id, count) do
    {next_idx, next_node, _state, reason} =
      first_paused_slot(continuation.slots)

    augmented_state =
      Map.put(continuation.source_state, @fan_out_key, continuation)

    _ =
      with_branch_id({continuation.join_target, next_idx}, fn ->
        case persist_pause_checkpoint(
               compiled,
               next_node,
               augmented_state,
               run_id,
               count,
               reason
             ) do
          :ok ->
            emit_run_event(:paused, %{
              run_id: run_id,
              graph_id: compiled.id,
              node_id: next_node,
              branch_id: {continuation.join_target, next_idx},
              interrupt_reason: reason,
              paused_at: DateTime.utc_now()
            })

          :no_saver ->
            :ok
        end
      end)

    {:interrupted, augmented_state, reason, count}
  end

  defp update_slot(continuation, index, new_slot) do
    %{
      continuation
      | slots: List.replace_at(continuation.slots, index, new_slot)
    }
  end

  # A checkpoint with `:interrupt_reason` in metadata is a pause
  # checkpoint: the node interrupted on the prior run and the runtime
  # must re-execute it. A normal successful-node checkpoint resumes by
  # traversing past the node, matching the original traversal semantics.
  defp resume_mode_for(%Checkpoint{metadata: %{interrupt_reason: reason}})
       when not is_nil(reason),
       do: :reenter

  defp resume_mode_for(_checkpoint), do: :traverse

  defp resolve_timeout(opts, compiled) do
    Keyword.get(
      opts,
      :run_timeout_ms,
      Map.get(compiled.opts, :run_timeout_ms, @default_run_timeout_ms)
    )
  end

  defp track_executed(node) do
    Process.put(@executed_key, [node | Process.get(@executed_key, [])])
  end

  defp executed_nodes, do: Process.get(@executed_key, [])

  defp current_branch_id, do: Process.get(@branch_id_key)

  defp with_branch_id(branch_id, fun) when is_function(fun, 0) do
    prior = Process.get(@branch_id_key)
    Process.put(@branch_id_key, branch_id)

    try do
      fun.()
    after
      if prior == nil do
        Process.delete(@branch_id_key)
      else
        Process.put(@branch_id_key, prior)
      end
    end
  end

  # Under failure_policy: :compensate, the runtime walks the executed
  # nodes in reverse and runs each one's compensate function. The
  # state threads through compensations so an earlier compensation
  # sees the result of a later one. Compensation errors are surfaced
  # through node.compensated telemetry but do not displace the run's
  # original failure reason.
  defp maybe_compensate_on_error(
         {:error, reason, state, count},
         compiled,
         run_id
       ) do
    if Map.get(compiled.opts, :failure_policy) == :compensate do
      new_state = run_compensations(executed_nodes(), state, compiled, run_id)
      {:error, reason, new_state, count}
    else
      {:error, reason, state, count}
    end
  end

  defp maybe_compensate_on_error(other, _compiled, _run_id), do: other

  defp run_compensations(nodes, state, compiled, run_id) do
    Enum.reduce(nodes, state, fn node, acc_state ->
      case do_compensate(node, acc_state) do
        {:ok, next_state} ->
          emit_node_event(:compensated, %{
            run_id: run_id,
            graph_id: compiled.id,
            node_id: WorkflowNode.id(node),
            result: :ok
          })

          next_state

        {:error, comp_reason} ->
          emit_node_event(:compensated, %{
            run_id: run_id,
            graph_id: compiled.id,
            node_id: WorkflowNode.id(node),
            result: {:error, comp_reason}
          })

          acc_state
      end
    end)
  end

  defp do_compensate(%FunctionNode{compensate_fun: nil}, state),
    do: {:ok, state}

  defp do_compensate(%FunctionNode{compensate_fun: fun}, state) do
    fun.(state)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_compensate(%BehaviourNode{module: mod, opts: opts}, state) do
    if function_exported?(mod, :compensate, 2) do
      mod.compensate(state, opts)
    else
      {:ok, state}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_compensate(%TypedNode{}, state), do: {:ok, state}

  defp wrap_outcome({:ok, final_state, count}, run_id, graph_id, offset) do
    nodes_executed = count - offset

    emit_run_event(:completed, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: nodes_executed
    })

    {:ok, final_state, %{run_id: run_id, nodes_executed: nodes_executed}}
  end

  defp wrap_outcome(
         {:interrupted, state, value, count},
         run_id,
         graph_id,
         offset
       ) do
    nodes_executed = count - offset

    emit_run_event(:interrupted, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: nodes_executed,
      value: value,
      interrupt_reason: value
    })

    {:interrupted, run_id, state, value}
  end

  defp wrap_outcome({:error, reason, state, count}, run_id, graph_id, offset) do
    nodes_executed = count - offset

    emit_run_event(:failed, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: nodes_executed,
      reason: reason
    })

    {:error, reason, state}
  end

  # --- Execution loop ---

  defp step(_compiled, @end_, state, _run_id, _deadline_us, count) do
    {:ok, state, count}
  end

  defp step(compiled, current_id, state, run_id, deadline_us, count) do
    cond do
      monotonic_us() >= deadline_us ->
        {:error, :run_timeout, state, count}

      current_id == @start ->
        # No work at start; just follow the outgoing edge.
        traverse(compiled, current_id, state, run_id, deadline_us, count)

      true ->
        execute_node_and_continue(
          compiled,
          current_id,
          state,
          run_id,
          deadline_us,
          count
        )
    end
  end

  defp execute_node_and_continue(
         compiled,
         current_id,
         state,
         run_id,
         deadline_us,
         count
       ) do
    case attempt_node_with_retry(compiled, current_id, state, run_id, 1) do
      {:node_ok, new_state, _tag} ->
        track_executed(Map.fetch!(compiled.nodes, current_id))
        persist_checkpoint(compiled, current_id, new_state, run_id, count)

        traverse(
          compiled,
          current_id,
          new_state,
          run_id,
          deadline_us,
          count + 1
        )

      {:interrupt, value, state_at_interrupt} ->
        handle_interrupt(
          compiled,
          current_id,
          state_at_interrupt,
          value,
          run_id,
          count
        )

      {:error, reason, state_at_error} ->
        {:error, reason, state_at_error, count + 1}
    end
  end

  # On interrupt, write a pause checkpoint with
  # `interrupt_reason` and `paused_at` in metadata so the run is
  # enumerable through `Saver.list_paused/2` and so resume knows to
  # re-enter the same node (versus traversing past it). The `:paused`
  # run event fires after the pause checkpoint commits; with no Saver
  # configured the event is suppressed because there is no durable
  # pause state to announce.
  defp handle_interrupt(compiled, current_id, state, value, run_id, count) do
    case persist_pause_checkpoint(
           compiled,
           current_id,
           state,
           run_id,
           count,
           value
         ) do
      :ok ->
        emit_run_event(:paused, %{
          run_id: run_id,
          graph_id: compiled.id,
          node_id: current_id,
          interrupt_reason: value,
          paused_at: DateTime.utc_now()
        })

      :no_saver ->
        :ok
    end

    {:interrupted, state, value, count + 1}
  end

  # Retry loop. Each attempt gets its own span + telemetry events; on
  # transient {:error, _} (including rescued exceptions and
  # {:invalid_result, _}) we sleep with exponential backoff and try
  # again, up to the configured max_attempts. Per-attempt telemetry
  # makes attempt counts and retry latencies observable.
  defp attempt_node_with_retry(compiled, current_id, state, run_id, attempt) do
    case execute_node_once(compiled, current_id, state, run_id) do
      {:error, _reason, _state} = err ->
        max = retry_max_attempts(compiled)

        if retry?(compiled) and attempt < max do
          Process.sleep(compute_backoff(retry_backoff_ms(compiled), attempt))

          attempt_node_with_retry(
            compiled,
            current_id,
            state,
            run_id,
            attempt + 1
          )
        else
          err
        end

      other ->
        other
    end
  end

  defp execute_node_once(compiled, current_id, state, run_id) do
    node = Map.fetch!(compiled.nodes, current_id)
    span_name = "workflow.node.#{inspect(current_id)}"
    _ = TraceContext.start_span(span_name)

    started_us = monotonic_us()

    emit_node_event(:started, %{
      run_id: run_id,
      graph_id: compiled.id,
      node_id: current_id,
      branch_id: current_branch_id()
    })

    try do
      finalize_attempt(
        run_node(node, state),
        compiled,
        current_id,
        state,
        run_id,
        started_us
      )
    rescue
      e ->
        message = Exception.message(e)

        end_span_and_emit(:failed, compiled, current_id, run_id, started_us, %{
          reason: {:exception, message}
        })

        {:error, {:exception, message}, state}
    catch
      :throw, {:__workflow_interrupt__, value} ->
        end_span_and_emit(
          :completed,
          compiled,
          current_id,
          run_id,
          started_us,
          %{
            result_type: :interrupt
          }
        )

        {:interrupt, value, state}
    end
  end

  defp finalize_attempt(
         {:ok, new_state},
         compiled,
         current_id,
         _state,
         run_id,
         started_us
       ) do
    end_span_and_emit(:completed, compiled, current_id, run_id, started_us, %{
      result_type: :ok
    })

    {:node_ok, new_state, :ok}
  end

  defp finalize_attempt(
         {:effects, directives, new_state},
         compiled,
         current_id,
         _state,
         run_id,
         started_us
       )
       when is_list(directives) do
    dispatch_effects(directives)

    end_span_and_emit(:completed, compiled, current_id, run_id, started_us, %{
      result_type: :effects
    })

    {:node_ok, new_state, :effects}
  end

  defp finalize_attempt(
         {:interrupt, value},
         compiled,
         current_id,
         state,
         run_id,
         started_us
       ) do
    end_span_and_emit(:completed, compiled, current_id, run_id, started_us, %{
      result_type: :interrupt
    })

    {:interrupt, value, state}
  end

  defp finalize_attempt(
         {:error, reason},
         compiled,
         current_id,
         state,
         run_id,
         started_us
       ) do
    end_span_and_emit(:failed, compiled, current_id, run_id, started_us, %{
      reason: reason
    })

    {:error, reason, state}
  end

  defp finalize_attempt(
         other,
         compiled,
         current_id,
         state,
         run_id,
         started_us
       ) do
    end_span_and_emit(:failed, compiled, current_id, run_id, started_us, %{
      reason: {:invalid_result, other}
    })

    {:error, {:invalid_result, other}, state}
  end

  defp end_span_and_emit(kind, compiled, current_id, run_id, started_us, extra) do
    _ = TraceContext.end_span()

    emit_node_event(
      kind,
      Map.merge(
        %{
          run_id: run_id,
          graph_id: compiled.id,
          node_id: current_id,
          duration_us: monotonic_us() - started_us,
          branch_id: current_branch_id()
        },
        extra
      )
    )
  end

  defp retry?(compiled),
    do: Map.get(compiled.opts, :failure_policy, :halt) == :retry

  defp retry_max_attempts(compiled),
    do: Map.get(compiled.opts, :max_attempts, @default_max_attempts)

  defp retry_backoff_ms(compiled),
    do: Map.get(compiled.opts, :retry_backoff_ms, @default_retry_backoff_ms)

  # Exponential backoff: base * 2^(attempt - 1). attempt is the
  # just-failed attempt number, so the first retry (attempt 1 -> 2)
  # waits `base`, the second waits `2 * base`, and so on.
  defp compute_backoff(base_ms, attempt) when attempt >= 1,
    do: base_ms * Bitwise.bsl(1, attempt - 1)

  defp persist_checkpoint(compiled, current_id, state, run_id, count) do
    case Saver.normalize(Map.get(compiled.opts, :saver)) do
      nil ->
        :ok

      {saver_module, saver_config} ->
        checkpoint =
          Checkpoint.new(
            thread_id: run_id,
            step: count,
            state: state,
            parent_step: parent_step_for(count),
            metadata: %{
              node_id: current_id,
              run_id: run_id,
              graph_id: compiled.id,
              branch_id: current_branch_id()
            }
          )

        saver_module.put(saver_config, run_id, checkpoint)
    end
  end

  # Pause checkpoint: same structure as a normal node checkpoint, plus
  # `interrupt_reason` and `paused_at` in metadata so
  # `Saver.list_paused/2` can enumerate suspended runs and so
  # `resume_mode_for/1` routes resume back into the same node. Returns
  # `:ok` on commit or `:no_saver` so the caller can suppress the
  # `:paused` lifecycle event when there is no durable pause state.
  defp persist_pause_checkpoint(
         compiled,
         current_id,
         state,
         run_id,
         count,
         reason
       ) do
    case Saver.normalize(Map.get(compiled.opts, :saver)) do
      nil ->
        :no_saver

      {saver_module, saver_config} ->
        checkpoint =
          Checkpoint.new(
            thread_id: run_id,
            step: count,
            state: state,
            parent_step: parent_step_for(count),
            metadata: %{
              node_id: current_id,
              run_id: run_id,
              graph_id: compiled.id,
              branch_id: current_branch_id(),
              interrupt_reason: reason,
              paused_at: DateTime.utc_now()
            }
          )

        saver_module.put(saver_config, run_id, checkpoint)
        :ok
    end
  end

  defp parent_step_for(0), do: nil
  defp parent_step_for(count) when count > 0, do: count - 1

  # --- Node execution ---

  defp run_node(%FunctionNode{fun: fun}, state), do: fun.(state)

  defp run_node(%BehaviourNode{module: module, opts: opts}, state) do
    module.run(state, opts)
  end

  defp run_node(%TypedNode{struct: struct}, state) do
    WorkflowNode.Executor.execute(struct, state, [])
  end

  # --- Edge traversal ---

  defp traverse(compiled, current_id, state, run_id, deadline_us, count) do
    outgoing = Map.get(compiled.edges_by_source, current_id, [])

    case pick_next(outgoing, state) do
      {:ok, next_id} when is_atom(next_id) or is_binary(next_id) ->
        step(compiled, next_id, state, run_id, deadline_us, count)

      {:ok, branch_ids} when is_list(branch_ids) ->
        fan_out(compiled, branch_ids, state, run_id, deadline_us, count)

      :no_match ->
        {:error, {:no_outgoing_edge_matched, current_id}, state, count}

      {:error, reason} ->
        {:error, reason, state, count}
    end
  end

  defp pick_next([], _state), do: :no_match

  defp pick_next([%StaticEdge{to: to} | _rest], _state), do: {:ok, to}

  defp pick_next([%GuardedEdge{to: to, guard: guard} | rest], state) do
    if guard.(state), do: {:ok, to}, else: pick_next(rest, state)
  end

  defp pick_next(
         [%ConditionalEdge{chooser: chooser, candidates: candidates} | _rest],
         state
       ) do
    case chooser.(state) do
      id when is_atom(id) or is_binary(id) ->
        if id in candidates do
          {:ok, id}
        else
          {:error, {:chooser_returned_unknown_candidate, id, candidates}}
        end

      ids when is_list(ids) and ids != [] ->
        validate_fan_out_ids(ids, candidates)

      other ->
        {:error, {:chooser_returned_non_id, other}}
    end
  end

  defp pick_next([%JoinEdge{} | rest], state), do: pick_next(rest, state)

  defp validate_fan_out_ids(ids, candidates) do
    case Enum.find(ids, fn id -> id not in candidates end) do
      nil -> {:ok, ids}
      bad -> {:error, {:chooser_returned_unknown_candidate, bad, candidates}}
    end
  end

  # --- Fan-out / Join ---

  defp fan_out(compiled, branch_ids, state, run_id, deadline_us, count) do
    case join_for_branches(compiled, branch_ids) do
      nil ->
        {:error, {:fan_out_without_join, branch_ids}, state, count}

      %JoinEdge{} = join ->
        result =
          dispatch_branches(
            join,
            compiled,
            branch_ids,
            state,
            run_id,
            deadline_us,
            count
          )

        case result do
          {:all_done, branch_states, new_count} ->
            merged = BranchMerge.merge(branch_states, join, compiled.channels)
            step(compiled, join.target, merged, run_id, deadline_us, new_count)

          {:has_paused, slots, new_count} ->
            interrupt_for_branch_pause(
              compiled,
              branch_ids,
              join,
              state,
              slots,
              run_id,
              new_count
            )

          {:error, _reason, _state, _count} = err ->
            err
        end
    end
  end

  defp interrupt_for_branch_pause(
         compiled,
         branch_ids,
         %JoinEdge{target: join_target},
         source_state,
         slots,
         run_id,
         count
       ) do
    continuation = %{
      source_state: source_state,
      join_target: join_target,
      branch_ids: branch_ids,
      slots: slots
    }

    augmented_state = Map.put(source_state, @fan_out_key, continuation)

    {paused_index, paused_node_id, _state_at_pause, interrupt_reason} =
      first_paused_slot(slots)

    _ =
      with_branch_id({join_target, paused_index}, fn ->
        case persist_pause_checkpoint(
               compiled,
               paused_node_id,
               augmented_state,
               run_id,
               count,
               interrupt_reason
             ) do
          :ok ->
            emit_run_event(:paused, %{
              run_id: run_id,
              graph_id: compiled.id,
              node_id: paused_node_id,
              branch_id: {join_target, paused_index},
              interrupt_reason: interrupt_reason,
              paused_at: DateTime.utc_now()
            })

          :no_saver ->
            :ok
        end
      end)

    {:interrupted, augmented_state, interrupt_reason, count}
  end

  defp first_paused_slot(slots) do
    slots
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{:paused, node_id, state, reason}, idx} -> {idx, node_id, state, reason}
      _ -> nil
    end)
  end

  defp join_for_branches(compiled, [first | _rest]) do
    Map.get(compiled.joins_by_upstream, first)
  end

  defp dispatch_branches(
         %JoinEdge{parallelism: 1},
         compiled,
         branch_ids,
         state,
         run_id,
         deadline_us,
         count
       ) do
    run_branches_serially(
      compiled,
      branch_ids,
      state,
      run_id,
      deadline_us,
      count
    )
  end

  defp dispatch_branches(
         %JoinEdge{},
         compiled,
         branch_ids,
         state,
         run_id,
         deadline_us,
         count
       ) do
    run_branches_concurrently(
      compiled,
      branch_ids,
      state,
      run_id,
      deadline_us,
      count
    )
  end

  defp run_branches_serially(
         compiled,
         branch_ids,
         state,
         run_id,
         deadline_us,
         count
       ) do
    join_target =
      case Map.get(compiled.joins_by_upstream, hd(branch_ids)) do
        %JoinEdge{target: t} -> t
        nil -> nil
      end

    branch_ids
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], count}, fn {id, index}, {:ok, slots, c} ->
      cond do
        monotonic_us() >= deadline_us ->
          {:halt, {:error, :run_timeout, state, c}}

        true ->
          result =
            with_branch_id({join_target, index}, fn ->
              step_branch(
                compiled,
                id,
                state,
                run_id,
                deadline_us,
                c,
                join_target
              )
            end)

          case result do
            {:branch_done, branch_state, new_count} ->
              {:cont, {:ok, [{:done, branch_state} | slots], new_count}}

            {:branch_paused, value, state_at_interrupt, paused_node_id,
             new_count} ->
              {:cont,
               {:ok,
                [{:paused, paused_node_id, state_at_interrupt, value} | slots],
                new_count}}

            {:error, _reason, _state, _count} = err ->
              {:halt, err}
          end
      end
    end)
    |> case do
      {:ok, slots, c} ->
        ordered = Enum.reverse(slots)

        if Enum.any?(ordered, &match?({:paused, _, _, _}, &1)) do
          {:has_paused, ordered, c}
        else
          {:all_done, Enum.map(ordered, fn {:done, st} -> st end), c}
        end

      {:error, _, _, _} = err ->
        err
    end
  end

  defp run_branches_concurrently(
         compiled,
         branch_ids,
         source_state,
         run_id,
         deadline_us,
         count
       ) do
    join_target =
      case Map.get(compiled.joins_by_upstream, hd(branch_ids)) do
        %JoinEdge{target: t} -> t
        nil -> nil
      end

    max_concurrency =
      case Map.get(compiled.joins_by_node, join_target) do
        %JoinEdge{parallelism: :branches} -> length(branch_ids)
        %JoinEdge{parallelism: n} when is_integer(n) and n > 0 -> n
        _ -> length(branch_ids)
      end

    parent_trace = TraceContext.current()

    stream_timeout = max(0, div(deadline_us - monotonic_us(), 1_000))

    indexed = Enum.with_index(branch_ids)

    # Halt early on the first :error outcome; Task.async_stream kills
    # the in-flight Tasks when the stream closes.
    stream_results =
      Task.async_stream(
        indexed,
        fn {branch_id, index} ->
          run_branch_in_task(
            compiled,
            branch_id,
            index,
            source_state,
            run_id,
            deadline_us,
            count,
            join_target,
            parent_trace
          )
        end,
        ordered: true,
        max_concurrency: max_concurrency,
        timeout: stream_timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while([], fn
        {:ok, {:branch_outcome, _idx, {:error, _, _, _}, _, _}} = result, acc ->
          {:halt, [result | acc]}

        {:ok, _outcome} = result, acc ->
          {:cont, [result | acc]}

        {:exit, _reason} = result, acc ->
          {:halt, [result | acc]}
      end)
      |> Enum.reverse()

    fold_concurrent_results(stream_results, source_state, count)
  end

  defp run_branch_in_task(
         compiled,
         branch_id,
         index,
         source_state,
         run_id,
         deadline_us,
         base_count,
         join_target,
         parent_trace
       ) do
    install_branch_trace(parent_trace)
    Process.put(@branch_id_key, {join_target, index})
    Process.put(@executed_key, [])

    task_start_count = base_count + index * @branch_step_stride

    try do
      result =
        TraceContext.with_span("workflow.branch.#{index}", fn ->
          step_branch(
            compiled,
            branch_id,
            source_state,
            run_id,
            deadline_us,
            task_start_count,
            join_target
          )
        end)

      executed = Process.get(@executed_key, [])
      {:branch_outcome, index, result, task_start_count, Enum.reverse(executed)}
    after
      Process.delete(@branch_id_key)
      Process.delete(@executed_key)
      TraceContext.clear()
    end
  end

  defp install_branch_trace(%{trace_id: trace_id} = parent)
       when not is_nil(trace_id) do
    Process.put(:raxol_trace_id, trace_id)
    Process.put(:raxol_span_id, parent.span_id)
    Process.put(:raxol_parent_span_id, parent.parent_span_id)

    if parent.causation_id do
      Process.put(:raxol_causation_id, parent.causation_id)
    end
  end

  defp install_branch_trace(_), do: :ok

  defp fold_concurrent_results(stream_results, source_state, base_count) do
    outcomes =
      Enum.map(stream_results, fn
        {:ok, {:branch_outcome, _idx, _result, _start, _executed} = outcome} ->
          outcome

        {:exit, reason} ->
          {:task_exit, reason}
      end)

    case Enum.find(outcomes, &match?({:task_exit, _}, &1)) do
      {:task_exit, reason} ->
        {:error, {:branch_task_exit, reason}, source_state, base_count}

      nil ->
        sorted =
          Enum.sort_by(outcomes, fn {:branch_outcome, idx, _, _, _} -> idx end)

        Enum.each(sorted, fn {:branch_outcome, _idx, _res, _start,
                              executed_nodes} ->
          Enum.each(executed_nodes, &track_executed/1)
        end)

        case Enum.find(sorted, fn
               {:branch_outcome, _, {:error, _, _, _}, _, _} -> true
               _ -> false
             end) do
          {:branch_outcome, _, {:error, _, _, _} = err, _, _} ->
            err

          nil ->
            build_slots_from_outcomes(sorted, base_count)
        end
    end
  end

  defp build_slots_from_outcomes(sorted_outcomes, base_count) do
    # new_count skips past every branch stride so any pause checkpoint
    # the caller writes is the saver's `get_latest` answer.
    {slots, _} =
      Enum.reduce(sorted_outcomes, {[], 0}, fn
        {:branch_outcome, _idx, {:branch_done, branch_state, _branch_count},
         _task_start, _exec},
        {acc, sum} ->
          {[{:done, branch_state} | acc], sum}

        {:branch_outcome, _idx,
         {:branch_paused, value, state_at_pause, paused_node_id, _branch_count},
         _task_start, _exec},
        {acc, sum} ->
          {[{:paused, paused_node_id, state_at_pause, value} | acc], sum}
      end)

    ordered = Enum.reverse(slots)
    new_count = base_count + length(sorted_outcomes) * @branch_step_stride

    if Enum.any?(ordered, &match?({:paused, _, _, _}, &1)) do
      {:has_paused, ordered, new_count}
    else
      {:all_done, Enum.map(ordered, fn {:done, st} -> st end), new_count}
    end
  end

  # --- Branch sub-execution walker ---

  defp step_branch(
         _compiled,
         @end_,
         state,
         _run_id,
         _deadline_us,
         count,
         halt_at
       ) do
    {:error, {:branch_reached_end_before_join, halt_at}, state, count}
  end

  defp step_branch(
         compiled,
         current_id,
         state,
         run_id,
         deadline_us,
         count,
         halt_at
       ) do
    cond do
      monotonic_us() >= deadline_us ->
        {:error, :run_timeout, state, count}

      true ->
        execute_branch_node(
          compiled,
          current_id,
          state,
          run_id,
          deadline_us,
          count,
          halt_at
        )
    end
  end

  defp execute_branch_node(
         compiled,
         current_id,
         state,
         run_id,
         deadline_us,
         count,
         halt_at
       ) do
    case attempt_node_with_retry(compiled, current_id, state, run_id, 1) do
      {:node_ok, new_state, _tag} ->
        track_executed(Map.fetch!(compiled.nodes, current_id))
        persist_checkpoint(compiled, current_id, new_state, run_id, count)

        traverse_branch(
          compiled,
          current_id,
          new_state,
          run_id,
          deadline_us,
          count + 1,
          halt_at
        )

      {:interrupt, value, state_at_interrupt} ->
        {:branch_paused, value, state_at_interrupt, current_id, count + 1}

      {:error, reason, state_at_error} ->
        {:error, reason, state_at_error, count + 1}
    end
  end

  defp traverse_branch(
         compiled,
         current_id,
         state,
         run_id,
         deadline_us,
         count,
         halt_at
       ) do
    outgoing = Map.get(compiled.edges_by_source, current_id, [])

    case pick_next(outgoing, state) do
      {:ok, ^halt_at} ->
        {:branch_done, state, count}

      {:ok, next_id} when is_atom(next_id) or is_binary(next_id) ->
        step_branch(
          compiled,
          next_id,
          state,
          run_id,
          deadline_us,
          count,
          halt_at
        )

      {:ok, ids} when is_list(ids) ->
        {:error, {:nested_fan_out_unsupported, current_id}, state, count}

      :no_match ->
        {:error, {:no_outgoing_edge_matched, current_id}, state, count}

      {:error, reason} ->
        {:error, reason, state, count}
    end
  end

  # --- Effect dispatch ---

  defp dispatch_effects(directives) do
    context = %{pid: self(), runtime_pid: self()}

    Enum.each(directives, fn directive ->
      if is_struct(directive) and Directive.Executor.impl_for(directive) != nil do
        Directive.Executor.execute(directive, context)
      else
        :ok
      end
    end)
  end

  # --- Telemetry helpers ---

  defp emit_run_event(kind, metadata) do
    :telemetry.execute(
      [:raxol, :workflow, :run, kind],
      %{},
      add_trace_context(metadata)
    )
  end

  defp emit_node_event(kind, metadata) do
    measurements =
      case Map.fetch(metadata, :duration_us) do
        {:ok, dur} -> %{duration_us: dur}
        :error -> %{}
      end

    :telemetry.execute(
      [:raxol, :workflow, :node, kind],
      measurements,
      add_trace_context(Map.delete(metadata, :duration_us))
    )
  end

  defp add_trace_context(metadata) do
    case TraceContext.current() do
      %{trace_id: nil} ->
        metadata

      ctx ->
        metadata
        |> Map.put(:trace_id, ctx.trace_id)
        |> Map.put(:span_id, ctx.span_id)
        |> maybe_put(:parent_span_id, ctx.parent_span_id)
        |> maybe_put(:causation_id, ctx.causation_id)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Misc ---

  @doc "Generate a fresh 16-character hex run id."
  @spec generate_run_id() :: binary()
  def generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
