# Symphony Graduation Runbook

The steps a human runs to graduate `raxol_symphony`: drive real issues to PRs
against a live GitHub repo, capture evidence, then publish 0.2.0 to Hex. The
code is release-packaged; these steps are the parts an agent cannot do
(they touch a live repo and interactive Hex auth).

Per issue #503 the natural first target is **dogfooding this repo**
(`DROOdotFOO/raxol`): the orchestrator picks up sibling issues and drives them.

## 1. Prerequisites

- `GITHUB_TOKEN` with `repo` scope (a PAT for the target repo).
- An AI backend key for the runner, e.g. `ANTHROPIC_API_KEY`. See the backend
  table in the root `ROADMAP.md` for the alternatives.
- `git` and `gh` on `PATH`. Optional: `cloc` for richer complexity evidence.
- Deps synced: `cd packages/raxol_symphony && MIX_ENV=test mix deps.get`.

## 2. Blast-radius control (do this first)

The GitHub tracker keys off `state/<slug>` labels (`state/todo`,
`state/in-progress`, `state/done`, ...). The orchestrator only dispatches
issues whose label matches `tracker.active_states`. Scope the first run by
applying `state/todo` to **one or two low-risk issues only** and leaving
everything else unlabelled. Nothing without a matching state label is touched.

## 3. Write `WORKFLOW.md`

YAML front matter is the config; the body is the agent prompt template.

```markdown
---
tracker:
  kind: github
  project_slug: DROOdotFOO/raxol
  api_key: $GITHUB_TOKEN
  active_states:
    - Todo            # -> state/todo label
  terminal_states:
    - Done            # -> state/done label
    - Closed
polling:
  interval_ms: 30000
workspace:
  root: ./.symphony/workspaces
workflow_mode: graph_parallel   # or `graph` / `default`
workflow_parallelism: 2         # batch size for graph_parallel
recording:
  enabled: true                 # writes per-run asciicast under the workspace
runner:
  kind: raxol_agent
  agent:
    backend: anthropic
    model: claude-sonnet-4-6
    api_key: $ANTHROPIC_API_KEY
    max_turns: 20
---
You are an autonomous coding agent working a single GitHub issue in an
isolated workspace. Implement the change on a feature branch, keep the
diff focused, run the project's checks, and open a pull request that
references the issue. Stop when the PR is open.
```

`workflow_mode: graph_parallel` fans up to `workflow_parallelism` eligible
issues through one graph run per tick. A branch that pauses is parked as
resumable, the same way a sequential run is; compensating the sibling branches
that already completed is still open (#517). Use `default` for the simplest
inline path, or `graph` for the per-node checkpointed pipeline.

## 4. start the orchestrator

```elixir
# from packages/raxol_symphony, `iex -S mix`
{:ok, _sup} = Raxol.Symphony.Supervisor.start_link(workflow_path: "WORKFLOW.md")
```

`Supervisor` starts the `Task.Supervisor`, a `WorkflowStore` (watches
`WORKFLOW.md` for hot-reload), and the `Orchestrator` (auto-ticks on the
`polling.interval_ms` cadence). Watch progress:

```elixir
Raxol.Symphony.Orchestrator.snapshot()
# => %{counts: %{running: _, retrying: _, paused: _, batches: _}, running: [...], batches: [...]}
```

Or attach a richer surface (terminal dashboard / LiveView / MCP / Telegram /
Watch / JSON API). All six consume the same snapshot over `Phoenix.PubSub`.

## 5. Capture evidence

Asciicasts land under `<workspace>/.raxol_symphony/run-<attempt>-<stamp>.cast`
when `recording.enabled: true`. One file per dispatch, not per run: a run that
continues or resumes writes a further fragment each time rather than truncating
the one before it, so replay a long run fragment by fragment in dispatch order.
Fragments live until the workspace is removed. Aggregate CI + PR evidence for a
run:

```elixir
Raxol.Symphony.Evidence.collect(config, %{
  workspace: workspace_path,
  repo: "DROOdotFOO/raxol",
  ref: "the-feature-branch",
  issue_number: 503
})
# => %Evidence{ci: %{...}, pr_comments: [...], complexity: %{...}, recordings: [...]}
```

Save the resulting PR URL(s), CI status, and `.cast` path(s) as the graduation
evidence.

## 6. Publish 0.2.0 to Hex

Once at least one issue has been driven to a PR with evidence captured:

```bash
cd packages/raxol_symphony
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish
```

`HEX_BUILD=1` strips the local `path:` deps so the build sees only Hex
packages. `raxol_symphony` publishes **independently of `raxol_earn`**: the
`raxol_earn` dependency is `only: :test` (`mix.exs`), so it is not a published
requirement. All published requirements (`raxol_core`, `raxol`, `raxol_agent`,
`raxol_mcp`) are already on Hex at `~> 2.6`.

## 7. Safety notes

- The default `raxol_agent` runner denies shell operations outside the
  per-issue workspace (`CommandHook` + `PermissionHook`). See `SPEC.md` s15.
- Start with `workflow_parallelism: 1` or `2` and a single labelled issue;
  widen only after the first clean PR.
- `stop_run/2` kills a single running issue; killing the orchestrator process
  cleanly abandons in-flight workers (they run under the `Task.Supervisor`).
