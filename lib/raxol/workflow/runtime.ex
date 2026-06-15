defmodule Raxol.Workflow.Runtime do
  @moduledoc """
  Synchronous execution runtime for `Raxol.Workflow.Compiled` graphs.

  Implements the synchronous `invoke/3` path described in ADR-0015.
  Walks the graph from `:__start__` to `:__end__`, executes each node
  according to its descriptor type, dispatches any returned directives
  through `Raxol.Core.Runtime.Directive.Executor`, and emits per-node
  telemetry with full Phase 24 trace context (trace_id, span_id,
  parent_span_id, causation_id) propagated through `TraceContext`.

  Async invocation (`async_invoke`, `stream_events`), checkpoint
  persistence, interrupt/resume, joins, and channel reducers land in
  follow-up PRs. This module only implements the synchronous,
  no-checkpoint path; the runtime catches `:interrupt` results and
  returns them to the caller without persisting state.
  """

  alias Raxol.Core.Runtime.Directive
  alias Raxol.Core.Telemetry.TraceContext
  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Edge.ConditionalEdge
  alias Raxol.Workflow.Edge.Edge, as: StaticEdge
  alias Raxol.Workflow.Edge.GuardedEdge
  alias Raxol.Workflow.Execution.Scratchpad
  alias Raxol.Workflow.Node, as: WorkflowNode
  alias Raxol.Workflow.Node.{BehaviourNode, FunctionNode, TypedNode}

  @executed_key :__raxol_workflow_executed__

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
        resume_from
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
              graph_id: compiled.id
            }
          )

        saver_module.put(saver_config, run_id, checkpoint)
    end
  end

  defp start_or_resume(compiled, state, run_id, deadline_us, count, nil) do
    step(compiled, @start, state, run_id, deadline_us, count)
  end

  defp start_or_resume(compiled, state, run_id, deadline_us, count, resume_node)
       when is_atom(resume_node) or is_binary(resume_node) do
    # The resume node already executed on the prior run; just traverse
    # outgoing edges to find the next node to execute.
    traverse(compiled, resume_node, state, run_id, deadline_us, count)
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
    resume_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:resume_from, checkpoint.metadata.node_id)
      |> Keyword.put(:initial_step, checkpoint.step + 1)
      |> Keyword.put(:resume_values, [resume_value])

    invoke(compiled, checkpoint.state, resume_opts)
  end

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
      value: value
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
        {:interrupted, state_at_interrupt, value, count + 1}

      {:error, reason, state_at_error} ->
        {:error, reason, state_at_error, count + 1}
    end
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
      node_id: current_id
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
          duration_us: monotonic_us() - started_us
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
              graph_id: compiled.id
            }
          )

        saver_module.put(saver_config, run_id, checkpoint)
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
      {:ok, next_id} ->
        step(compiled, next_id, state, run_id, deadline_us, count)

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

      other ->
        {:error, {:chooser_returned_non_id, other}}
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
