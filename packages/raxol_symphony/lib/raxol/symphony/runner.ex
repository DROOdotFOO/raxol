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

  Available implementations, declared once in `@kinds` (ADR-0034 Gap 4: the
  resolver clauses, the operator-configurable set and the vendor identities
  all derive from that one list, so they cannot drift apart):

  - `"raxol_agent"` -> `Raxol.Symphony.Runners.RaxolAgent` -- DEFAULT; wraps
    the `raxol_agent` `Stream` API. Vendor `:raxol`.
  - `"raxol_agent_session"` -> `Raxol.Symphony.Runners.RaxolAgentSession` --
    the `Session`-based variant. Vendor `:raxol`.
  - `"codex"` -> `Raxol.Symphony.Runners.Codex` -- Port-based Codex
    app-server (JSON-RPC 2.0 over stdio, mirrors upstream Symphony Elixir).
    Vendor `:codex`.
  - `"review"` -> `Raxol.Symphony.Runners.Review` -- cross-vendor review
    decorator. Not a vendor of its own; it delegates to two others.
  - `"noop"` -> `Raxol.Symphony.Runners.Noop` -- test-only runner with
    directable behaviour. Resolvable but NOT operator-configurable, so it is
    absent from `Raxol.Symphony.Config.Schema`'s supported set.

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

  # ADR-0034 Gap 4: the one declaration every runner-kind surface derives
  # from. Before this, `resolve_from_config/1` handled five kinds while
  # `Config.Schema` declared three, so `raxol_agent_session` and `noop`
  # resolved and then failed their own preflight.
  #
  # `vendor` is the review-relevant identity (ADR-0034 Gap 5): two runner
  # kinds that share a vendor are the same vendor wearing two hats and cannot
  # review each other. `nil` means "not a review vendor at all" -- `review`
  # is a decorator over two other kinds, and `noop` is inert, so a `noop`
  # reviewer would rubber-stamp every diff.
  #
  # `configurable?: false` marks a kind that stays resolvable but is not
  # valid in a WORKFLOW.md. `noop` reads its per-issue directive from a
  # named `Raxol.Symphony.Runners.Noop.Director` process that only tests
  # start, so an operator naming it would get a crash at dispatch rather
  # than an inert run: declaring it supported config would be a promise the
  # runner cannot keep. It stays in the resolver because the orchestrator's
  # own tests drive it through `config.runner.kind` (their preflight runs
  # with `skip_runner: true` behind a `:runner_module` override).
  @kinds [
    %{
      kind: "raxol_agent",
      module: Raxol.Symphony.Runners.RaxolAgent,
      vendor: :raxol,
      configurable?: true
    },
    %{
      kind: "raxol_agent_session",
      module: Raxol.Symphony.Runners.RaxolAgentSession,
      vendor: :raxol,
      configurable?: true
    },
    %{
      kind: "codex",
      module: Raxol.Symphony.Runners.Codex,
      vendor: :codex,
      configurable?: true
    },
    %{
      kind: "review",
      module: Raxol.Symphony.Runners.Review,
      vendor: nil,
      configurable?: true
    },
    %{
      kind: "noop",
      module: Raxol.Symphony.Runners.Noop,
      vendor: nil,
      configurable?: false
    }
  ]

  @typedoc """
  Review-relevant vendor identity of a runner kind.

  `nil` for kinds that are not vendors (a decorator or an inert runner).
  `{:unknown, kind}` for a kind absent from `@kinds`: distinctness cannot be
  proven either way, so each unknown kind counts as its own vendor.
  """
  @type vendor :: atom() | nil | {:unknown, String.t()}

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
  Every runner kind `resolve/2` handles, in declaration order.

  This IS the resolver's domain: the `resolve_from_config/1` clauses are
  generated from the same list, so a kind cannot be resolvable without
  appearing here.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: Enum.map(@kinds, & &1.kind)

  @doc """
  The subset of `kinds/0` that is valid in a WORKFLOW.md.

  `Raxol.Symphony.Config.Schema`'s supported set MUST equal this list; the
  runner-kind convention test enforces that.
  """
  @spec configurable_kinds() :: [String.t()]
  def configurable_kinds do
    @kinds |> Enum.filter(& &1.configurable?) |> Enum.map(& &1.kind)
  end

  @doc """
  Review-relevant vendor identity of a runner kind.

  Returns `nil` for a kind that is not a vendor (`"review"`, `"noop"`) and
  `{:unknown, kind}` for a kind this module does not declare.
  """
  @spec vendor(String.t()) :: vendor()
  def vendor(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(&1.kind == kind)) do
      nil -> {:unknown, kind}
      entry -> entry.vendor
    end
  end

  @doc """
  Resolves the runner module from config, with optional override.

  Resolution order:

  1. `:runner_module` option (used by tests).
  2. `config.runner.kind`, mapped through `@kinds` (see the moduledoc for
     the table and `kinds/0` for the resolvable set).
  """
  @spec resolve(Config.t(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve(%Config{} = config, opts \\ []) do
    case Keyword.get(opts, :runner_module) do
      nil -> resolve_from_config(config)
      mod when is_atom(mod) -> {:ok, mod}
    end
  end

  for %{kind: kind, module: module} <- @kinds do
    defp resolve_from_config(%Config{runner: %{kind: unquote(kind)}}),
      do: {:ok, unquote(module)}
  end

  defp resolve_from_config(%Config{runner: %{kind: kind}}),
    do: {:error, {:unsupported_runner_kind, kind}}
end
