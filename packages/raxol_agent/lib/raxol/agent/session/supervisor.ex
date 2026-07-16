defmodule Raxol.Agent.Session.Supervisor do
  @moduledoc """
  One supervised OTP subtree per harness session, plus the `session_id → pid`
  registry the Wave 2 units resolve against (U4 reattach, U5/U6 turn
  kill/steer, U9 pointer records).

  ## Tree shape

  `:rest_for_one`, children in dependency order:

    1. `Raxol.Agent.EmitBridge` — the per-session sink. Owns the durable
       journal handle (opened lazily on the first durable event) and the
       EmitBus subscription.
    2. `Raxol.Core.Runtime.Lifecycle` — the per-session TEA runtime (dispatcher
       + model). A **supervised sibling**, not something the session spawns and
       orphans. It emits durable events onto EmitBus, so it must start AFTER the
       sink is subscribed (dependency order). Registered under
       `{:lifecycle, session_id}`.
    3. `Raxol.Agent.Session` — the thin API/forwarder. Started with
       `start_emit_bridge: false` AND `manage_lifecycle: false`: the tree owns
       both the sink and the runtime; the session only looks them up and
       forwards `send_message` / `get_model` to the runtime's dispatcher.

  Why the runtime is a supervised child (not session-spawned): if the session
  owned an unlinked lifecycle, a `stop_session` (or any `:rest_for_one` restart,
  which kills the non-trapping session WITHOUT running `terminate/2`) would
  leave the runtime running forever — a leak — and a later same-`session_id`
  start would reattach to that dead session's stale model. As a tree child the
  runtime is torn down with the subtree and started fresh on every restart:
  the leak and the reattach-to-dead are structurally impossible.

  Why this order: the sink is the resource the runtime *depends on* (durable
  events must have somewhere to land), so it starts first and stops last; the
  runtime depends on it and the session depends on the runtime. Under
  `:rest_for_one`:

    * a **bridge crash** restarts the bridge, THEN the lifecycle, THEN the
      session — the whole tree recovers in dependency order (a FRESH lifecycle,
      so no durable event is ever emitted into a dead-sink gap), and the
      restarted bridge re-registers under `{:emit_bridge, session_id}` (exactly
      one bridge; the journal Writer survives via its own `:global`
      single-writer discipline and is re-joined on the next durable append, so
      offsets stay monotonic);
    * a **session crash** restarts *only* the session — the sink and the
      lifecycle are never orphaned or duplicated, and the restarted session
      re-resolves the SAME running lifecycle (model preserved) via the registry.

  ## Registry keys (all in `Raxol.Agent.Registry`)

    * `{:session_supervisor, session_id}` → this subtree supervisor
    * `{:session, session_id}` → the live `Raxol.Agent.Session` process
      (registered by the session itself, in both supervised and standalone
      modes, so `whereis/1` resolves either)
    * `{:emit_bridge, session_id}` → the sink (pre-existing key, unchanged)

  Session ids are unique: a second `start_session/2` with the same
  `session_id` returns `{:error, {:already_started, pid}}`.

  ## Placement

  Subtrees run under the existing `Raxol.Agent.DynSup` (the agent package's
  DynamicSupervisor, supervised by `Raxol.Agent.Supervisor`), so a session
  tree is crash-isolated from every other session and from the caller.
  `start_session/2` therefore requires `Raxol.Agent.Registry` and
  `Raxol.Agent.DynSup` to be running (boot `Raxol.Agent.Supervisor`, or start
  both directly in tests).

  Note: the journal `FileStore.Writer` keeps its `:global` name (keyed by the
  physical journal *directory*, not by session) — that registration enforces
  the single-writer-per-dir invariant across sessions, base dirs and (on
  shared storage) nodes, which a per-session Registry key cannot express.
  See `Raxol.Agent.Journal.FileStore.Writer.global_name/1`.
  """

  use Supervisor

  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Session

  @registry Raxol.Agent.Registry
  @dynsup Raxol.Agent.DynSup

  # --- public API --------------------------------------------------------------

  @doc """
  Start a session as one supervised subtree under `Raxol.Agent.DynSup`.

  Returns `{:ok, pid}` where `pid` is the subtree supervisor (resolve the
  session process itself with `whereis/1`). A second call with the same
  `session_id` returns `{:error, {:already_started, pid}}`.

  Options (all `Raxol.Agent.Session` options are accepted and forwarded):

    * `:session_id` — the harness session key (default: derived from `:id`
      or the app module, filename-safe + unique suffix)
    * `:id` — the agent id for `Raxol.Agent.Registry` discovery (default:
      `{:harness_session, session_id}`)
    * `:journal` / `:journal_opts` — forwarded to the tree-owned
      `Raxol.Agent.EmitBridge`
  """
  @spec start_session(module(), keyword()) ::
          {:ok, pid()} | {:error, {:already_started, pid()} | term()}
  def start_session(app_module, opts \\ []) when is_atom(app_module) do
    with :ok <- ensure_infrastructure() do
      opts = normalize_opts(app_module, opts)

      DynamicSupervisor.start_child(@dynsup, tree_spec(opts))
    end
  end

  @doc """
  Stop a session's whole subtree (session first, then the sink — the reverse
  of start order — so the bridge's `terminate/2` flushes and closes the
  journal handle last). Also stops bare `Raxol.Agent.Session.start_link`
  sessions that registered under `{:session, session_id}`.

  ## Journal-tail completeness guarantee (graceful stop)

  Before tearing the tree down, `stop_session/1` drains the durable tail so a
  graceful stop never silently truncates the journal. The runtime `Lifecycle`
  does NOT trap exits, so a plain subtree teardown would kill the dispatcher
  (and the events queued in its mailbox) with no drain. Instead we flush in
  dependency order using synchronous FIFO barriers — a `:sys.get_state/2` call
  returns only after every message enqueued before it has been handled:

    1. barrier on the **session** — `send_message` is a cast the session forwards
       (also a cast) to the dispatcher, so this drains queued inbound messages
       out of the session's mailbox into the dispatcher's first;
    2. barrier on the **dispatcher** — it processes its whole mailbox, publishing
       each queued durable event to `EmitBus`, which `send`s it (synchronously)
       into the bridge's mailbox;
    3. barrier on the **bridge** — it processes its whole mailbox, `append`ing
       each durable event to the journal `Writer` (a synchronous call).

  Neither barrier stops a process, so no `:rest_for_one` restart is triggered.
  Only then do we tear the subtree down; the journal `Writer` (which traps exits)
  datasyncs and closes in its own `terminate/2`.

  GUARANTEED: every durable event enqueued to the dispatcher at the moment the
  drain begins is appended to the journal and datasynced before teardown.
  NOT guaranteed: events emitted *concurrently* by a still-running async turn
  after the barriers pass — they race the teardown. For the harness's
  synchronous one-message-one-turn model, once inbound `send_message`s stop the
  tail is captured in full. The drain is bounded (best-effort) and never blocks
  teardown on a slow/dead process.
  """
  @spec stop_session(term()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case lookup({:session_supervisor, session_id}) do
      pid when is_pid(pid) ->
        drain_durable_tail(session_id)
        stop_tree(pid)

      nil ->
        # Standalone sessions drain themselves: `Session.terminate/2` runs
        # `stop_lifecycle_sync` (drains the dispatcher) then stops the bridge
        # (which flushes the journal), so no extra drain is needed here.
        stop_standalone(session_id)
    end
  end

  # Flush dispatcher -> bridge -> journal via FIFO barriers so a graceful stop
  # captures the full durable tail before the tree is torn down. See the
  # `stop_session/1` doc for the completeness guarantee. Best-effort and bounded:
  # any missing/slow/dead process just short-circuits — teardown proceeds either
  # way, and a hard teardown is still safe (the Writer datasyncs on its own exit).
  defp drain_durable_tail(session_id) do
    flush_barrier(lookup({:session, session_id}))
    flush_barrier(dispatcher_for(session_id))
    flush_barrier(lookup({:emit_bridge, session_id}))
    :ok
  end

  defp dispatcher_for(session_id) do
    with pid when is_pid(pid) <- lookup({:lifecycle, session_id}),
         %{dispatcher_pid: dispatcher} <-
           GenServer.call(pid, :get_full_state, drain_timeout()) do
      dispatcher
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # A synchronous system message is a FIFO barrier: it returns only after every
  # message enqueued before it has been handled, draining the mailbox into the
  # process's side effects (dispatcher: publish to EmitBus; bridge: append to
  # journal) WITHOUT stopping it (so no `:rest_for_one` restart fires).
  defp flush_barrier(pid) when is_pid(pid) do
    _ = :sys.get_state(pid, drain_timeout())
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp flush_barrier(_), do: :ok

  defp drain_timeout, do: Raxol.Core.Defaults.shutdown_timeout_ms()

  @doc """
  Resolve `session_id` to the live `Raxol.Agent.Session` pid, or `nil`.
  """
  @spec whereis(term()) :: pid() | nil
  def whereis(session_id), do: lookup({:session, session_id})

  @doc """
  All live sessions as `{session_id, session_pid}` — supervised subtrees and
  standalone `Session.start_link` sessions alike.
  """
  @spec list_sessions() :: [{term(), pid()}]
  def list_sessions do
    Registry.select(@registry, [
      {{{:session, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  rescue
    # Registry not running — no sessions.
    ArgumentError -> []
  end

  # --- supervisor --------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {@registry, {:session_supervisor, session_id}}}
    )
  end

  @impl Supervisor
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    bridge_opts =
      [
        session_id: session_id,
        name: {:via, Registry, {@registry, {:emit_bridge, session_id}}}
      ]
      |> copy_opt(:journal, opts)
      |> copy_opt(:journal_opts, opts)

    # The tree owns the sink AND the lifecycle; the session starts (and stops)
    # neither — it only looks them up and forwards to the runtime's dispatcher.
    session_opts =
      opts
      |> Keyword.put(:start_emit_bridge, false)
      |> Keyword.put(:manage_lifecycle, false)

    children = [
      %{
        id: :emit_bridge,
        start: {__MODULE__, :start_bridge, [session_id, bridge_opts]},
        restart: :permanent,
        shutdown: 5_000
      },
      Session.lifecycle_child_spec(opts),
      %{
        id: :session,
        start: {Session, :start_link, [session_opts]},
        restart: :permanent
      }
    ]

    # Restarts are made deterministic (each via-named child waits for its dead
    # predecessor's Registry key to clear before re-registering — see
    # `start_bridge/2`, `Session.start_supervised_lifecycle/1`,
    # `Session.start_link/1`), so `max_restarts` no longer has to absorb a lost
    # cleanup race. Keep a small budget purely as a genuine crash-loop backstop.
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 5
    )
  end

  @doc false
  # Start the per-session sink, waiting for a dead predecessor's
  # `{:emit_bridge, session_id}` via-name to clear first so a `:rest_for_one`
  # restart is deterministic (YELLOW 3) rather than depending on winning the
  # race against Registry's async cleanup.
  @spec start_bridge(term(), keyword()) :: GenServer.on_start()
  def start_bridge(session_id, bridge_opts) do
    Session.await_free({:emit_bridge, session_id})
    EmitBridge.start_link(bridge_opts)
  end

  # --- helpers -----------------------------------------------------------------

  defp normalize_opts(app_module, opts) do
    session_id =
      Keyword.get(opts, :session_id) ||
        Session.derive_session_id(Keyword.get(opts, :id, app_module))

    opts
    |> Keyword.put(:app_module, app_module)
    |> Keyword.put(:session_id, session_id)
    |> Keyword.put_new(:id, {:harness_session, session_id})
  end

  defp tree_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :supervisor
    }
  end

  defp ensure_infrastructure do
    cond do
      is_nil(Process.whereis(@registry)) -> {:error, :registry_not_running}
      is_nil(Process.whereis(@dynsup)) -> {:error, :dynsup_not_running}
      true -> :ok
    end
  end

  defp lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Prefer terminate_child (synchronous, removes the DynSup child); fall back
  # to a direct stop for a tree that was not started under DynSup.
  defp stop_tree(sup) do
    case Process.whereis(@dynsup) do
      nil ->
        stop_process(sup)

      _ ->
        case DynamicSupervisor.terminate_child(@dynsup, sup) do
          :ok -> :ok
          {:error, :not_found} -> stop_process(sup)
        end
    end
  end

  defp stop_standalone(session_id) do
    case lookup({:session, session_id}) do
      nil -> {:error, :not_found}
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp copy_opt(target, key, source) do
    case Keyword.fetch(source, key) do
      {:ok, value} -> Keyword.put(target, key, value)
      :error -> target
    end
  end
end
