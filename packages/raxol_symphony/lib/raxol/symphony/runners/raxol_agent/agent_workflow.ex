defmodule Raxol.Symphony.Runners.RaxolAgent.AgentWorkflow do
  @moduledoc """
  Multi-node `Raxol.Workflow` graph that wraps the `RaxolAgent` turn
  loop with per-turn checkpointing (Phase 7, supersedes the Phase 6
  single-node MVP).

  ## Topology

  Compiled per-run, parameterized by `max_turns`:

      __start__
        -> :turn_1 -> :after_turn_1
                       [continue] -> :turn_2 -> :after_turn_2
                                                  ...
                                                    -> :turn_N -> :after_turn_N
                                                                    -> __end__
                       [end]      -> __end__

  Each `:turn_N` node runs ONE turn (build prompt, pull stream,
  forward events). Each `:after_turn_N` node:

    1. Refreshes the issue via the tracker (`still_active?`).
    2. If a pause was queued during turn_N, calls
       `Raxol.Workflow.interrupt/1`.
    3. Decides whether to continue to `:turn_{N+1}` or end.

  ## Why split per turn

  The workflow runtime checkpoints state **before** a node body runs.
  Phase 6's single-node graph re-ran the in-flight LLM turn on resume
  because the checkpoint reset to "before turn 1". Phase 7 puts the
  interrupt in `:after_turn_N` so resume re-runs the after node
  (cheap: tracker check + decision) but never the LLM stream from
  `:turn_N`.

  ## State

      %{
        # Static across the run
        issue, config, parent, attempt,
        backend, backend_opts, system_prompt, pause_detector,
        max_turns,

        # Mutated per turn
        turn,                # 1..max_turns, advanced in after_turn_N
        last_events,         # list of stream events from the most recent turn
        pause_request,       # {:pause, reason, token} | nil; queued in turn_N
        last_resume_value,   # set when after_turn_N resumes

        # Filled when the loop terminates
        run_result,          # :ok | :max_turns_reached | {:error, reason}
        next_step            # :next | :end -- read by conditional edges
      }

  ## Detector contract

  In multi-node mode the detector is consulted per-event during
  `turn_N`. If any event causes a `{:pause, reason, token}`, the
  pause is QUEUED (state.pause_request) and stream consumption
  continues to completion. The pause fires at the turn boundary
  inside `after_turn_N`. This means the turn's tail events are
  still forwarded before the run pauses; this is a deliberate
  trade-off so that resuming never has to re-run the LLM call.
  """

  alias Raxol.Workflow.{Compiled, Graph}

  # Optional dep -- consumers wire it via agent.thread_log; the
  # dispatcher's nil branch silently no-ops, so the appends below are
  # safe even when raxol_agent isn't loaded.
  @compile {:no_warn_undefined, Raxol.Agent.ThreadLog}

  @doc """
  Build and compile the multi-node turn-loop graph for
  `max_turns` (>= 1).

  `opts` forwards to `Graph.compile/2`. The most load-bearing one is
  `:saver`; the runner defaults to an in-memory ETS saver if the
  consumer hasn't set `agent.workflow_saver`.
  """
  @spec compile(pos_integer(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def compile(max_turns, opts \\ []) when is_integer(max_turns) and max_turns >= 1 do
    g = Graph.new(:raxol_agent_turn_loop)

    # __start__ -> :turn_1
    g = Graph.add_edge(g, :__start__, turn_node(1))

    # Per-turn pair of nodes: :turn_N -> :after_turn_N
    g =
      Enum.reduce(1..max_turns, g, fn n, g ->
        g
        |> Graph.add_node(turn_node(n), &__MODULE__.run_turn/1)
        |> Graph.add_node(after_node(n), build_after_node_body(n, max_turns))
        |> Graph.add_edge(turn_node(n), after_node(n))
      end)

    # Conditional fan-out from :after_turn_N to either :turn_{N+1} or __end__.
    g =
      Enum.reduce(1..(max_turns - 1)//1, g, fn n, g ->
        Graph.add_conditional_edge(
          g,
          after_node(n),
          [turn_node(n + 1), :__end__],
          fn state ->
            if Map.get(state, :next_step) == :next,
              do: turn_node(n + 1),
              else: :__end__
          end
        )
      end)

    # Final after-turn always goes to __end__.
    g = Graph.add_edge(g, after_node(max_turns), :__end__)

    Graph.compile(g, opts)
  end

  # --- Node id builders ---

  defp turn_node(n), do: :"turn_#{n}"
  defp after_node(n), do: :"after_turn_#{n}"

  # --- Turn node body ---
  #
  # Runs one LLM turn: build prompt, pull stream, forward events,
  # consult detector PER EVENT. Pause requests are queued (not
  # acted on) so the stream is consumed to completion. The next
  # node (:after_turn_N) handles the pause.

  @doc false
  def run_turn(state) do
    body_fn = state.turn_body_fn

    case body_fn.(state) do
      {:ok, events, pause_request} ->
        {:ok, %{state | last_events: events, pause_request: pause_request}}

      {:error, reason} ->
        # Hard turn failure (e.g. PolicyApplier exhausted retries or
        # the timeout policy aborted). Surface to state so after_turn
        # short-circuits straight to __end__ and the runner translates
        # the workflow result back into {:error, reason} from run/3.
        {:ok,
         %{
           state
           | last_events: [],
             pause_request: nil,
             run_result: {:error, reason}
         }}
    end
  end

  # --- After-turn node body ---

  defp build_after_node_body(n, max_turns) do
    fn state -> after_turn(state, n, max_turns) end
  end

  @doc false
  def after_turn(state, n, max_turns) do
    # If the turn body failed hard (PolicyApplier exhausted retries,
    # timeout, etc.) -- run_result is set and we short-circuit to
    # __end__ without consulting the tracker or the pause queue.
    # The runner's translate_workflow_result surfaces this back to
    # the orchestrator as {:error, reason} from run/3.
    case Map.get(state, :run_result) do
      {:error, _} -> {:ok, %{state | next_step: :end}}
      _ -> do_after_turn(state, n, max_turns)
    end
  end

  defp do_after_turn(state, n, max_turns) do
    # Pause check FIRST so the operator's decision can override the
    # tracker (e.g., reject the run early). interrupt/1 throws on
    # first pass, returns the resume value on resume.
    state =
      case state.pause_request do
        {:pause, reason, _token} ->
          resume_value = Raxol.Workflow.interrupt(reason)

          # Reached here only on the resume path -- interrupt/1
          # threw on the first pass. Log the resume decision.
          _ =
            Raxol.Agent.ThreadLog.append(
              Map.get(state, :thread_log),
              Map.get(state, :thread_id, "symphony-agent-unknown"),
              :message,
              %{event: :resumed, interrupt_reason: reason, resume_value: resume_value, turn: n}
            )

          %{state | pause_request: nil, last_resume_value: resume_value}

        nil ->
          state
      end

    # Tracker check. The helper receives the whole state so it can
    # consult ancillary fields (e.g., the optional tracker cache).
    still_active_fn = state.still_active_fn

    case still_active_fn.(state) do
      :done ->
        {:ok, %{state | run_result: :ok, next_step: :end}}

      {:error, _reason} ->
        # Tracker unavailable -- end this run; the orchestrator will retry.
        {:ok, %{state | run_result: :ok, next_step: :end}}

      {:active, refreshed} ->
        cond do
          n >= max_turns ->
            {:ok,
             %{
               state
               | issue: refreshed,
                 run_result: :max_turns_reached,
                 next_step: :end
             }}

          true ->
            {:ok, %{state | turn: n + 1, issue: refreshed, next_step: :next}}
        end
    end
  end
end
