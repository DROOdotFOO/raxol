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

  Available implementations:

  - `Raxol.Symphony.Runners.Noop` -- test-only runner with configurable
    behaviour.
  - `Raxol.Symphony.Runners.RaxolAgent` -- DEFAULT; wraps the `raxol_agent`
    `Stream` API.
  - `Raxol.Symphony.Runners.Codex` -- Port-based Codex app-server (JSON-RPC
    2.0 over stdio, mirrors upstream Symphony Elixir).

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
          workspace_path: Path.t()
        ]

  @callback run(Issue.t(), Config.t(), opts()) :: :ok | {:error, term()}

  @doc """
  Resolves the runner module from config, with optional override.

  Resolution order:

  1. `:runner_module` option (used by tests).
  2. `config.runner.kind` mapping:
     - `"raxol_agent"` -> `Raxol.Symphony.Runners.RaxolAgent`
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

  defp resolve_from_config(%Config{runner: %{kind: "codex"}}),
    do: {:ok, Raxol.Symphony.Runners.Codex}

  defp resolve_from_config(%Config{runner: %{kind: "noop"}}),
    do: {:ok, Raxol.Symphony.Runners.Noop}

  defp resolve_from_config(%Config{runner: %{kind: kind}}),
    do: {:error, {:unsupported_runner_kind, kind}}
end
