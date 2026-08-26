defmodule Raxol.Agent.Session do
  @moduledoc """
  Manages a single agent's TEA application lifecycle.

  Follows the same pattern as `Raxol.SSH.Session`: wraps a Lifecycle
  instance with `environment: :agent`. Agents register in
  `Raxol.Agent.Registry` for discovery by other agents.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  defstruct [
    :id,
    :app_module,
    :lifecycle_pid,
    :team_id,
    :session_id,
    :emit_bridge,
    bridge_opts: [],
    owns_bridge?: true,
    owns_lifecycle?: true
  ]

  @type t :: %__MODULE__{
          id: term(),
          app_module: module(),
          lifecycle_pid: pid() | nil,
          team_id: term() | nil,
          session_id: String.t() | nil,
          emit_bridge: pid() | nil,
          bridge_opts: keyword(),
          owns_bridge?: boolean(),
          owns_lifecycle?: boolean()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      # The child-spec shutdown budget must STRICTLY EXCEED `stop_lifecycle_sync`'s
      # total wait (`shutdown_timeout_ms() + 1_000`, see ~640). A standalone
      # Session traps exits and drains its owned lifecycle in `terminate/2`; on a
      # parent shutdown (e.g. `Raxol.Agent.Team`'s `:rest_for_one`), the parent
      # must give `terminate/2` long enough to reach its `Process.exit(:kill)`
      # fallback. If this budget were <= the drain budget the parent would
      # brutal-kill the Session mid-drain, BEFORE the kill-fallback runs —
      # orphaning the lifecycle (the exact failure the sync drain exists to
      # prevent). +2_000 keeps a 1s margin over the +1_000 drain budget.
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms() + 2_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    # Deterministic (re)start: a `:rest_for_one` restart can race Registry's
    # async cleanup of the dead predecessor's `{:via, ...}` name. Wait for the
    # stale key to clear before we register, so the start can't lose the race
    # and fail with `{:already_started, dead_pid}` (YELLOW 3). Only the
    # single restarter competes for this unique key, and cleanup only REMOVES
    # it, so once it reads empty our registration cannot collide.
    await_free(id)

    GenServer.start_link(__MODULE__, opts,
      # The :session value marks this entry as an agent session, so
      # broadcasts can target sessions without hitting the auxiliary
      # entries ({:lifecycle, id}, {:emit_bridge, id}) in the same
      # Registry.
      name: {:via, Registry, {Raxol.Agent.Registry, id, :session}}
    )
  end

  @doc """
  Send a message into the agent's TEA loop.

  Pass `from: sender_agent_id` to attribute the message; it arrives in
  `update/2` as `{:agent_message, sender_agent_id, message}`. Without it
  the `from` position is `nil` (unknown sender), never a guess.
  """
  @spec send_message(term(), term(), keyword()) :: :ok | {:error, :not_found}
  def send_message(agent_id, message, opts \\ []) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] ->
        case Keyword.get(opts, :from) do
          nil -> GenServer.cast(pid, {:send_message, message})
          from -> GenServer.cast(pid, {:send_message, message, %{from: from}})
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Read the agent's current model."
  @spec get_model(term()) :: {:ok, term()} | {:error, :not_found}
  def get_model(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :get_model)
      [] -> {:error, :not_found}
    end
  end

  @doc "Read the agent's latest view tree."
  @spec get_view_tree(term()) :: {:ok, term()} | {:error, :not_found}
  def get_view_tree(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :get_view_tree)
      [] -> {:error, :not_found}
    end
  end

  @doc "Read the agent's view as a semantic tree (layout keys stripped)."
  @spec get_semantic_view(term()) :: {:ok, term()} | {:error, :not_found}
  def get_semantic_view(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :get_semantic_view)
      [] -> {:error, :not_found}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.get(opts, :team_id)

    # Harness keystone: a stable session_id makes the runtime Dispatcher emit
    # typed events, and scopes the durable journal + event stream. Start the
    # per-session sink (EmitBridge) BEFORE the lifecycle so it is subscribed to
    # EmitBus in time for the first turn. The sink emits into the singleton
    # SessionStreamer (supervised by Raxol.Agent.Supervisor); when none is
    # running its emits are harmless no-ops.
    session_id = Keyword.get(opts, :session_id) || derive_session_id(id)

    bridge_opts =
      []
      |> maybe_put(:journal, Keyword.get(opts, :journal))
      |> maybe_put(:journal_opts, Keyword.get(opts, :journal_opts))

    # Two ownership modes, one flag pair:
    #
    #   * standalone `Session.start_link` (default): the session OWNS both its
    #     bridge and its lifecycle — starts them (unlinked so their crashes can
    #     never take the session down), monitors them, and stops them in
    #     `terminate/2`. To make `terminate/2` actually run on a graceful
    #     `GenServer.stop`/parent-shutdown, this mode traps exits (BaseManager
    #     does NOT — unlike BaseServer). Without trapping, the cleanup below
    #     would be dead code and the lifecycle would leak.
    #   * under `Raxol.Agent.Session.Supervisor`
    #     (`start_emit_bridge: false`, `manage_lifecycle: false`): the TREE owns
    #     both — the bridge and the lifecycle are sibling supervised children
    #     started BEFORE this session under `:rest_for_one`. The session only
    #     looks them up; supervision owns start/restart/stop. This is what makes
    #     the lifecycle leak + reattach-to-dead structurally impossible: a
    #     `stop_session` tears the whole subtree down (fresh lifecycle on any
    #     restart, never an orphan), so no `terminate/2` cleanup is needed here.
    owns_bridge? = Keyword.get(opts, :start_emit_bridge, true)
    owns_lifecycle? = Keyword.get(opts, :manage_lifecycle, true)

    if owns_bridge? or owns_lifecycle?, do: Process.flag(:trap_exit, true)

    emit_bridge =
      if owns_bridge? do
        bridge = start_emit_bridge(session_id, bridge_opts)
        if bridge, do: Process.monitor(bridge)
        bridge
      else
        lookup_emit_bridge(session_id)
      end

    # session_id → pid resolution seam (SS): registered in both ownership
    # modes so `Raxol.Agent.Session.Supervisor.whereis/1` resolves supervised
    # and standalone sessions alike. Registry cleans the key up on death.
    register_session(session_id, id, app_module)

    lifecycle_pid =
      if owns_lifecycle? do
        pid = start_or_reattach_lifecycle(app_module, id, session_id)
        Process.monitor(pid)
        pid
      else
        # Tree-owned lifecycle: it started before us under `:rest_for_one` and
        # registered its `{:lifecycle, session_id}` via-name synchronously, so
        # the key is present by the time we init. No monitor: if it crashes,
        # `:rest_for_one` restarts us too, so we always re-resolve a fresh pid.
        lookup_lifecycle(session_id)
      end

    Logger.info(
      "[Agent.Session] Started agent #{inspect(id)} (#{inspect(app_module)}) session=#{session_id}"
    )

    {:ok,
     %__MODULE__{
       id: id,
       app_module: app_module,
       lifecycle_pid: lifecycle_pid,
       team_id: team_id,
       session_id: session_id,
       emit_bridge: emit_bridge,
       bridge_opts: bridge_opts,
       owns_bridge?: owns_bridge?,
       owns_lifecycle?: owns_lifecycle?
     }}
  end

  # Team broadcasts are filtered here, not at the broadcaster: only a
  # session started with a matching :team_id forwards the message. BOTH
  # cast shapes must hit the filter -- the metadata-carrying 3-tuple
  # (Comm.send with :from, the SendAgent directive) would otherwise
  # smuggle a foreign team's broadcast past it.
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(
        {:send_message, {:team_broadcast, team_id, _} = message},
        state
      ) do
    if state.team_id == team_id do
      forward_to_dispatcher(state, message, %{})
    else
      {:noreply, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(
        {:send_message, {:team_broadcast, team_id, _} = message, metadata},
        state
      )
      when is_map(metadata) do
    if state.team_id == team_id do
      forward_to_dispatcher(state, message, metadata)
    else
      {:noreply, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:send_message, message, metadata}, state)
      when is_map(metadata) do
    forward_to_dispatcher(state, message, metadata)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:send_message, message}, state) do
    forward_to_dispatcher(state, message, %{})
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(_msg, state), do: {:noreply, state}

  defp forward_to_dispatcher(state, message, metadata) do
    case get_dispatcher(state.lifecycle_pid) do
      nil ->
        # The sender already got :ok from the cast; leave a trace so a
        # dropped message during lifecycle startup/restart is diagnosable.
        Logger.debug(
          "[Agent.Session] #{inspect(state.id)} dropped message (no dispatcher): " <>
            inspect(message, limit: 5)
        )

        :ok

      dispatcher_pid ->
        # `from` is the SENDER's id when the sender attributed itself; nil
        # otherwise. It must never default to state.id — that is the
        # receiver, and stamping it here would fabricate a sender.
        {from, metadata} = Map.pop(metadata, :from)
        payload = {:agent_message, from, message}

        cast =
          if map_size(metadata) == 0,
            do: {:dispatch, payload},
            else: {:dispatch, payload, metadata}

        GenServer.cast(dispatcher_pid, cast)
    end

    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_model, _from, state) do
    result =
      case get_dispatcher(state.lifecycle_pid) do
        nil -> {:error, :no_dispatcher}
        pid -> GenServer.call(pid, :get_model)
      end

    {:reply, result, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_view_tree, _from, state) do
    result =
      case get_dispatcher(state.lifecycle_pid) do
        nil -> {:error, :no_dispatcher}
        pid -> GenServer.call(pid, :get_view_tree)
      end

    {:reply, result, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_semantic_view, _from, state) do
    result =
      case get_dispatcher(state.lifecycle_pid) do
        nil ->
          {:error, :no_dispatcher}

        pid ->
          case GenServer.call(pid, :get_view_tree) do
            {:ok, tree} ->
              {:ok, Raxol.Agent.SemanticTree.from_view_tree(tree)}

            error ->
              error
          end
      end

    {:reply, result, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_session_id, _from, state) do
    {:reply, {:ok, state.session_id}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(_msg, _from, state),
    do: {:reply, {:error, :unknown_call}, state}

  # The session's emit bridge went down. Graceful stops (:normal/:shutdown)
  # need no reaction — the session itself is usually terminating. On a crash,
  # restart the bridge (same session_id, so it re-registers and re-subscribes)
  # or degrade to running without a sink if the restart fails.
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:DOWN, _ref, :process, pid, reason},
        %__MODULE__{emit_bridge: pid} = state
      ) do
    if reason in [:normal, :shutdown] do
      {:noreply, %{state | emit_bridge: nil}}
    else
      Logger.warning(
        "[Agent.Session] EmitBridge for session #{state.session_id} crashed: " <>
          "#{inspect(reason)}; restarting"
      )

      bridge = start_emit_bridge(state.session_id, state.bridge_opts)
      if bridge, do: Process.monitor(bridge)
      {:noreply, %{state | emit_bridge: bridge}}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, reason}, state) do
    if pid == state.lifecycle_pid do
      Logger.warning(
        "[Agent.Session] Lifecycle for #{inspect(state.id)} crashed: #{inspect(reason)}"
      )

      {:noreply, %{state | lifecycle_pid: nil}}
    else
      {:noreply, state}
    end
  end

  # A LINKED process exited abnormally. Standalone mode traps exits, so a link
  # exit lands here as `{:EXIT, pid, reason}`. gen_server intercepts the PARENT's
  # exit before it reaches this callback (it drives `terminate/2`), so this only
  # fires for a NON-parent link. Nothing links to the Session today (the lifecycle
  # and bridge are unlinked + monitored), but if a future linked helper dies
  # abnormally, log it rather than let the catch-all below swallow it silently.
  def handle_manager_info({:EXIT, pid, reason}, state)
      when reason not in [:normal, :shutdown] do
    Logger.warning(
      "[Agent.Session] linked process #{inspect(pid)} for #{inspect(state.id)} " <>
        "exited abnormally: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Standalone mode only. Under `Session.Supervisor` the tree owns both the
    # lifecycle and the bridge as supervised siblings, so `owns_lifecycle?` and
    # `owns_bridge?` are false here and this is a no-op — supervision tears the
    # subtree down in dependency order, and no cleanup depends on this callback
    # (which BaseManager only reaches because standalone init sets `trap_exit`).
    #
    # Stop the lifecycle SYNCHRONOUSLY (block until it is truly dead) so its
    # `{:lifecycle, session_id}` via-name is free and no orphaned runtime leaks.
    if state.owns_lifecycle?, do: stop_lifecycle_sync(state.lifecycle_pid)

    # Gracefully stop the per-session sink so its journal handle is flushed and
    # closed (its terminate/2 does this). Best-effort — never block session
    # shutdown on it.
    if state.owns_bridge?, do: stop_emit_bridge(state.emit_bridge)

    :ok
  end

  @doc "Read the harness session_id for a running agent (nil if not found)."
  @spec session_id(term()) :: {:ok, String.t() | nil} | {:error, :not_found}
  def session_id(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :get_session_id)
      [] -> {:error, :not_found}
    end
  end

  # Wire the agent's permission/sandbox/audit hook chain into the runtime so it
  # runs before any Shell/Async/SendAgent directive executes. nil when the agent
  # declares no hooks, so the runtime skips interception entirely.
  defp build_command_interceptor(app_module, id) do
    case Raxol.Agent.effective_hooks(app_module) do
      [] ->
        nil

      hooks ->
        context = %{agent_id: id, agent_module: app_module}

        fn commands ->
          Raxol.Agent.CommandHook.wrap_commands(commands, hooks, context)
        end
    end
  end

  # The lifecycle's registered name. A `{:via, Registry, ...}` name keyed by the
  # (unique-suffixed) session_id — NOT a `:"agent_lifecycle_#{id}"` atom. Bare
  # atoms are never garbage-collected, so minting one per session marches a
  # long-running node toward the ~1M atom limit; a Registry key has no such cost
  # and is auto-removed when the lifecycle dies.
  defp lifecycle_name(session_id),
    do: {:via, Registry, {Raxol.Agent.Registry, {:lifecycle, session_id}}}

  defp lifecycle_opts(app_module, id, session_id) do
    [
      environment: :agent,
      width: Raxol.Core.Defaults.terminal_width(),
      height: Raxol.Core.Defaults.terminal_height(),
      name: lifecycle_name(session_id),
      command_interceptor: build_command_interceptor(app_module, id),
      # Harness keystone: makes the Dispatcher publish typed events to EmitBus.
      session_id: session_id
    ]
  end

  # Standalone ownership: the session starts the lifecycle itself, unlinked so a
  # lifecycle crash can't cascade into the session (the session monitors it
  # instead). `terminate/2` stops it synchronously, so a graceful stop leaves no
  # orphan. The `{:already_started, _}` branch only fires if a prior standalone
  # incarnation leaked a lifecycle under the same session_id (e.g. a brutal
  # kill, which skips terminate); reattach rather than fail to start.
  defp start_or_reattach_lifecycle(app_module, id, session_id) do
    case Raxol.Core.Runtime.Lifecycle.start_link(
           app_module,
           lifecycle_opts(app_module, id, session_id)
         ) do
      {:ok, lifecycle_pid} ->
        Process.unlink(lifecycle_pid)
        lifecycle_pid

      {:error, {:already_started, lifecycle_pid}} ->
        lifecycle_pid
    end
  end

  # Resolve the tree-owned lifecycle for `session_id` (supervised mode). It
  # starts before this session under `:rest_for_one` and registers its via-name
  # synchronously, so the key is present when we look it up.
  defp lookup_lifecycle(session_id) do
    case Registry.lookup(Raxol.Agent.Registry, {:lifecycle, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  # Supervised child spec for the per-session lifecycle, placed BETWEEN the sink
  # and the session in `Raxol.Agent.Session.Supervisor`'s `:rest_for_one` tree.
  # The tree owns the lifecycle: a `stop_session` (or any restart) tears it down
  # with the subtree — it can neither leak nor be reattached-to while dead.
  #
  # NOTE on `shutdown`: `Raxol.Core.Runtime.Lifecycle` does NOT trap exits, so on
  # a supervised teardown it dies immediately on the `:shutdown` signal WITHOUT
  # running its `handle_cast(:shutdown)` dispatcher-drain or `terminate/2` — this
  # budget only bounds how long the supervisor waits before brutal-kill (it
  # rarely engages). The durable-tail drain is therefore NOT done here; it is
  # done up-front by `Raxol.Agent.Session.Supervisor.stop_session/1`, which flushes
  # the dispatcher -> bridge -> journal Writer via FIFO barriers BEFORE tearing
  # the tree down. The journal Writer traps exits and datasyncs in its own
  # `terminate/2`, so once flushed the tail survives this hard teardown.
  @spec lifecycle_child_spec(keyword()) :: Supervisor.child_spec()
  def lifecycle_child_spec(opts) do
    %{
      id: :lifecycle,
      start: {__MODULE__, :start_supervised_lifecycle, [opts]},
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms()
    }
  end

  @doc false
  # Start the lifecycle as a linked, supervised child (NOT unlinked — the tree
  # supervises it). Waits for the dead predecessor's via-name to clear first so
  # a `:rest_for_one` restart is deterministic (YELLOW 3).
  @spec start_supervised_lifecycle(keyword()) :: GenServer.on_start()
  def start_supervised_lifecycle(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    id = Keyword.fetch!(opts, :id)
    session_id = Keyword.fetch!(opts, :session_id)

    await_free({:lifecycle, session_id})

    Raxol.Core.Runtime.Lifecycle.start_link(
      app_module,
      lifecycle_opts(app_module, id, session_id)
    )
  end

  @doc false
  # Block (bounded) until a Registry key is unregistered. Used before a
  # same-name (re)start so it never loses the race against Registry's async
  # cleanup of a dead predecessor. Only the single restarter competes for these
  # unique per-session keys, and cleanup only removes entries, so once this
  # reads empty a fresh registration cannot collide. Bounded so a genuinely
  # live holder (pathological) just falls through to a normal already_started.
  @spec await_free(term(), non_neg_integer()) :: :ok
  def await_free(key, attempts \\ 200) do
    case safe_lookup(key) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(5)
        await_free(key, attempts - 1)

      _ ->
        :ok
    end
  end

  defp safe_lookup(key) do
    Registry.lookup(Raxol.Agent.Registry, key)
  rescue
    ArgumentError -> []
  end

  # A session_id is also the durable journal's on-disk directory name, so it
  # must be a safe filename. Coerce the (arbitrary term) agent id into the
  # journal's charset and suffix a unique token so restarts never collide.
  #
  # Public (not `defp`) so `Raxol.Agent.Session.Supervisor.start_session/2` can
  # mint the same shape of id up-front when the caller omits `:session_id`.
  @doc false
  @spec derive_session_id(term()) :: String.t()
  def derive_session_id(id) do
    base =
      id
      |> to_id_string()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.trim("-")

    base = if base == "", do: "agent", else: base
    "#{base}-#{System.unique_integer([:positive])}"
  end

  defp to_id_string(id) when is_binary(id), do: id
  defp to_id_string(id) when is_atom(id), do: Atom.to_string(id)
  defp to_id_string(id), do: inspect(id)

  # The `session_id → pid` resolution seam (SS). The session is already
  # registered by its agent `id` (its `{:via, ...}` name); this ADDS a second
  # key, `{:session, session_id}`, so `Raxol.Agent.Session.Supervisor.whereis/1`
  # and `list_sessions/0` resolve every session — supervised or standalone —
  # by its harness session_id. `:unique` Registry allows one process under many
  # keys; each key stays unique. The Registry auto-removes the key on death.
  #
  # Best-effort: an unexpectedly duplicate session_id (two standalone sessions
  # with distinct agent ids but the same session_id) just skips the secondary
  # registration rather than crashing the session — the primary `id` identity
  # is untouched. Registry is always up here (the `{:via, ...}` name requires
  # it), but guard defensively.
  defp register_session(session_id, id, app_module) do
    if Process.whereis(Raxol.Agent.Registry) do
      do_register_session(
        {:session, session_id},
        %{id: id, app_module: app_module}
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Don't silently skip on `:already_registered`. A `{:session, session_id}` key
  # can briefly outlive its dead owner (Registry cleanup lag on a fast
  # `:rest_for_one` restart); skipping then would leave a LIVE session
  # unregistered once the stale key is swept — `whereis/1`, `list_sessions/0`
  # and standalone `stop_session/1` would all lose it (YELLOW 2). Instead retry
  # (bounded) until the stale predecessor's key clears and ours lands. A key
  # already held by self() is fine. A genuinely-live foreign holder
  # (pathological duplicate session_id) exhausts the budget and is skipped — the
  # primary `id` identity is untouched.
  defp do_register_session(key, meta, attempts \\ 200) do
    case Registry.register(Raxol.Agent.Registry, key, meta) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, _pid}} when attempts > 0 ->
        Process.sleep(5)
        do_register_session(key, meta, attempts - 1)

      {:error, {:already_registered, holder}} ->
        # Retry budget exhausted: a genuinely-live foreign holder still owns the
        # key. Proceed (the primary `id` identity is intact) but LOUDLY — an
        # unregistered live session is invisible to `whereis/1`, `list_sessions/0`
        # and `stop_session/1` by session_id, and a silent `:ok` would hide that.
        Logger.warning(
          "[Agent.Session] session_id seam registration for #{inspect(key)} timed " <>
            "out (held by #{inspect(holder)}); proceeding UNREGISTERED — this " <>
            "session won't resolve by session_id via whereis/list_sessions/stop_session"
        )

        :telemetry.execute(
          [:raxol, :agent, :session, :register_timeout],
          %{count: 1},
          Map.put(meta, :key, key)
        )

        :ok
    end
  end

  # Resolve the tree-owned sink for `session_id` (supervised mode). The bridge
  # child of `Session.Supervisor` starts BEFORE this session under
  # `:rest_for_one` and registers its `{:via, ...}` name synchronously, so by
  # the time the session inits the key is already present.
  defp lookup_emit_bridge(session_id) do
    case Registry.lookup(Raxol.Agent.Registry, {:emit_bridge, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Start the per-session sink under the agent DynamicSupervisor when available
  # (so it is not crash-coupled to this Session); fall back to an unlinked
  # standalone start otherwise. Returns the bridge pid or nil.
  #
  # The bridge is registered by session_id in Raxol.Agent.Registry (when
  # running) under `{:emit_bridge, session_id}`. That registration is the
  # orphan guard: if this session crashed and its bridge survived (subscribed,
  # journal open), a restarted session with the same session_id gets
  # `{:already_started, pid}` here and ADOPTS the orphan instead of starting a
  # second bridge — one bridge per session, no duplicate emits.
  defp start_emit_bridge(session_id, extra_opts) do
    bridge_opts =
      [session_id: session_id] ++ extra_opts ++ bridge_name_opts(session_id)

    case Process.whereis(Raxol.Agent.DynSup) do
      nil ->
        start_emit_bridge_standalone(bridge_opts)

      _sup ->
        case DynamicSupervisor.start_child(
               Raxol.Agent.DynSup,
               {Raxol.Agent.EmitBridge, bridge_opts}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, _} -> start_emit_bridge_standalone(bridge_opts)
        end
    end
  end

  defp bridge_name_opts(session_id) do
    if Process.whereis(Raxol.Agent.Registry) do
      [
        name: {:via, Registry, {Raxol.Agent.Registry, {:emit_bridge, session_id}}}
      ]
    else
      []
    end
  end

  # Standalone fallback (no Raxol.Agent.DynSup). Ownership direction: the
  # SESSION owns the bridge, never the reverse — a bridge crash must not take
  # the session down. A raw start_link would link bidirectionally, so we
  # immediately unlink and rely on the Process.monitor set by the caller
  # (init_manager / the :DOWN handler): bridge death arrives as :DOWN and is
  # answered with log + restart-or-degrade, and a crashed session's surviving
  # bridge is found-and-adopted via its registry name by the successor.
  defp start_emit_bridge_standalone(bridge_opts) do
    case Raxol.Agent.EmitBridge.start_link(bridge_opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, {:already_started, pid}} ->
        pid

      _ ->
        nil
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # Stop the lifecycle and block until it is truly gone, so its via-name is free
  # for a same-session_id restart. `Lifecycle.stop/1` casts `:shutdown`, so we
  # monitor + await the `:DOWN` ourselves. The wait budget matches the
  # lifecycle's own shutdown budget (`Defaults.shutdown_timeout_ms/0`) plus a
  # margin — a shorter timeout could fire spuriously under load and return while
  # the lifecycle is still sinking. If it DOES time out we hard-kill it before
  # returning: returning with a still-alive lifecycle would let a restart
  # reattach to a dying runtime whose dispatcher then vanishes, silently
  # dropping every `send_message`.
  defp stop_lifecycle_sync(nil), do: :ok

  defp stop_lifecycle_sync(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Raxol.Core.Runtime.Lifecycle.stop(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        Raxol.Core.Defaults.shutdown_timeout_ms() + 1_000 ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
          :ok
      end
    end

    :ok
  end

  defp stop_emit_bridge(nil), do: :ok

  defp stop_emit_bridge(pid) do
    if Process.alive?(pid) do
      # FIFO barrier: drain the bridge's mailbox so durable events the lifecycle
      # drain (`stop_lifecycle_sync`, run just before this) published are appended
      # to the journal BEFORE we stop the bridge. This matters on the DynSup path:
      # a plain `GenServer.stop` would trip the bridge's permanent-child restart,
      # so we must `terminate_child` — which brutal-kills without a mailbox drain.
      # The journal Writer (linked, exit-trapping) datasyncs in its own
      # `terminate/2`, so once appended the tail survives the kill.
      drain_mailbox(pid)

      case Process.whereis(Raxol.Agent.DynSup) do
        nil ->
          GenServer.stop(pid, :normal, 1_000)

        _sup ->
          # An adopted bridge may have been started standalone by a prior
          # session incarnation; stop it directly if DynSup doesn't own it.
          case DynamicSupervisor.terminate_child(Raxol.Agent.DynSup, pid) do
            :ok -> :ok
            {:error, :not_found} -> GenServer.stop(pid, :normal, 1_000)
          end
      end
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # A synchronous system message is a FIFO barrier: it returns only after every
  # message enqueued before it has been handled. Best-effort/bounded — a slow or
  # dead process just short-circuits and teardown proceeds.
  defp drain_mailbox(pid) do
    _ = :sys.get_state(pid, Raxol.Core.Defaults.shutdown_timeout_ms())
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp get_dispatcher(lifecycle_pid) when is_pid(lifecycle_pid) do
    if Process.alive?(lifecycle_pid) do
      %{dispatcher_pid: pid} = GenServer.call(lifecycle_pid, :get_full_state)
      pid
    else
      nil
    end
  catch
    :exit, _ -> nil
  end

  defp get_dispatcher(_), do: nil
end
