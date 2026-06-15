defmodule Raxol.Symphony.Workflow.GraphAdapter do
  @moduledoc """
  Builds a `Raxol.Workflow.Graph` that represents the canonical Symphony
  pipeline using main raxol's Phase 25 workflow primitive.

  This adapter is the opt-in path described in ADR-0015. The default
  Symphony orchestrator runs the prompt-only path through `Orchestrator`;
  consumers that want graph-shaped execution call `from_workflow/2` to
  build a compiled graph and dispatch it through `Raxol.Workflow.Compiled`
  themselves.

  ## Canonical pipeline

  The graph wires the five stages the orchestrator already implements
  inline into discrete nodes the workflow runtime can checkpoint
  individually:

      :__start__ -> :tracker_poll -> :candidate_selection
        -> :runner_dispatch -> :evidence_collection -> :completion -> :__end__

  Each node accumulates fields into the workflow state map:

  | Node                  | Reads                  | Writes                |
  | --------------------- | ---------------------- | --------------------- |
  | `tracker_poll`        | `config`               | `candidates`          |
  | `candidate_selection` | `candidates`           | `candidate`           |
  | `runner_dispatch`     | `candidate`, `config`  | `run_result`          |
  | `evidence_collection` | `candidate`, `config`  | `evidence`            |
  | `completion`          | `run_result`,`evidence`| `completed_at`        |

  ## Required runtime opts

  `from_workflow/2` accepts a single `opts` keyword:

    * `:config` (required) -- a `Raxol.Symphony.Config` struct used by
      the tracker poll, runner dispatch, and evidence collection nodes.
    * `:saver` (optional) -- forwarded to `Raxol.Workflow.Graph.compile/2`
      so resumable runs can be wired without changing the graph.
    * `:runner_module` (optional) -- override the runner module
      `Raxol.Symphony.Runner.resolve/2` picks; primarily for tests.
    * `:tracker_state_filter` (optional) -- pass-through to
      `Raxol.Symphony.Tracker.fetch_candidate_issues/1` semantics; the
      default uses the config's tracker kind.

  ## Out of scope (deferred to a follow-up PR)

  - Wiring `workflow_mode: :graph` into the `Orchestrator` GenServer.
    This adapter ships the translation function; the orchestrator
    integration is opt-in via a separate PR so the default prompt-only
    behavior stays unchanged.
  - Interrupt-based pauses on runner dispatch. The runner is invoked
    synchronously (`Runner.run/3` returns `:ok | {:error, _}`), so this
    PR does not exercise `Workflow.interrupt/1`. A follow-up can wrap
    long-running runners with an interrupt-and-resume mechanism keyed
    on the orchestrator's existing `:run_event` messages.
  - Per-node tracker / runner overrides via custom node bodies. The
    adapter ships one canonical shape; richer composition is a later
    concern.
  """

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Evidence
  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Runner
  alias Raxol.Symphony.Tracker
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  @typedoc """
  Workflow state accumulated through the pipeline.

  Each node adds keys; absent keys are treated as `nil` by downstream
  nodes.
  """
  @type state :: %{
          optional(:config) => Config.t(),
          optional(:candidates) => [Issue.t()],
          optional(:candidate) => Issue.t() | nil,
          optional(:run_result) => :ok | {:error, term()},
          optional(:evidence) => Evidence.t(),
          optional(:completed_at) => DateTime.t(),
          optional(:runner_module) => module() | nil
        }

  @doc """
  Build and compile the canonical Symphony graph.

  Returns `{:ok, compiled}` or `{:error, validation_error}`. The
  compiled graph can be invoked via the standard runtime entry points
  (`Compiled.invoke/3`, `Compiled.async_invoke/3`, `Compiled.stream_events/3`).
  """
  @spec from_workflow(keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def from_workflow(opts) do
    Graph.new(:symphony_canonical)
    |> Graph.add_node(:tracker_poll, &tracker_poll_node/1)
    |> Graph.add_node(:candidate_selection, &candidate_selection_node/1)
    |> Graph.add_node(:runner_dispatch, &runner_dispatch_node/1)
    |> Graph.add_node(:evidence_collection, &evidence_collection_node/1)
    |> Graph.add_node(:completion, &completion_node/1)
    |> Graph.add_edge(:__start__, :tracker_poll)
    |> Graph.add_edge(:tracker_poll, :candidate_selection)
    |> Graph.add_edge(:candidate_selection, :runner_dispatch)
    |> Graph.add_edge(:runner_dispatch, :evidence_collection)
    |> Graph.add_edge(:evidence_collection, :completion)
    |> Graph.add_edge(:completion, :__end__)
    |> Graph.compile(compile_opts(opts))
  end

  defp compile_opts(opts) do
    opts
    |> Keyword.take([:saver, :failure_policy, :step_timeout_ms, :run_timeout_ms])
  end

  @doc """
  Build the initial state expected by the graph.

  Pass the result as the second argument to `Compiled.invoke/3`. The
  state seeds `config`, `runner_module`, and any other adapter-side
  keys the nodes read.
  """
  @spec initial_state(keyword()) :: state()
  def initial_state(opts) do
    %{
      config: Keyword.fetch!(opts, :config),
      runner_module: Keyword.get(opts, :runner_module)
    }
  end

  # --- Node bodies ---

  defp tracker_poll_node(state) do
    case Tracker.fetch_candidate_issues(state.config) do
      {:ok, issues} ->
        {:ok, Map.put(state, :candidates, issues)}

      {:error, _reason} = err ->
        err
    end
  end

  defp candidate_selection_node(%{candidates: candidates} = state) do
    case candidates do
      [first | rest] ->
        {:ok, state |> Map.put(:candidate, first) |> Map.put(:candidates, rest)}

      [] ->
        {:ok, Map.put(state, :candidate, nil)}
    end
  end

  defp runner_dispatch_node(%{candidate: nil} = state) do
    {:ok, Map.put(state, :run_result, {:error, :no_candidate})}
  end

  defp runner_dispatch_node(%{candidate: %Issue{} = issue, config: config} = state) do
    runner_opts = if state.runner_module, do: [runner_module: state.runner_module], else: []

    with {:ok, runner_module} <- Runner.resolve(config, runner_opts) do
      result =
        runner_module.run(issue, config,
          parent: self(),
          attempt: 1,
          workspace_path: Map.get(state, :workspace_path, "")
        )

      {:ok, Map.put(state, :run_result, result)}
    end
  end

  defp evidence_collection_node(%{candidate: nil} = state) do
    {:ok, Map.put(state, :evidence, nil)}
  end

  defp evidence_collection_node(%{config: config} = state) do
    subject = %{
      workspace: Map.get(state, :workspace_path, ""),
      repo: nil,
      ref: nil,
      issue_number: nil
    }

    evidence = Evidence.collect(config, subject, backends: [])
    {:ok, Map.put(state, :evidence, evidence)}
  end

  defp completion_node(state) do
    {:ok, Map.put(state, :completed_at, DateTime.utc_now())}
  end
end
