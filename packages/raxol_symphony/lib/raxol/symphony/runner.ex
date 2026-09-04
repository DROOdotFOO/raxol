defmodule Raxol.Symphony.Runner do
  @moduledoc """
  Behaviour for an Agent Runner -- the component that executes a coding agent
  on a single issue (SPEC s10.7).

  An implementation receives a per-issue workspace + prompt + tracker access
  and runs the coding-agent session until the work either:

  - Finishes (returns `:ok`); the orchestrator schedules a continuation retry
    to re-check whether the issue is still active.
  - Fails (returns `{:error, reason}`); the orchestrator schedules an
    exponential-backoff retry.
  - Pauses (returns `{:pause, interrupt_reason :: atom(), token :: term()}`);
    the orchestrator parks the run in its `paused` map and does NOT schedule
    a retry. A subsequent `Raxol.Symphony.Orchestrator.resume_run/3` call
    re-dispatches the runner with `:resume_token` (the prior `token`) and
    `:resume_value` (the caller-supplied resume payload) in `opts`. The
    runner is responsible for serializing whatever state it needs into the
    `token` so a fresh process can pick up where the prior one left off.

  Available implementations:

  - `Raxol.Symphony.Runners.Noop` -- test-only runner with configurable
    behaviour.
  - `Raxol.Symphony.Runners.RaxolAgent` -- DEFAULT; wraps the `raxol_agent`
    `Stream` API.
  - `Raxol.Symphony.Runners.Codex` -- Port-based Codex app-server (JSON-RPC
    2.0 over stdio, mirrors upstream Symphony Elixir).

  ## Workspace

  `opts[:workspace_path]` is the per-issue directory the orchestrator allocated
  under `config.workspace.root`, and it is REQUIRED rather than advisory: a
  runner that ignores it runs against whatever cwd the orchestrator process
  happens to have. `Raxol.Symphony.Runners.RaxolAgent` threads it into the
  agent's tool context as `:cwd`; `Raxol.Symphony.Runners.Codex` passes it as
  the Codex session root. Both raise when it is absent, so a run is never
  silently unconfined.

  ## Sending updates back

  The runner SHOULD forward agent events to the orchestrator via the `:parent`
  pid in `opts`:

      send(opts[:parent], {:run_event, issue.id, event})

  Events are free-form maps; the orchestrator extracts standard fields
  (`event`, `timestamp`, optional `usage`, optional `message`).

  Implementations MUST be safe to run inside `Task.Supervisor` -- they cannot
  rely on process-dictionary state from the orchestrator.
  """

  alias Raxol.Symphony.{Config, Issue}

  @type opts :: [
          parent: pid(),
          attempt: pos_integer() | nil,
          workspace_path: Path.t(),
          resume_token: term() | nil,
          resume_value: term() | nil
        ]

  @type result :: :ok | {:error, term()} | {:pause, atom(), term()}

  @callback run(Issue.t(), Config.t(), opts()) :: result()

  @doc """
  Declare the canonical set of interrupt-reason atoms this runner can
  emit in its `{:pause, reason, token}` returns.

  Optional. Implementing it documents the runner's pause vocabulary
  and lets `Raxol.Symphony.PauseReason.awaiting?/1` mechanically
  enforce the `:awaiting_<subject>` naming convention via the shared
  convention test. Every pause names what the run is waiting FOR, so an
  operator surface can render the reason without a per-runner lookup
  table.

  Runners whose reasons are entirely user-supplied (e.g.
  `Raxol.Symphony.Runners.Noop`, `Raxol.Symphony.Runners.RaxolAgent`
  when the operator wires a `pause_detector`) should NOT implement
  this callback -- the convention is enforced on the caller's
  side, not the runner's.
  """
  @callback pause_reasons() :: [atom()]

  @optional_callbacks pause_reasons: 0

  @doc """
  Resolves the runner module from config, with optional override.

  Resolution order:

  1. `:runner_module` option (used by tests).
  2. `config.runner.kind` mapping:
     - `"raxol_agent"` -> `Raxol.Symphony.Runners.RaxolAgent`
     - `"raxol_agent_session"` -> `Raxol.Symphony.Runners.RaxolAgentSession`
     - `"codex"` -> `Raxol.Symphony.Runners.Codex`
     - `"noop"` -> `Raxol.Symphony.Runners.Noop`
  """
  @spec resolve(Config.t(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve(%Config{} = config, opts \\ []) do
    case Keyword.get(opts, :runner_module) do
      nil -> resolve_from_config(config)
      mod when is_atom(mod) -> {:ok, mod}
    end
  end

  defp resolve_from_config(%Config{runner: %{kind: "raxol_agent"}}),
    do: {:ok, Raxol.Symphony.Runners.RaxolAgent}

  defp resolve_from_config(%Config{runner: %{kind: "raxol_agent_session"}}),
    do: {:ok, Raxol.Symphony.Runners.RaxolAgentSession}

  defp resolve_from_config(%Config{runner: %{kind: "codex"}}),
    do: {:ok, Raxol.Symphony.Runners.Codex}

  defp resolve_from_config(%Config{runner: %{kind: "noop"}}),
    do: {:ok, Raxol.Symphony.Runners.Noop}

  defp resolve_from_config(%Config{runner: %{kind: "review"}}),
    do: {:ok, Raxol.Symphony.Runners.Review}

  defp resolve_from_config(%Config{runner: %{kind: kind}}),
    do: {:error, {:unsupported_runner_kind, kind}}
end
