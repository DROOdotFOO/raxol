defmodule Raxol.AgentClientProtocol.Session.Supervisor do
  @moduledoc """
  The per-connection `DynamicSupervisor` for `Raxol.AgentClientProtocol.Session`
  processes (supervision design §1.2, §1.3).

  This is child #2 of the `ConnectionSupervisor` subtree
  (`:one_for_all, auto_shutdown: :any_significant`); its siblings are the
  per-connection `Task.Supervisor` (#1) and the `Connection` (#3, significant).
  It is `restart: :permanent`, and its children — Sessions — are **`:temporary`**:

    * A session crash is NOT auto-restarted. A blank respawned session would lie to
      the client (accept prompts against state the client believes exists). Instead
      the crash surfaces as an error on the in-flight request (adopter-death →
      `-32603` at the Connection, IC-4) and the client re-establishes via
      `session/load` — journal replay is the ONLY resurrection path (§1.1).
    * Restart intensity is therefore irrelevant (temporary children never count),
      so a hot-crashing handler can't take the subtree down with it (§1.2).

  Cleanup is entirely monitor-based: a dead Session's `SessionRegistry` key is
  pruned by the Registry's own owner-monitor — there is **no hand-rolled sessions
  map** anywhere (I11). The Session registers itself via its `:via` name inside
  `Session.start_link/1`, so `start_session/2` need only pass the child spec; the
  register-before-respond ordering (I2) is a `start_link`/`init` property, not
  something this module arranges.

  ## Package `Registry` and `Task.Supervisor` wiring

  The `SessionRegistry` is a single package-level, name-registered `Registry` with
  `:unique` keys `{conn_pid, session_id}` (§1.3). Registry names must be atoms, so
  a per-connection registry would need dynamic atoms — the atom-DoS this package
  bans; hence ONE shared Registry, keyed by the (stable-for-the-subtree-lifetime)
  Connection pid. It is normally started by the library `Application`; the helpers
  here (`registry_child_spec/0`, `child_specs/1`) exist so a host tree — or a test
  — can assemble the pieces without reaching across module boundaries.
  """

  use DynamicSupervisor

  alias Raxol.AgentClientProtocol.Session

  # Per-connection session cap (durable-sessions robustness): a peer cannot open
  # unbounded Sessions on one connection. `start_session/2` returns the
  # DynamicSupervisor's own `{:error, :max_children}` past this — a clean refusal
  # the `session/new`/`session/load` handler maps to a busy/invalid-params error,
  # never a crash or a silent leak. Override per-connection via `:max_sessions`.
  @default_max_sessions 1_000

  # Backstop cap for the sibling per-connection dispatch `Task.Supervisor`
  # (`child_specs/1`): the Connection's own `pending_in` cap sheds inbound
  # requests well before this, so this only bounds a pathological co-tenant
  # spawn burst. Override via `:max_inbound_tasks`.
  @default_max_inbound_tasks 4_000

  @doc """
  Start the per-connection Session `DynamicSupervisor`. Pass `:name` to register
  it (a host tree keys one per connection; tests may start it anonymously);
  `:max_sessions` caps concurrent live Sessions (default #{@default_max_sessions}).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)
    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_sessions)
  end

  @doc """
  Start a Session under this supervisor as a `:temporary` child (§1.2). The Session
  registers itself on `{conn, session_id}` via its `:via` name, so a duplicate live
  id returns `{:error, {:already_started, pid}}` — the caller (the `session/new` /
  `session/load` handler) maps that to invalid-params (§2).

  `session_opts` is the `Session.start_link/1` keyword list (`:session_id`,
  `:conn`, `:mode_state`, `:task_sup`, `:turn_runner`, `:config`, `:conn_mod`).
  """
  @spec start_session(Supervisor.supervisor(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor, session_opts) do
    spec = %{
      id: Session,
      start: {Session, :start_link, [session_opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc """
  Child spec for the package-level `SessionRegistry` (unique keys). A host tree's
  `Application` starts exactly this once; the Connection reads the same Registry
  for `session/cancel` direct dispatch (IC-5b), so the key shape is contract.
  """
  @spec registry_child_spec() :: Supervisor.child_spec()
  def registry_child_spec do
    Registry.child_spec(keys: :unique, name: Session.registry())
  end

  @doc """
  The two per-connection infrastructure children that must start BEFORE the
  Connection (IC-8 start order): the `Task.Supervisor` and this
  `Session.Supervisor`. A host `ConnectionSupervisor` prepends these to its child
  list (Connection last, `significant: true`); the returned `:id`s let the
  Connection resolve the sibling pids in `handle_continue/2`.
  """
  @spec child_specs(
          task_sup_name: term(),
          session_sup_name: term(),
          max_inbound_tasks: pos_integer(),
          max_sessions: pos_integer()
        ) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    task_sup_name = Keyword.get(opts, :task_sup_name)
    session_sup_name = Keyword.get(opts, :session_sup_name)
    max_inbound_tasks = Keyword.get(opts, :max_inbound_tasks, @default_max_inbound_tasks)
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)

    task_sup_opts =
      [max_children: max_inbound_tasks] ++
        if(task_sup_name, do: [name: task_sup_name], else: [])

    session_sup_opts =
      [max_sessions: max_sessions] ++
        if(session_sup_name, do: [name: session_sup_name], else: [])

    [
      Supervisor.child_spec(
        {Task.Supervisor, task_sup_opts},
        id: :acp_task_supervisor,
        restart: :permanent
      ),
      Supervisor.child_spec(
        {__MODULE__, session_sup_opts},
        id: :acp_session_supervisor,
        restart: :permanent
      )
    ]
  end
end
