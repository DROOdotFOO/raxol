defmodule Raxol.Agent.Process do
  @moduledoc """
  GenServer running the observe-think-act loop for an AI agent.

  Each Agent.Process owns a terminal buffer and runs a configurable
  tick timer. On each tick:

  1. `observe/3` -- reads buffer + recent events
  2. `think/2` -- agent decides what to do
  3. `act/3` -- agent writes to terminal or sends messages

  On crash, the DynamicSupervisor restarts the process. The new instance
  calls `ContextStore.load/1` then `restore_context/1` to resume.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.ContextCompactor
  alias Raxol.Agent.ContextStore
  alias Raxol.Agent.Protocol

  @type status ::
          :initializing | :thinking | :acting | :waiting | :paused | :taken_over

  defstruct [
    :agent_id,
    :agent_module,
    :agent_state,
    :backend,
    :backend_config,
    :tick_ms,
    :tick_ref,
    :pane_id,
    :strategy,
    status: :initializing,
    event_buffer: []
  ]

  @type t :: %__MODULE__{
          agent_id: atom(),
          agent_module: module(),
          agent_state: map(),
          backend: module(),
          backend_config: keyword(),
          tick_ms: pos_integer(),
          tick_ref: reference() | nil,
          pane_id: term(),
          strategy: module() | nil,
          status: status(),
          event_buffer: [term()]
        }

  @default_tick_ms 1_000
  @max_event_buffer 100

  # -- Client API --------------------------------------------------------------

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    %{
      id: {__MODULE__, agent_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @doc "Start an agent process."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Raxol.Agent.Registry, {:process, agent_id}}}
    )
  end

  @doc "Send a directive to the agent."
  @spec send_directive(pid() | atom(), term()) :: :ok
  def send_directive(agent, directive) when is_pid(agent) do
    GenServer.cast(agent, {:directive, directive})
  end

  def send_directive(agent_id, directive) when is_atom(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> send_directive(pid, directive)
      error -> error
    end
  end

  @doc "Pilot takes over the agent's terminal."
  @spec takeover(pid() | atom()) :: :ok | {:error, term()}
  def takeover(agent) when is_pid(agent) do
    GenServer.call(agent, :takeover)
  end

  def takeover(agent_id) when is_atom(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> takeover(pid)
      error -> error
    end
  end

  @doc "Pilot releases the agent's terminal back to the agent."
  @spec release(pid() | atom()) :: :ok | {:error, term()}
  def release(agent) when is_pid(agent) do
    GenServer.call(agent, :release)
  end

  def release(agent_id) when is_atom(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> release(pid)
      error -> error
    end
  end

  @doc "Get the agent's current status."
  @spec get_status(pid() | atom()) :: map()
  def get_status(agent) when is_pid(agent) do
    GenServer.call(agent, :get_status)
  end

  def get_status(agent_id) when is_atom(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> get_status(pid)
      error -> error
    end
  end

  @doc "Push an event into the agent's event buffer."
  @spec push_event(pid() | atom(), term()) :: :ok
  def push_event(agent, event) when is_pid(agent) do
    GenServer.cast(agent, {:push_event, event})
  end

  def push_event(agent_id, event) when is_atom(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> push_event(pid, event)
      error -> error
    end
  end

  # -- Server ------------------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_module = Keyword.fetch!(opts, :agent_module)
    backend = Keyword.get(opts, :backend, Raxol.Agent.Backend.Mock)
    backend_config = Keyword.get(opts, :backend_config, [])
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    pane_id = Keyword.get(opts, :pane_id)
    strategy = Keyword.get(opts, :strategy)

    unless has_process_behaviour?(agent_module) do
      Logger.debug(
        "[Agent.Process] #{inspect(agent_module)} does not implement " <>
          "Raxol.Agent.ProcessBehaviour -- consider adding `use Raxol.Agent.UseProcess`"
      )
    end

    ContextStore.init()

    # Try to restore context from a previous run
    initial_state =
      case ContextStore.load(agent_id) do
        {:ok, context} ->
          Logger.info("[Agent.Process] Restoring context for #{agent_id}")

          case agent_module.restore_context(context) do
            {:ok, agent_state} -> agent_state
            _ -> init_agent(agent_module, opts)
          end

        {:error, :not_found} ->
          init_agent(agent_module, opts)
      end

    state = %__MODULE__{
      agent_id: agent_id,
      agent_module: agent_module,
      agent_state: initial_state,
      backend: backend,
      backend_config: backend_config,
      tick_ms: tick_ms,
      pane_id: pane_id,
      strategy: strategy,
      status: :waiting
    }

    tick_ref = schedule_tick(tick_ms)

    Logger.info(
      "[Agent.Process] Started #{agent_id} (#{inspect(agent_module)}, tick=#{tick_ms}ms)"
    )

    {:ok, %{state | tick_ref: tick_ref}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:tick, %{status: status} = state)
      when status in [:paused, :taken_over] do
    # Don't run the loop when paused or taken over, but keep the timer
    {:noreply, %{state | tick_ref: schedule_tick(state.tick_ms)}}
  end

  def handle_manager_info(:tick, state) do
    state = run_cycle(state)
    {:noreply, %{state | tick_ref: schedule_tick(state.tick_ms)}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:directive, directive}, state) do
    state = handle_directive(directive, state)
    {:noreply, state}
  end

  def handle_manager_cast({:push_event, event}, state) do
    buffer = [event | state.event_buffer] |> Enum.take(@max_event_buffer)
    {:noreply, %{state | event_buffer: buffer}}
  end

  def handle_manager_cast(_msg, state), do: {:noreply, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:takeover, _from, state) do
    state = %{state | status: :taken_over}

    agent_state =
      if function_exported?(state.agent_module, :on_takeover, 1) do
        case state.agent_module.on_takeover(state.agent_state) do
          {:ok, new_state} -> new_state
          _ -> state.agent_state
        end
      else
        state.agent_state
      end

    save_context(%{state | agent_state: agent_state})
    {:reply, :ok, %{state | agent_state: agent_state}}
  end

  def handle_manager_call(:release, _from, state) do
    agent_state =
      if function_exported?(state.agent_module, :on_resume, 1) do
        case state.agent_module.on_resume(state.agent_state) do
          {:ok, new_state} -> new_state
          _ -> state.agent_state
        end
      else
        state.agent_state
      end

    state = %{state | status: :waiting, agent_state: agent_state}
    save_context(state)
    {:reply, :ok, state}
  end

  def handle_manager_call(:get_status, _from, state) do
    status = %{
      agent_id: state.agent_id,
      module: state.agent_module,
      status: state.status,
      pane_id: state.pane_id,
      tick_ms: state.tick_ms,
      event_buffer_size: length(state.event_buffer)
    }

    {:reply, status, state}
  end

  def handle_manager_call(_msg, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    save_context(state)
    :ok
  end

  # -- Private: observe/think/act loop -----------------------------------------

  defp run_cycle(state) do
    state = %{state | status: :thinking}

    # 1. Observe
    {observation, agent_state} =
      case state.agent_module.observe(state.event_buffer, state.agent_state) do
        {:ok, obs, new_state} -> {obs, new_state}
        _ -> {%{}, state.agent_state}
      end

    state = %{state | agent_state: agent_state, event_buffer: []}

    # 2. Think
    case state.agent_module.think(observation, state.agent_state) do
      {:act, action, agent_state} ->
        state = %{state | agent_state: agent_state, status: :acting}
        execute_action(action, state)

      {:wait, agent_state} ->
        %{state | agent_state: agent_state, status: :waiting}

      {:ask_pilot, question, agent_state} ->
        msg = Protocol.new(state.agent_id, :pilot, :query, question)
        notify_orchestrator({:agent_query, state.agent_id, msg})
        %{state | agent_state: agent_state, status: :waiting}

      _ ->
        %{state | status: :waiting}
    end
  rescue
    e in [
      RuntimeError,
      ArgumentError,
      FunctionClauseError,
      MatchError,
      KeyError
    ] ->
      Logger.warning("[Agent.Process] Cycle error for #{state.agent_id}: #{Exception.message(e)}")

      save_context(state)
      %{state | status: :waiting}
  end

  defp execute_action(action, state) do
    case maybe_use_strategy(action, state) do
      {:strategy, result} ->
        handle_strategy_result(result, state)

      :legacy ->
        case state.agent_module.act(action, state.agent_state) do
          {:ok, agent_state} ->
            agent_state = maybe_compact_history(agent_state, state.agent_module)
            state = %{state | agent_state: agent_state, status: :waiting}
            save_context(state)
            state

          {:error, _reason, agent_state} ->
            %{state | agent_state: agent_state, status: :waiting}
        end
    end
  end

  defp maybe_use_strategy({action_mod, _params} = action, state)
       when is_atom(action_mod) and not is_nil(state.strategy) do
    if function_exported?(action_mod, :__action_meta__, 0) do
      context = %{
        backend: state.backend,
        backend_opts: state.backend_config,
        actions: get_available_actions(state)
      }

      {:strategy, state.strategy.execute(action, state.agent_state, context)}
    else
      :legacy
    end
  end

  defp maybe_use_strategy(_action, _state), do: :legacy

  defp handle_strategy_result({:ok, agent_state}, state),
    do: handle_strategy_result({:ok, agent_state, []}, state)

  defp handle_strategy_result({:ok, agent_state, _commands}, state) do
    agent_state = maybe_compact_history(agent_state, state.agent_module)
    state = %{state | agent_state: agent_state, status: :waiting}
    save_context(state)
    state
  end

  defp handle_strategy_result({:error, _reason}, state) do
    %{state | status: :waiting}
  end

  defp get_available_actions(state) do
    if function_exported?(state.agent_module, :available_actions, 0) do
      state.agent_module.available_actions()
    else
      []
    end
  end

  defp handle_directive(directive, state) do
    case state.agent_module.receive_directive(directive, state.agent_state) do
      {:ok, agent_state} ->
        %{state | agent_state: agent_state}

      {:defer, agent_state} ->
        %{state | agent_state: agent_state}

      _ ->
        state
    end
  end

  defp init_agent(agent_module, opts) do
    case agent_module.init(opts) do
      {:ok, state} -> state
      state when is_map(state) -> state
      _ -> %{}
    end
  end

  defp maybe_compact_history(agent_state, agent_module) do
    if function_exported?(agent_module, :compaction_config, 0) do
      do_compact_history(agent_state, agent_module.compaction_config())
    else
      agent_state
    end
  end

  defp do_compact_history(agent_state, nil), do: agent_state

  defp do_compact_history(agent_state, config) do
    case Map.get(agent_state, :history) do
      history when is_list(history) ->
        case ContextCompactor.compact(history, config) do
          %{compacted: true, messages: compacted} ->
            Logger.debug(
              "[Agent.Process] Compacted history: #{length(history)} -> #{length(compacted)} messages"
            )

            Map.put(agent_state, :history, compacted)

          _ ->
            agent_state
        end

      _ ->
        agent_state
    end
  end

  defp save_context(state) do
    if function_exported?(state.agent_module, :context_snapshot, 1) do
      snapshot = state.agent_module.context_snapshot(state.agent_state)
      ContextStore.save(state.agent_id, snapshot)
    end
  end

  defp schedule_tick(tick_ms) do
    Process.send_after(self(), :tick, tick_ms)
  end

  defp notify_orchestrator(message) do
    case Registry.lookup(Raxol.Agent.Registry, :orchestrator) do
      [{pid, _}] -> send(pid, message)
      _ -> :ok
    end
  end

  defp lookup(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, {:process, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp has_process_behaviour?(module) do
    behaviours =
      module.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Raxol.Agent.ProcessBehaviour in behaviours
  rescue
    UndefinedFunctionError -> false
    ArgumentError -> false
  end
end
