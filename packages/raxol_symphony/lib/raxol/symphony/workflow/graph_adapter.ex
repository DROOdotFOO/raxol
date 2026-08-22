defmodule Raxol.Symphony.Workflow.GraphAdapter do
  @moduledoc """
  Builds a `Raxol.Workflow.Graph` that represents the canonical Symphony
  pipeline using main raxol's workflow primitive.

  This adapter is the opt-in path. The default
  Symphony orchestrator runs the prompt-only path through `Orchestrator`;
  consumers that want graph-shaped execution call `from_workflow/2` to
  build a compiled graph and dispatch it through `Raxol.Workflow.Compiled`
  themselves.

  ## Canonical pipeline

  The graph wires the orchestrator's inline stages into discrete nodes
  the workflow runtime can checkpoint individually:

      :__start__ -> :tracker_poll -> :candidate_selection
        -> :runner_dispatch -> [:runner_wait -> :runner_dispatch] *
        -> :evidence_collection -> :completion -> :__end__

  `:runner_dispatch` and `:runner_wait` form a pause/resume loop: when
  the runner returns `{:pause, reason, token}`, `:runner_dispatch`
  stashes the pause context and routes to `:runner_wait`, which calls
  `Raxol.Workflow.interrupt/1` so the runtime checkpoints + surfaces
  `{:interrupted, run_id, state, {reason, token}}` to the caller. On
  `Compiled.resume/3` the wait node pops the resume value, stashes it
  in state, and routes back to `:runner_dispatch`, which re-invokes the
  runner with `resume_token` + `resume_value` opts. The loop continues
  until the runner returns `:ok` or `{:error, _}`.

  Each node accumulates fields into the workflow state map:

  | Node                  | Reads                          | Writes                |
  | --------------------- | ------------------------------ | --------------------- |
  | `tracker_poll`        | `config`                       | `candidates`          |
  | `candidate_selection` | `candidates`                   | `candidate`           |
  | `runner_dispatch`     | `candidate`, `config`,         | `run_result` *or*     |
  |                       | `runner_pending_resume`        | `runner_pause`        |
  | `runner_wait`         | `runner_pause`                 | `runner_pending_resume` |
  | `evidence_collection` | `candidate`, `config`          | `evidence`            |
  | `completion`          | `run_result`,`evidence`        | `completed_at`        |

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

  ## Orchestrator integration

  Setting `workflow_mode: :graph` in the workflow config flips the
  `Raxol.Symphony.Orchestrator` worker payload to invoke through this
  adapter. The orchestrator pre-seeds `:candidates`, `:candidate`,
  `:parent_pid`, `:attempt`, and `:workspace_path` in the initial
  state; `tracker_poll` short-circuits when `:candidates` is already
  set so the orchestrator's eligibility decision is not overwritten
  by a second tracker round-trip.

  ## Out of scope (deferred to follow-up PRs)

  - Per-node tracker / runner overrides via custom node bodies. The
    adapter ships one canonical shape; richer composition is a later
    concern.
  """

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Evidence
  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Runner
  alias Raxol.Symphony.Tracker
  alias Raxol.Symphony.Workspace
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
          optional(:workspaces) => [Path.t()],
          optional(:hosts) => [term() | nil],
          optional(:host) => term() | nil,
          optional(:candidate) => Issue.t() | nil,
          optional(:run_result) => :ok | {:error, term()},
          optional(:runner_pause) => {atom(), term()} | nil,
          optional(:runner_pending_resume) => {term(), term()} | nil,
          optional(:evidence) => Evidence.t(),
          optional(:completed_at) => DateTime.t(),
          optional(:runner_module) => module() | nil,
          optional(:parent_pid) => pid(),
          optional(:attempt) => non_neg_integer() | nil,
          optional(:workspace_path) => Path.t()
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
    |> Graph.add_node(:runner_wait, &runner_wait_node/1)
    |> Graph.add_node(:evidence_collection, &evidence_collection_node/1)
    |> Graph.add_node(:completion, &completion_node/1)
    |> Graph.add_edge(:__start__, :tracker_poll)
    |> Graph.add_edge(:tracker_poll, :candidate_selection)
    |> Graph.add_edge(:candidate_selection, :runner_dispatch)
    |> Graph.add_conditional_edge(
      :runner_dispatch,
      [:runner_wait, :evidence_collection],
      &choose_after_runner_dispatch/1
    )
    |> Graph.add_edge(:runner_wait, :runner_dispatch)
    |> Graph.add_edge(:evidence_collection, :completion)
    |> Graph.add_edge(:completion, :__end__)
    |> Graph.compile(compile_opts(opts))
  end

  defp choose_after_runner_dispatch(%{runner_pause: pause}) when not is_nil(pause),
    do: :runner_wait

  defp choose_after_runner_dispatch(_state), do: :evidence_collection

  @default_max_candidates 3

  @doc """
  Build and compile a parallel-candidate variant of the Symphony graph.

  Each slot 0..N-1 runs its own dispatch + evidence sub-graph concurrently
  via ADR-0019 fan-out. After every branch completes, an aggregate node
  merges per-slot `run_result` / `evidence` into `:run_results` /
  `:evidences` lists keyed by candidate id.

  ## Options

    * `:max_candidates` -- static branch count (default `#{@default_max_candidates}`).
      Excess candidates beyond this slot count are ignored (the
      orchestrator-level concurrency is unchanged).
    * `:saver`, `:failure_policy`, `:step_timeout_ms`, `:run_timeout_ms`
      -- same as `from_workflow/1`.

  ## Branch pauses

  A per-slot runner may return `{:pause, reason, token}`; the slot records
  it verbatim as its `run_result` and the aggregate surfaces it alongside
  the completed branches. Unlike `from_workflow/1`, the graph run does NOT
  interrupt on a pause — sibling branches run to completion, and the paused
  branch's evidence is left `nil` (the workspace is only half-done). The
  orchestrator parks the pause token and re-dispatches the paused issue on
  resume; there is no whole-batch rollback.
  """
  @spec from_workflow_parallel(keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def from_workflow_parallel(opts) do
    max_candidates = Keyword.get(opts, :max_candidates, @default_max_candidates)
    slots = 0..(max_candidates - 1) |> Enum.to_list()
    branch_entries = Enum.map(slots, &slot_prepare_id/1)

    base_graph =
      Graph.new(:symphony_parallel)
      |> Graph.add_node(:tracker_poll, &tracker_poll_node/1)
      |> Graph.add_node(:fan_out_candidates, fn s -> {:ok, s} end)
      |> Graph.add_node(:aggregate, fn s -> {:ok, aggregate_results(s, slots)} end)
      |> Graph.add_node(:completion, &completion_node/1)

    graph_with_slot_nodes =
      Enum.reduce(slots, base_graph, fn slot, g -> add_slot_nodes(g, slot) end)

    graph_with_static_edges =
      graph_with_slot_nodes
      |> Graph.add_edge(:__start__, :tracker_poll)
      |> Graph.add_edge(:tracker_poll, :fan_out_candidates)
      |> Graph.add_conditional_edge(
        :fan_out_candidates,
        branch_entries,
        fn _ -> branch_entries end
      )
      |> Graph.add_join(:aggregate, branch_entries)
      |> Graph.add_edge(:aggregate, :completion)
      |> Graph.add_edge(:completion, :__end__)

    full_graph =
      Enum.reduce(slots, graph_with_static_edges, fn slot, g -> add_slot_edges(g, slot) end)

    Graph.compile(full_graph, compile_opts(opts))
  end

  defp slot_prepare_id(n), do: :"slot_prepare_#{n}"
  defp slot_dispatch_id(n), do: :"slot_dispatch_#{n}"
  defp slot_evidence_id(n), do: :"slot_evidence_#{n}"

  defp add_slot_nodes(graph, slot) do
    graph
    |> Graph.add_node(slot_prepare_id(slot), build_slot_prepare(slot))
    |> Graph.add_node(slot_dispatch_id(slot), build_slot_dispatch(slot))
    |> Graph.add_node(slot_evidence_id(slot), build_slot_evidence(slot))
  end

  defp add_slot_edges(graph, slot) do
    graph
    |> Graph.add_edge(slot_prepare_id(slot), slot_dispatch_id(slot))
    |> Graph.add_edge(slot_dispatch_id(slot), slot_evidence_id(slot))
    |> Graph.add_edge(slot_evidence_id(slot), :aggregate)
  end

  defp build_slot_prepare(slot) do
    candidate_key = :"candidate_#{slot}"
    workspace_key = :"workspace_#{slot}"

    fn state ->
      candidates = Map.get(state, :candidates, [])
      candidate = Enum.at(candidates, slot)
      workspace = slot_workspace(state, slot)

      {:ok,
       state
       |> Map.put(candidate_key, candidate)
       |> Map.put(workspace_key, workspace)}
    end
  end

  # Per-slot workspace isolation: each fan-out branch runs its candidate in
  # its own workspace so concurrent runners never share a working directory.
  # Falls back to the shared `:workspace_path` when no per-slot list is seeded
  # (e.g. a single-candidate invocation).
  defp slot_workspace(state, slot) do
    workspaces = Map.get(state, :workspaces, [])
    Enum.at(workspaces, slot) || Map.get(state, :workspace_path, "")
  end

  # Per-slot reserved host (from the orchestrator's host pool), so a fan-out
  # branch runs on the slot the orchestrator reserved for it. `nil` (no pool,
  # or a slot past the free-host count) means local execution.
  defp slot_host(state, slot) do
    Enum.at(Map.get(state, :hosts, []), slot)
  end

  defp build_slot_dispatch(slot) do
    candidate_key = :"candidate_#{slot}"
    workspace_key = :"workspace_#{slot}"
    result_key = :"run_result_#{slot}"

    fn state ->
      case Map.get(state, candidate_key) do
        nil -> {:ok, Map.put(state, result_key, nil)}
        %Issue{} = issue -> dispatch_slot(state, issue, slot, workspace_key, result_key)
      end
    end
  end

  defp dispatch_slot(state, %Issue{} = issue, slot, workspace_key, result_key) do
    runner_opts = if state.runner_module, do: [runner_module: state.runner_module], else: []
    workspace = Map.get(state, workspace_key) || Map.get(state, :workspace_path, "")
    host = slot_host(state, slot)

    run_opts = base_run_opts(state, workspace, host)

    with {:ok, runner_module} <- Runner.resolve(state.config, runner_opts) do
      # Bracketed per SLOT, not per batch: each slot has its own issue, its own
      # workspace and (in a host pool) its own machine, so one `before_run`
      # covering all of them would run the wrong hook in the wrong place. A slot
      # whose `before_run` fails records the failure as ITS result and leaves
      # its siblings running -- the same shape as a branch pause, and the reason
      # this does not abort the whole graph.
      #
      # A branch pause is recorded verbatim as the slot result and surfaced
      # through the aggregate. The graph run itself does NOT interrupt (unlike
      # `from_workflow/1`) -- the orchestrator parks the pause token and
      # re-dispatches the paused issue on resume.
      outcome =
        Workspace.around_run(state.config, workspace, hook_opts(state, host), fn ->
          runner_module.run(issue, state.config, run_opts)
        end)

      {:ok, Map.put(state, result_key, slot_result(outcome))}
    end
  end

  defp build_slot_evidence(slot) do
    candidate_key = :"candidate_#{slot}"
    workspace_key = :"workspace_#{slot}"
    result_key = :"run_result_#{slot}"
    evidence_key = :"evidence_#{slot}"

    fn state ->
      case {Map.get(state, candidate_key), Map.get(state, result_key)} do
        {nil, _} ->
          {:ok, Map.put(state, evidence_key, nil)}

        # A paused branch has not finished; collecting evidence now would
        # capture a half-done workspace. Leave it nil until the resume.
        {%Issue{}, {:pause, _reason, _token}} ->
          {:ok, Map.put(state, evidence_key, nil)}

        {%Issue{}, _result} ->
          subject = %{
            workspace: Map.get(state, workspace_key) || Map.get(state, :workspace_path, ""),
            repo: nil,
            ref: nil,
            issue_number: nil
          }

          evidence = Evidence.collect(state.config, subject, backends: [])
          {:ok, Map.put(state, evidence_key, evidence)}
      end
    end
  end

  defp aggregate_results(state, slots) do
    {run_results, evidences} =
      Enum.reduce(slots, {[], []}, fn slot, {results, evidences} ->
        candidate = Map.get(state, :"candidate_#{slot}")
        run_result = Map.get(state, :"run_result_#{slot}")
        evidence = Map.get(state, :"evidence_#{slot}")

        case candidate do
          nil ->
            {results, evidences}

          %Issue{id: id} ->
            {[{id, run_result} | results], [{id, evidence} | evidences]}
        end
      end)

    state
    |> Map.put(:run_results, Enum.reverse(run_results))
    |> Map.put(:evidences, Enum.reverse(evidences))
  end

  defp compile_opts(opts) do
    opts
    |> Keyword.take([
      :saver,
      :failure_policy,
      :step_timeout_ms,
      :run_timeout_ms
    ])
  end

  @doc """
  Build the initial state expected by the graph.

  Pass the result as the second argument to `Compiled.invoke/3`. The
  state seeds `config`, `runner_module`, and any other adapter-side
  keys the nodes read.
  """
  @spec initial_state(keyword()) :: state()
  def initial_state(opts) do
    base = %{
      config: Keyword.fetch!(opts, :config),
      runner_module: Keyword.get(opts, :runner_module)
    }

    base
    |> maybe_put(:candidates, Keyword.get(opts, :candidates))
    |> maybe_put(:candidate, Keyword.get(opts, :candidate))
    |> maybe_put(:workspaces, Keyword.get(opts, :workspaces))
    |> maybe_put(:hosts, Keyword.get(opts, :hosts))
    |> maybe_put(:parent_pid, Keyword.get(opts, :parent_pid))
    |> maybe_put(:attempt, Keyword.get(opts, :attempt))
    |> maybe_put(:workspace_path, Keyword.get(opts, :workspace_path))
    |> maybe_put(:host, Keyword.get(opts, :host))
    |> maybe_put(:ssh, Keyword.get(opts, :ssh))
  end

  # The workspace run hooks a runner node brackets its runner with. `:host` is
  # per-slot in a parallel graph and shared otherwise; `:ssh` is the transport
  # the orchestrator was configured with, identical for every slot.
  defp hook_opts(state, host), do: [host: host, ssh: Map.get(state, :ssh, [])]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Node bodies ---

  # When the orchestrator pre-seeds `:candidates` (workflow_mode :graph
  # routes one orchestrator-chosen issue per worker), skip the tracker
  # round-trip entirely. The orchestrator already ran its eligibility
  # gate; re-polling would race and could overwrite the pre-seeded list.
  defp tracker_poll_node(%{candidates: pre_seeded} = state)
       when is_list(pre_seeded) and pre_seeded != [] do
    {:ok, state}
  end

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
    {:ok,
     state
     |> Map.put(:run_result, {:error, :no_candidate})
     |> Map.put(:runner_pause, nil)}
  end

  defp runner_dispatch_node(%{candidate: %Issue{} = issue, config: config} = state) do
    runner_opts =
      if state.runner_module, do: [runner_module: state.runner_module], else: []

    workspace = Map.get(state, :workspace_path, "")
    host = Map.get(state, :host)
    {resume_token, resume_value, state} = consume_pending_resume(state)

    run_opts =
      maybe_put_resume_opts(base_run_opts(state, workspace, host), resume_token, resume_value)

    with {:ok, runner_module} <- Runner.resolve(config, runner_opts) do
      config
      |> Workspace.around_run(workspace, hook_opts(state, host), fn ->
        runner_module.run(issue, config, run_opts)
      end)
      |> store_bracketed_result(state)
    end
  end

  # What every runner invocation is handed, however it was reached: the pid to
  # report events to, which attempt this is, and where (and on what machine) to
  # run. The parallel slots build the same list from their own per-slot values.
  defp base_run_opts(state, workspace, host) do
    [
      parent: Map.get(state, :parent_pid, self()),
      attempt: Map.get(state, :attempt) || 1,
      workspace_path: workspace,
      host: host
    ]
  end

  # SPEC s9.4: a `before_run` failure is fatal to this run attempt. A node error
  # is how the graph says that, and `graph_outcome/1` turns it into the same
  # failure retry a runner error gets.
  defp store_bracketed_result({:error, reason}, _state), do: {:error, reason}
  defp store_bracketed_result({:ok, result}, state), do: {:ok, store_runner_result(state, result)}

  # A `before_run` that failed is this slot's result, in the shape the
  # aggregate already understands, so one slot cannot fail the batch.
  defp slot_result({:ok, result}), do: result
  defp slot_result({:error, reason}), do: {:error, reason}

  defp maybe_put_resume_opts(opts, nil, nil), do: opts

  defp maybe_put_resume_opts(opts, token, value) do
    opts ++ [resume_token: token, resume_value: value]
  end

  defp consume_pending_resume(%{runner_pending_resume: {token, value}} = state) do
    {token, value, Map.put(state, :runner_pending_resume, nil)}
  end

  defp consume_pending_resume(state), do: {nil, nil, state}

  defp store_runner_result(state, {:pause, reason, token}) when is_atom(reason) do
    state
    |> Map.put(:runner_pause, {reason, token})
    |> Map.put(:run_result, nil)
  end

  defp store_runner_result(state, result) do
    state
    |> Map.put(:run_result, result)
    |> Map.put(:runner_pause, nil)
  end

  defp runner_wait_node(%{runner_pause: {reason, token}} = state) do
    # `interrupt/1` throws on first execution; the runtime catches the
    # throw, persists `state_before_node` (which carries `runner_pause`),
    # and surfaces `{:interrupted, run_id, state, {reason, token}}` to
    # the caller. On `Compiled.resume/3` this node re-runs with the
    # caller's resume value in the scratchpad; `interrupt/1` returns it
    # without throwing.
    resume_value = Raxol.Workflow.interrupt({reason, token})

    {:ok,
     state
     |> Map.put(:runner_pending_resume, {token, resume_value})
     |> Map.put(:runner_pause, nil)}
  end

  # Defensive: a misconfigured run reaches the wait node without a
  # `:runner_pause` set (e.g. the chooser was bypassed). Treat the
  # absence as `:ok` and fall through; the next dispatch sees no
  # pending_resume and runs the runner fresh.
  defp runner_wait_node(state), do: {:ok, state}

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
