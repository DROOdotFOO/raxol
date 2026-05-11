defmodule Raxol.Agent.Orchestrator do
  @moduledoc """
  Coordinates multiple AI agents in the cockpit.

  Manages pane layout, routes pilot input to the focused pane,
  handles agent spawning/killing, and implements the takeover/release
  protocol.

  Pilot modes:
  - `:observe` -- watching agents work (default)
  - `:command` -- sending directives to agents
  - `:takeover` -- directly controlling an agent's terminal
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Process, as: AgentProcess
  alias Raxol.Agent.Protocol

  defstruct agents: %{},
            pane_layout: %{},
            focused_pane: nil,
            pilot_mode: :observe,
            event_log: nil,
            pending_recommendation: nil,
            subscribers: MapSet.new()

  @type t :: %__MODULE__{
          agents: %{atom() => pid()},
          pane_layout: %{atom() => map()},
          focused_pane: atom() | nil,
          pilot_mode: :observe | :command | :takeover,
          event_log: CircularBuffer.t() | nil,
          pending_recommendation: map() | nil,
          subscribers: MapSet.t(pid())
        }

  @max_event_log 200
  @default_pane_position %{x: 0, y: 0}
  @default_pane_dimensions %{
    width: Raxol.Core.Defaults.terminal_width(),
    height: Raxol.Core.Defaults.terminal_height()
  }

  # -- Client API --------------------------------------------------------------

  @doc "Start the orchestrator."
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Raxol.Agent.Registry, :orchestrator}}
    )
  end

  @doc "Spawn a new agent and assign it a pane."
  @spec spawn_agent(pid(), atom(), module(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def spawn_agent(orchestrator, agent_id, agent_module, opts \\ []) do
    GenServer.call(orchestrator, {:spawn_agent, agent_id, agent_module, opts})
  end

  @doc "Kill an agent and remove its pane."
  @spec kill_agent(pid(), atom()) :: :ok
  def kill_agent(orchestrator, agent_id) do
    GenServer.call(orchestrator, {:kill_agent, agent_id})
  end

  @doc "Switch pilot focus to a different pane."
  @spec focus_pane(pid(), atom()) :: :ok
  def focus_pane(orchestrator, pane_id) do
    GenServer.call(orchestrator, {:focus_pane, pane_id})
  end

  @doc "Pilot takes over the focused agent's terminal."
  @spec pilot_takeover(pid()) :: :ok | {:error, term()}
  def pilot_takeover(orchestrator) do
    GenServer.call(orchestrator, :pilot_takeover)
  end

  @doc "Pilot releases the taken-over agent's terminal."
  @spec pilot_release(pid()) :: :ok | {:error, term()}
  def pilot_release(orchestrator) do
    GenServer.call(orchestrator, :pilot_release)
  end

  @doc "Route pilot input to the focused pane's agent (during takeover)."
  @spec send_input(pid(), term()) :: :ok | {:error, term()}
  def send_input(orchestrator, input) do
    GenServer.call(orchestrator, {:send_input, input})
  end

  @doc "Send a directive to a specific agent."
  @spec send_directive(pid(), atom(), term()) :: :ok | {:error, term()}
  def send_directive(orchestrator, agent_id, directive) do
    GenServer.call(orchestrator, {:send_directive, agent_id, directive})
  end

  @doc "Broadcast a directive to all agents."
  @spec broadcast_directive(pid(), term()) :: :ok
  def broadcast_directive(orchestrator, directive) do
    GenServer.cast(orchestrator, {:broadcast_directive, directive})
  end

  @doc "Get the current layout and agent status."
  @spec get_layout(pid()) :: map()
  def get_layout(orchestrator) do
    GenServer.call(orchestrator, :get_layout)
  end

  @doc "Get all agent statuses."
  @spec get_statuses(pid()) :: map()
  def get_statuses(orchestrator) do
    GenServer.call(orchestrator, :get_statuses)
  end

  @doc "Accept the pending layout recommendation."
  @spec accept_recommendation(pid()) :: :ok | {:error, :no_pending}
  def accept_recommendation(orchestrator) do
    GenServer.call(orchestrator, :accept_recommendation)
  end

  @doc "Reject the pending layout recommendation."
  @spec reject_recommendation(pid()) :: :ok | {:error, :no_pending}
  def reject_recommendation(orchestrator) do
    GenServer.call(orchestrator, :reject_recommendation)
  end

  @doc "Get the pending recommendation, if any."
  @spec get_pending_recommendation(pid()) :: map() | nil
  def get_pending_recommendation(orchestrator) do
    GenServer.call(orchestrator, :get_pending_recommendation)
  end

  @doc "Subscribe to orchestrator events."
  @spec subscribe(pid()) :: :ok
  def subscribe(orchestrator) do
    GenServer.call(orchestrator, {:subscribe, self()})
  end

  # -- Server ------------------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    {:ok, %__MODULE__{event_log: CircularBuffer.new(@max_event_log)}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:spawn_agent, agent_id, agent_module, opts},
        _from,
        %__MODULE__{} = state
      ) do
    if Map.has_key?(state.agents, agent_id) do
      {:reply, {:error, :already_exists}, state}
    else
      case start_agent_process(agent_id, agent_module, opts) do
        {:ok, pid} ->
          state =
            state
            |> register_agent(agent_id, pid, opts)
            |> auto_focus(agent_id)
            |> log_event({:agent_spawned, agent_id})

          {:reply, {:ok, agent_id}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_manager_call({:kill_agent, agent_id}, _from, %__MODULE__{} = state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        _ = DynamicSupervisor.terminate_child(Raxol.Agent.DynSup, pid)

        state =
          state
          |> remove_agent(agent_id)
          |> log_event({:agent_killed, agent_id})

        {:reply, :ok, state}
    end
  end

  def handle_manager_call({:focus_pane, pane_id}, _from, %__MODULE__{} = state) do
    if Map.has_key?(state.pane_layout, pane_id) do
      {:reply, :ok, %__MODULE__{state | focused_pane: pane_id}}
    else
      {:reply, {:error, :pane_not_found}, state}
    end
  end

  def handle_manager_call(:pilot_takeover, _from, %__MODULE__{} = state) do
    with {:ok, pane_id} <- require_focused_pane(state),
         {:ok, pid} <- require_agent(state, pane_id) do
      _ = AgentProcess.takeover(pid)

      state =
        %__MODULE__{state | pilot_mode: :takeover}
        |> log_event({:pilot_takeover, pane_id})

      {:reply, :ok, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_manager_call(:pilot_release, _from, %__MODULE__{} = state) do
    with {:ok, pane_id} <- require_focused_pane(state),
         {:ok, pid} <- require_agent(state, pane_id) do
      _ = AgentProcess.release(pid)

      state =
        %__MODULE__{state | pilot_mode: :observe}
        |> log_event({:pilot_release, pane_id})

      {:reply, :ok, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_manager_call({:send_input, input}, _from, %__MODULE__{} = state) do
    case {state.pilot_mode, state.focused_pane} do
      {:takeover, pane_id} when not is_nil(pane_id) ->
        case Map.get(state.pane_layout, pane_id) do
          %{terminal_pid: terminal_pid} when is_pid(terminal_pid) ->
            AgentProcess.push_event(
              Map.get(state.agents, pane_id),
              {:pilot_input, input}
            )

            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :no_terminal}, state}
        end

      {:takeover, nil} ->
        {:reply, {:error, :no_focused_pane}, state}

      _ ->
        {:reply, {:error, :not_in_takeover}, state}
    end
  end

  def handle_manager_call(
        {:send_directive, agent_id, directive},
        _from,
        %__MODULE__{} = state
      ) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        AgentProcess.send_directive(pid, directive)
        {:reply, :ok, state}
    end
  end

  def handle_manager_call(:get_layout, _from, %__MODULE__{} = state) do
    layout = %{
      panes: state.pane_layout,
      focused: state.focused_pane,
      pilot_mode: state.pilot_mode,
      agent_count: map_size(state.agents)
    }

    {:reply, layout, state}
  end

  def handle_manager_call(:get_statuses, _from, %__MODULE__{} = state) do
    statuses =
      state.agents
      |> Enum.map(fn {agent_id, pid} ->
        status =
          if Process.alive?(pid) do
            AgentProcess.get_status(pid)
          else
            %{status: :dead}
          end

        {agent_id, status}
      end)
      |> Map.new()

    {:reply, statuses, state}
  end

  def handle_manager_call(:accept_recommendation, _from, %__MODULE__{} = state) do
    resolve_recommendation(state, :accepted)
  end

  def handle_manager_call(:reject_recommendation, _from, %__MODULE__{} = state) do
    resolve_recommendation(state, :rejected)
  end

  def handle_manager_call(:get_pending_recommendation, _from, %__MODULE__{} = state) do
    {:reply, state.pending_recommendation, state}
  end

  def handle_manager_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)

    {:reply, :ok, %__MODULE__{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_manager_call(_msg, _from, %__MODULE__{} = state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:broadcast_directive, directive}, %__MODULE__{} = state) do
    Enum.each(state.agents, fn {_id, pid} ->
      AgentProcess.send_directive(pid, directive)
    end)

    {:noreply, state}
  end

  def handle_manager_cast(_msg, %__MODULE__{} = state), do: {:noreply, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:agent_query, agent_id, %Protocol{} = msg},
        %__MODULE__{} = state
      ) do
    Logger.info("[Orchestrator] Agent #{agent_id} asks pilot: #{inspect(msg.payload)}")

    state = log_event(state, {:agent_query, agent_id, msg.payload})
    {:noreply, state}
  end

  def handle_manager_info({:layout_recommendation, rec}, %__MODULE__{} = state) do
    state =
      %__MODULE__{state | pending_recommendation: rec}
      |> log_event({:recommendation_pending, rec.id})

    notify_subscribers(state.subscribers, {:recommendation_pending, rec})
    {:noreply, state}
  end

  def handle_manager_info({:DOWN, _ref, :process, pid, reason}, %__MODULE__{} = state) do
    case Enum.find(state.agents, fn {_, p} -> p == pid end) do
      {agent_id, _} ->
        Logger.warning("[Orchestrator] Agent #{agent_id} died: #{inspect(reason)}")

        state = %__MODULE__{state | agents: Map.delete(state.agents, agent_id)}
        {:noreply, state}

      nil ->
        {:noreply, %__MODULE__{state | subscribers: MapSet.delete(state.subscribers, pid)}}
    end
  end

  def handle_manager_info(_msg, %__MODULE__{} = state), do: {:noreply, state}

  # -- Private -----------------------------------------------------------------

  defp start_agent_process(agent_id, agent_module, opts) do
    agent_opts =
      Keyword.merge(opts,
        agent_id: agent_id,
        agent_module: agent_module,
        pane_id: agent_id
      )

    DynamicSupervisor.start_child(
      Raxol.Agent.DynSup,
      {AgentProcess, agent_opts}
    )
  end

  defp register_agent(%__MODULE__{} = state, agent_id, pid, opts) do
    pane = %{
      agent_id: agent_id,
      agent_pid: pid,
      position: Keyword.get(opts, :position, @default_pane_position),
      dimensions: Keyword.get(opts, :dimensions, @default_pane_dimensions),
      terminal_pid: Keyword.get(opts, :terminal_pid),
      buffer_pid: Keyword.get(opts, :buffer_pid),
      label: Keyword.get(opts, :label, to_string(agent_id))
    }

    %__MODULE__{
      state
      | agents: Map.put(state.agents, agent_id, pid),
        pane_layout: Map.put(state.pane_layout, agent_id, pane)
    }
  end

  defp auto_focus(%__MODULE__{focused_pane: nil} = state, agent_id) do
    %__MODULE__{state | focused_pane: agent_id}
  end

  defp auto_focus(%__MODULE__{} = state, _agent_id), do: state

  defp remove_agent(%__MODULE__{} = state, agent_id) do
    state = %__MODULE__{
      state
      | agents: Map.delete(state.agents, agent_id),
        pane_layout: Map.delete(state.pane_layout, agent_id)
    }

    if state.focused_pane == agent_id do
      next = state.agents |> Map.keys() |> List.first()
      %__MODULE__{state | focused_pane: next, pilot_mode: :observe}
    else
      state
    end
  end

  defp require_focused_pane(%__MODULE__{focused_pane: nil}),
    do: {:error, :no_focused_pane}

  defp require_focused_pane(%__MODULE__{focused_pane: pane_id}),
    do: {:ok, pane_id}

  defp require_agent(%__MODULE__{} = state, pane_id) do
    case Map.get(state.agents, pane_id) do
      nil -> {:error, :agent_not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_recommendation(
         %__MODULE__{pending_recommendation: nil} = state,
         _decision
       ) do
    {:reply, {:error, :no_pending}, state}
  end

  defp resolve_recommendation(
         %__MODULE__{pending_recommendation: rec} = state,
         decision
       ) do
    event_tag =
      case decision do
        :accepted -> :recommendation_accepted
        :rejected -> :recommendation_rejected
      end

    state =
      %__MODULE__{state | pending_recommendation: nil}
      |> log_event({event_tag, rec.id})

    notify_subscribers(state.subscribers, {event_tag, rec})
    {:reply, :ok, state}
  end

  defp log_event(%__MODULE__{} = state, event) do
    entry = {event, DateTime.utc_now()}

    %__MODULE__{
      state
      | event_log: CircularBuffer.insert(state.event_log, entry)
    }
  end

  defp notify_subscribers(subscribers, event) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:orchestrator_event, event})
    end)
  end
end
