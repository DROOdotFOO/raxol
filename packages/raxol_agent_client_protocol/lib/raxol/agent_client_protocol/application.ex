defmodule RaxolAgentClientProtocol.Application do
  @moduledoc """
  The package OTP application — the single shared supervision tree that the
  per-connection subtrees and the reattach extension depend on
  (`acp-supervision-design.md` §1.3, `acp-reattach-design.md` §2.1,
  `acp-attachpolicy-design.md` §3.3).

  ## What it starts (the load-bearing wiring gap this module closes)

  The `Connection`/`Session` per-connection subtree is started PER CONNECTION
  (library mode via `Agent.child_spec/1` / `Client.child_spec/1`, or standalone
  via `ConnectionsSupervisor`). But three things are **package-level shared** —
  a durable session outlives every connection (supervision §1.1: process
  identity ≠ session identity), and the attach funnel is one per node:

    1. `Raxol.AgentClientProtocol.SessionRegistry` — the ONE package-level unique
       `Registry` keyed `{conn_pid, session_id}` (§1.3). The `Connection` reads
       it for `session/cancel` direct dispatch (IC-5b), so its name is contract.
    2. `Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry` +
       `Raxol.AgentClientProtocol.Ext.Journal.WriterSupervisor` — the journal
       single-publisher Writers, started lazily on first append/subscribe
       (reattach §2.1). `Ext.Journal.ensure_writer/3` starts them here.
    3. `Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor` — the
       `Task.Supervisor` the fail-closed admission funnel isolates policy tasks
       under (attachpolicy §3.3). **Without it, a REAL attach denies
       `:policy_infra` on every request** — the `[G5:S18]` fail-closed leg,
       correct but useless for a legitimate attach.

  It also starts `Raxol.AgentClientProtocol.ConnectionsSupervisor`, the
  standalone-mode `DynamicSupervisor` under which `mix acp.serve` /
  programmatic `connect/3` place a `ConnectionSupervisor` (§1.3/§1.4).

  ## Test opt-out

  The application module is declared in `mix.exs` (`mod:`), so it auto-starts
  outside `:test`. Under `MIX_ENV=test` it starts an **empty tree** so the
  package's own suite (which starts each named supervisor manually, per test,
  with the SAME names) is never disturbed by a colliding auto-started one.
  The env is captured at COMPILE time (`@auto_start`), so no `Mix` call happens
  at runtime / in a release.

  ## Library mode (embedder does NOT want our Application)

  An embedder who assembles their own tree calls `children/0` and splices the
  returned child specs into their own supervisor — the exact list this module
  starts, so the module names the modules resolve against (`Runner`'s default
  `Task.Supervisor`, `Writer.registry/0`, `Session.registry/0`) are satisfied
  by the embedder's tree with zero further wiring.
  """

  use Application

  @session_registry Raxol.AgentClientProtocol.SessionRegistry
  @writer_registry Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry
  @writer_supervisor Raxol.AgentClientProtocol.Ext.Journal.WriterSupervisor
  @attach_task_supervisor Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor
  @connections_supervisor Raxol.AgentClientProtocol.ConnectionsSupervisor

  # Captured at compile time: the package's own test suite starts every named
  # supervisor manually, so the auto-started tree MUST be empty under :test to
  # avoid `{:already_started, _}` name collisions. A boolean literal is baked in
  # here, so nothing calls `Mix` at runtime.
  @auto_start Mix.env() != :test

  @impl Application
  def start(_type, _args) do
    children = if @auto_start, do: children(), else: []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RaxolAgentClientProtocol.Supervisor
    )
  end

  @doc """
  The package-level shared child specs (supervision §1.3, reattach §2.1,
  attachpolicy §3.3). Library-mode embedders splice this into their own tree
  instead of relying on the auto-started `Application`.

  All ids are the module names each spec registers under, which is exactly what
  the consuming modules resolve against by default — so nothing else needs to
  be named or configured.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      # (1) the ONE package-level Session registry (IC-8 / §1.3).
      {Registry, keys: :unique, name: @session_registry},
      # (2) the journal single-publisher Writers (reattach §2.1).
      {Registry, keys: :unique, name: @writer_registry},
      {DynamicSupervisor, name: @writer_supervisor, strategy: :one_for_one},
      # (3) the attach-policy fail-closed funnel's Task.Supervisor
      #     (attachpolicy §3.3; without it every attach denies :policy_infra).
      {Task.Supervisor, name: @attach_task_supervisor},
      # standalone-mode connection host (§1.3/§1.4).
      {DynamicSupervisor, name: @connections_supervisor, strategy: :one_for_one}
    ]
  end

  @doc "The standalone-mode `DynamicSupervisor` name (§1.3/§1.4)."
  @spec connections_supervisor() :: atom()
  def connections_supervisor, do: @connections_supervisor

  @doc "The journal Writer `DynamicSupervisor` name (reattach §2.1) — where `Ext.Journal.ensure_writer/3` starts Writers."
  @spec writer_supervisor() :: atom()
  def writer_supervisor, do: @writer_supervisor
end
