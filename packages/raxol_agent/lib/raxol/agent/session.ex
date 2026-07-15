defmodule Raxol.Agent.Session do
  @moduledoc """
  Manages a single agent's TEA application lifecycle.

  Follows the same pattern as `Raxol.SSH.Session`: wraps a Lifecycle
  instance with `environment: :agent`. Agents register in
  `Raxol.Agent.Registry` for discovery by other agents.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  defstruct [:id, :app_module, :lifecycle_pid, :team_id, :session_id, :emit_bridge]

  @type t :: %__MODULE__{
          id: term(),
          app_module: module(),
          lifecycle_pid: pid() | nil,
          team_id: term() | nil,
          session_id: String.t() | nil,
          emit_bridge: pid() | nil
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Raxol.Agent.Registry, id}})
  end

  @doc "Send a message into the agent's TEA loop."
  @spec send_message(term(), term()) :: :ok | {:error, :not_found}
  def send_message(agent_id, message) do
    case Registry.lookup(Raxol.Agent.Registry, agent_id) do
      [{pid, _}] -> GenServer.cast(pid, {:send_message, message})
      [] -> {:error, :not_found}
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
    emit_bridge = start_emit_bridge(session_id, opts)

    lifecycle_pid = start_or_reattach_lifecycle(app_module, id, session_id)
    Process.monitor(lifecycle_pid)

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
       emit_bridge: emit_bridge
     }}
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
        :ok

      dispatcher_pid ->
        payload = {:agent_message, state.id, message}

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

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.lifecycle_pid && Process.alive?(state.lifecycle_pid) do
      Raxol.Core.Runtime.Lifecycle.stop(state.lifecycle_pid)
    end

    # Gracefully stop the per-session sink so its journal handle is flushed and
    # closed (its terminate/2 does this). Best-effort — never block session
    # shutdown on it.
    stop_emit_bridge(state.emit_bridge)

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
        fn commands -> Raxol.Agent.CommandHook.wrap_commands(commands, hooks, context) end
    end
  end

  defp start_or_reattach_lifecycle(app_module, id, session_id) do
    opts = [
      environment: :agent,
      width: Raxol.Core.Defaults.terminal_width(),
      height: Raxol.Core.Defaults.terminal_height(),
      name: :"agent_lifecycle_#{inspect(id)}",
      command_interceptor: build_command_interceptor(app_module, id),
      # Harness keystone: makes the Dispatcher publish typed events to EmitBus.
      session_id: session_id
    ]

    case Raxol.Core.Runtime.Lifecycle.start_link(app_module, opts) do
      {:ok, lifecycle_pid} ->
        # A fresh lifecycle is linked to us; unlink so its crashes don't cascade.
        Process.unlink(lifecycle_pid)
        lifecycle_pid

      {:error, {:already_started, lifecycle_pid}} ->
        # A prior session was killed before its lifecycle was cleaned up.
        # Reattach to the running runtime instead of failing to restart.
        lifecycle_pid
    end
  end

  # A session_id is also the durable journal's on-disk directory name, so it
  # must be a safe filename. Coerce the (arbitrary term) agent id into the
  # journal's charset and suffix a unique token so restarts never collide.
  defp derive_session_id(id) do
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

  # Start the per-session sink under the agent DynamicSupervisor when available
  # (so it is not crash-coupled to this Session); fall back to a linked start
  # otherwise, so the sink dies with the session rather than leaking. Returns
  # the bridge pid or nil.
  defp start_emit_bridge(session_id, opts) do
    bridge_opts =
      [session_id: session_id]
      |> maybe_put(:journal, Keyword.get(opts, :journal))
      |> maybe_put(:journal_opts, Keyword.get(opts, :journal_opts))

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

  defp start_emit_bridge_standalone(bridge_opts) do
    case Raxol.Agent.EmitBridge.start_link(bridge_opts) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp stop_emit_bridge(nil), do: :ok

  defp stop_emit_bridge(pid) do
    if Process.alive?(pid) do
      case Process.whereis(Raxol.Agent.DynSup) do
        nil -> GenServer.stop(pid, :normal, 1_000)
        _sup -> DynamicSupervisor.terminate_child(Raxol.Agent.DynSup, pid)
      end
    end

    :ok
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
