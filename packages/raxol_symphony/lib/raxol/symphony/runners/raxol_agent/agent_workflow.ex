defmodule Raxol.Symphony.Runners.RaxolAgent.AgentWorkflow do
  @moduledoc """
  Single-node `Raxol.Workflow` graph that wraps the existing
  `Raxol.Symphony.Runners.RaxolAgent` turn loop.

  Opt-in via `agent.workflow_mode: true`. When set, the runner
  dispatches each run through `Compiled.invoke/resume` instead of
  calling `RaxolAgent.run_turns/3` directly. Pause detection inside
  the agent stream calls `Raxol.Workflow.interrupt/1` (which the
  workflow runtime catches, surfaces as `{:interrupted, run_id, _,
  reason}`, and checkpoints to the configured Saver).

  ## Why the envelope is opt-in

  The workflow runtime adds two things:

    1. **Durable resume across BEAM restart** -- the workflow Saver
       can be Dets/Postgrex, in which case a paused run survives
       process death.
    2. **Symmetric pause API** -- the runner's `{:pause, ...}` return
       and the orchestrator's `resume_run/3` are wired around
       `Workflow.interrupt/1` instead of synthetic tuples, matching
       the pattern `Raxol.ACP.Job.Workflow` uses.

  In return it costs an extra LLM call per pause (see "Limitation"
  below). The default detector path (no envelope) avoids both.

  ## Topology

      __start__ -> :run_turns -> __end__

  One node. The node body wraps `RaxolAgent.run_turns/3` plus the
  pause-detector logic the runner already has, but routes pauses
  through `Workflow.interrupt/1` rather than synthetic returns.

  ## Limitation: single-node graph re-runs the in-flight turn on resume

  The Workflow runtime checkpoints state **before** the node body
  starts. On resume, the SAME node body re-runs with the pre-node
  state -- which for this MVP envelope means re-running the
  in-flight turn (re-building the prompt, re-pulling the LLM stream).

  This is acceptable for many cases (test runs, deterministic
  prompts, idempotent tool calls) but adds latency + cost when
  pauses are frequent. The Phase 7 follow-up splits the graph into
  `turn_1, after_turn_1, turn_2, after_turn_2, ...` nodes so the
  resume re-runs only the lightweight `after_turn_N` decision node,
  not the LLM turn itself.

  ## State

  The workflow state is the same `ctx` map `RaxolAgent.do_run/3`
  builds, plus a `:run_result` slot the node writes when it finishes
  (one of `:ok`, `:max_turns_reached`, `{:error, reason}`).

  ## Resume semantics

  `Raxol.Workflow.interrupt/1` returns the resume value on the
  second pass. The node body stashes it in `state.last_resume_value`
  so the next prompt builder can incorporate the operator's
  decision. The current implementation just passes through; richer
  prompt threading is a future addition.
  """

  alias Raxol.Workflow.{Compiled, Graph}

  @typedoc """
  The accumulated agent run state passed between turn iterations
  inside the single node body.
  """
  @type state :: %{
          required(:issue) => term(),
          required(:config) => term(),
          required(:parent) => pid(),
          required(:attempt) => non_neg_integer() | nil,
          required(:backend) => module(),
          required(:backend_opts) => keyword(),
          required(:system_prompt) => binary() | nil,
          required(:pause_detector) => term() | nil,
          required(:turn) => pos_integer(),
          required(:max_turns) => pos_integer(),
          required(:body) => (state() -> :ok | {:error, term()} | {:pause, atom(), term()}),
          optional(:run_result) => :ok | :max_turns_reached | {:error, term()},
          optional(:last_resume_value) => term()
        }

  @doc """
  Build and compile the single-node turn-loop graph.

  `opts` is forwarded to `Raxol.Workflow.Graph.compile/2`; the most
  load-bearing one is `:saver`, which controls whether paused runs
  are durable across the BEAM restart. The default (no `:saver`)
  uses an in-memory checkpoint store that survives the orchestrator
  process but not the BEAM.
  """
  @spec compile(keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def compile(opts \\ []) do
    Graph.new(:raxol_agent_turn_loop)
    |> Graph.add_node(:run_turns, &run_turns_node/1)
    |> Graph.add_edge(:__start__, :run_turns)
    |> Graph.add_edge(:run_turns, :__end__)
    |> Graph.compile(opts)
  end

  # --- Node body ---

  defp run_turns_node(state) do
    iterate(state)
  end

  defp iterate(%{turn: t, max_turns: max} = state) when t > max do
    {:ok, Map.put(state, :run_result, :max_turns_reached)}
  end

  defp iterate(state) do
    case state.body.(state) do
      {:continue, new_state} ->
        # One turn completed successfully + tracker says continue.
        iterate(%{new_state | turn: new_state.turn + 1})

      :done ->
        # Tracker reported the issue terminal mid-loop. Finish clean.
        {:ok, Map.put(state, :run_result, :ok)}

      {:pause, reason, _detector_token} when is_atom(reason) ->
        # Interrupt the run. interrupt/1 throws on the first pass and
        # the workflow runtime catches + checkpoints. On resume the
        # scratchpad pops the resume value and execution continues
        # here.
        resume_value = Raxol.Workflow.interrupt(reason)
        iterate(%{state | turn: state.turn + 1, last_resume_value: resume_value})

      {:error, reason} ->
        {:ok, Map.put(state, :run_result, {:error, reason})}
    end
  end
end
