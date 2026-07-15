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
    2. `Raxol.Agent.Session` — the Lifecycle wrapper (dispatcher). Started
       with `start_emit_bridge: false`: the tree owns the bridge, the session
       must not start a second one.

  Why this order: the journal/sink is the resource the session *depends on*
  (durable events must have somewhere to land), so it starts first and stops
  last. Under `:rest_for_one`:

    * a **bridge crash** restarts the bridge *and then* the session — the
      whole tree recovers in dependency order, and the restarted bridge
      re-registers under `{:emit_bridge, session_id}` (exactly one bridge; the
      journal Writer survives via its own `:global` single-writer discipline
      and is re-joined on the next durable append, so offsets stay monotonic);
    * a **session crash** restarts *only* the session — the sink is never
      orphaned and never duplicated, and the restarted session finds the
      running bridge via the registry.

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
  """
  @spec stop_session(term()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case lookup({:session_supervisor, session_id}) do
      pid when is_pid(pid) -> stop_tree(pid)
      nil -> stop_standalone(session_id)
    end
  end

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

    # The tree owns the bridge; the session must not start (or stop) its own.
    session_opts = Keyword.put(opts, :start_emit_bridge, false)

    children = [
      %{
        id: :emit_bridge,
        start: {EmitBridge, :start_link, [bridge_opts]},
        restart: :permanent
      },
      %{
        id: :session,
        start: {Session, :start_link, [session_opts]},
        restart: :permanent
      }
    ]

    # max_restarts is slightly generous: an immediate restart of the session
    # child can transiently lose the Registry-cleanup race for its via name
    # and need another attempt.
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 5
    )
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
