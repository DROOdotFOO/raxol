defmodule Raxol.Agent.Session do
  @moduledoc """
  Manages a single agent's TEA application lifecycle.

  Follows the same pattern as `Raxol.SSH.Session`: wraps a Lifecycle
  instance with `environment: :agent`. Agents register in
  `Raxol.Agent.Registry` for discovery by other agents.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  defstruct [:id, :app_module, :lifecycle_pid, :team_id]

  @type t :: %__MODULE__{
          id: term(),
          app_module: module(),
          lifecycle_pid: pid() | nil,
          team_id: term() | nil
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

    {:ok, lifecycle_pid} =
      Raxol.Core.Runtime.Lifecycle.start_link(app_module,
        environment: :agent,
        width: Raxol.Core.Defaults.terminal_width(),
        height: Raxol.Core.Defaults.terminal_height(),
        name: :"agent_lifecycle_#{inspect(id)}"
      )

    # Unlink so Lifecycle crashes don't kill the Session.
    Process.unlink(lifecycle_pid)
    Process.monitor(lifecycle_pid)

    Logger.info("[Agent.Session] Started agent #{inspect(id)} (#{inspect(app_module)})")

    {:ok,
     %__MODULE__{
       id: id,
       app_module: app_module,
       lifecycle_pid: lifecycle_pid,
       team_id: team_id
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:send_message, message}, state) do
    case get_dispatcher(state.lifecycle_pid) do
      nil ->
        :ok

      dispatcher_pid ->
        GenServer.cast(
          dispatcher_pid,
          {:dispatch, {:agent_message, state.id, message}}
        )
    end

    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(_msg, state), do: {:noreply, state}

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

    :ok
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
