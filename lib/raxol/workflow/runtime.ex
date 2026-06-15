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
  alias Raxol.Workflow.Node, as: WorkflowNode
  alias Raxol.Workflow.Node.{BehaviourNode, FunctionNode, TypedNode}

  @start :__start__
  @end_ :__end__

  @default_run_timeout_ms 60_000

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
    run_id = Keyword.get_lazy(opts, :run_id, &generate_run_id/0)
    deadline_us = monotonic_us() + resolve_timeout(opts, compiled) * 1_000

    _ = TraceContext.start_trace()

    try do
      emit_run_event(:started, %{run_id: run_id, graph_id: compiled.id})

      compiled
      |> step(@start, initial_state, run_id, deadline_us, 0)
      |> wrap_outcome(run_id, compiled.id)
    after
      _ = TraceContext.clear()
    end
  end

  defp resolve_timeout(opts, compiled) do
    Keyword.get(
      opts,
      :run_timeout_ms,
      Map.get(compiled.opts, :run_timeout_ms, @default_run_timeout_ms)
    )
  end

  defp wrap_outcome({:ok, final_state, count}, run_id, graph_id) do
    emit_run_event(:completed, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: count
    })

    {:ok, final_state, %{run_id: run_id, nodes_executed: count}}
  end

  defp wrap_outcome({:interrupted, state, value, count}, run_id, graph_id) do
    emit_run_event(:interrupted, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: count,
      value: value
    })

    {:interrupted, run_id, state, value}
  end

  defp wrap_outcome({:error, reason, state, count}, run_id, graph_id) do
    emit_run_event(:failed, %{
      run_id: run_id,
      graph_id: graph_id,
      nodes_executed: count,
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
      handle_node_result(
        run_node(node, state),
        compiled,
        current_id,
        state,
        run_id,
        deadline_us,
        count,
        started_us
      )
    rescue
      e ->
        _ = TraceContext.end_span()
        message = Exception.message(e)

        emit_node_event(:failed, %{
          run_id: run_id,
          graph_id: compiled.id,
          node_id: current_id,
          duration_us: monotonic_us() - started_us,
          reason: {:exception, message}
        })

        {:error, {:exception, message}, state, count + 1}
    end
  end

  defp handle_node_result(
         {:ok, new_state},
         compiled,
         current_id,
         _state,
         run_id,
         deadline_us,
         count,
         started_us
       ) do
    finish_node_ok(
      compiled,
      current_id,
      new_state,
      run_id,
      deadline_us,
      count,
      started_us,
      :ok
    )
  end

  defp handle_node_result(
         {:effects, directives, new_state},
         compiled,
         current_id,
         _state,
         run_id,
         deadline_us,
         count,
         started_us
       )
       when is_list(directives) do
    dispatch_effects(directives)

    finish_node_ok(
      compiled,
      current_id,
      new_state,
      run_id,
      deadline_us,
      count,
      started_us,
      :effects
    )
  end

  defp handle_node_result(
         {:interrupt, value},
         compiled,
         current_id,
         state,
         run_id,
         _deadline_us,
         count,
         started_us
       ) do
    end_span_and_emit(:completed, compiled, current_id, run_id, started_us, %{
      result_type: :interrupt
    })

    {:interrupted, state, value, count + 1}
  end

  defp handle_node_result(
         {:error, reason},
         compiled,
         current_id,
         state,
         run_id,
         _deadline_us,
         count,
         started_us
       ) do
    end_span_and_emit(:failed, compiled, current_id, run_id, started_us, %{
      reason: reason
    })

    {:error, reason, state, count + 1}
  end

  defp handle_node_result(
         other,
         compiled,
         current_id,
         state,
         run_id,
         _deadline_us,
         count,
         started_us
       ) do
    end_span_and_emit(:failed, compiled, current_id, run_id, started_us, %{
      reason: {:invalid_result, other}
    })

    {:error, {:invalid_result, other}, state, count + 1}
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

  defp finish_node_ok(
         compiled,
         current_id,
         new_state,
         run_id,
         deadline_us,
         count,
         started_us,
         tag
       ) do
    emit_node_event(:completed, %{
      run_id: run_id,
      graph_id: compiled.id,
      node_id: current_id,
      duration_us: monotonic_us() - started_us,
      result_type: tag
    })

    _ = TraceContext.end_span()
    persist_checkpoint(compiled, current_id, new_state, run_id, count)
    traverse(compiled, current_id, new_state, run_id, deadline_us, count + 1)
  end

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
