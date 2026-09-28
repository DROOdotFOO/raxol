defmodule Raxol.Core.Runtime.Plugins.PluginRuntime do
  @moduledoc """
  Stable process that owns one loaded plugin's state and callback execution.

  All stateful callbacks for a plugin execute serially in this process. This
  gives timers and other messages sent to `self()` a stable destination for the
  lifetime of the loaded plugin.
  """

  use GenServer

  alias Raxol.Core.Runtime.Log

  alias Raxol.Core.Runtime.Plugins.{
    PluginInstanceSupervisor,
    ResourceBudget
  }

  @type plugin_id :: atom() | String.t()

  defstruct [:plugin_id, :module, :plugin_state]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    plugin_id = Keyword.fetch!(opts, :plugin_id)
    GenServer.start_link(__MODULE__, opts, name: PluginInstanceSupervisor.runtime_name(plugin_id))
  end

  @spec handle_event(plugin_id(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def handle_event(plugin_id, event, timeout \\ 5_000) do
    with :ok <- ResourceBudget.admit(plugin_id) do
      call(plugin_id, {:handle_event, event}, timeout)
    end
  end

  @spec filter_event(plugin_id(), term(), timeout()) :: {:ok, term()} | :halt | {:error, term()}
  def filter_event(plugin_id, event, timeout \\ 1_000) do
    with :ok <- ResourceBudget.admit(plugin_id) do
      call(plugin_id, {:filter_event, event}, timeout)
    end
  end

  @spec handle_command(plugin_id(), term(), list(), timeout()) ::
          {:ok, term(), term()} | {:error, term()}
  def handle_command(plugin_id, command, args, timeout \\ 5_000) do
    with :ok <- ResourceBudget.admit(plugin_id) do
      call(plugin_id, {:handle_command, command, args}, timeout)
    end
  end

  @spec call_hook(plugin_id(), atom(), [term()], timeout()) ::
          {:ok, term()} | {:error, term()} | :not_exported
  def call_hook(plugin_id, hook, args \\ [], timeout \\ 5_000) do
    call(plugin_id, {:call_hook, hook, args}, timeout)
  end

  @spec get_state(plugin_id()) :: {:ok, term()} | {:error, :not_found}
  def get_state(plugin_id), do: call(plugin_id, :get_state)

  @spec set_state(plugin_id(), term()) :: :ok | {:error, :not_found}
  def set_state(plugin_id, plugin_state), do: call(plugin_id, {:set_state, plugin_state})

  @impl GenServer
  def init(opts) do
    plugin_id = Keyword.fetch!(opts, :plugin_id)
    module = Keyword.fetch!(opts, :module)
    config = Keyword.get(opts, :config, %{})

    case initialize(module, config) do
      {:ok, plugin_state} ->
        {:ok, %__MODULE__{plugin_id: plugin_id, module: module, plugin_state: plugin_state}}

      {:error, reason} ->
        {:stop, {:plugin_init_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state.plugin_state}, state}
  end

  def handle_call({:set_state, plugin_state}, _from, state) do
    {:reply, :ok, %{state | plugin_state: plugin_state}}
  end

  def handle_call({:handle_event, event}, _from, state) do
    {reply, state} = invoke_event(event, state)
    {:reply, reply, state}
  end

  def handle_call({:filter_event, event}, _from, state) do
    reply =
      if function_exported?(state.module, :filter_event, 2) do
        state.module.filter_event(event, state.plugin_state)
      else
        {:ok, event}
      end

    {:reply, reply, state}
  rescue
    error -> {:reply, {:error, {:crashed, error}}, state}
  catch
    kind, value -> {:reply, {:error, {:crashed, {kind, value}}}, state}
  end

  def handle_call({:handle_command, command, args}, _from, state) do
    {reply, state} = invoke_command(command, args, state)
    {:reply, reply, state}
  end

  def handle_call({:call_hook, hook, args}, _from, state) do
    arity = length(args)

    if function_exported?(state.module, hook, arity) do
      {:reply, {:ok, apply(state.module, hook, args)}, state}
    else
      {:reply, :not_exported, state}
    end
  rescue
    error -> {:reply, {:error, {:crashed, error}}, state}
  catch
    kind, value -> {:reply, {:error, {:crashed, {kind, value}}}, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    {_reply, state} = invoke_event(message, state)
    {:noreply, state}
  end

  defp call(plugin_id, message, timeout \\ 5_000) do
    case PluginInstanceSupervisor.runtime_pid(plugin_id) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, message, timeout)
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
    end
  end

  defp initialize(module, config) do
    case module.init(config) do
      {:ok, plugin_state} -> {:ok, plugin_state}
      {:error, reason} -> {:error, reason}
      plugin_state when is_map(plugin_state) -> {:ok, plugin_state}
      other -> {:error, {:invalid_init_return, other}}
    end
  rescue
    error -> {:error, {:crashed, error}}
  catch
    kind, value -> {:error, {:crashed, {kind, value}}}
  end

  defp invoke_event(event, state) do
    if function_exported?(state.module, :handle_event, 2) do
      case state.module.handle_event(event, state.plugin_state) do
        {:ok, plugin_state} -> {{:ok, plugin_state}, %{state | plugin_state: plugin_state}}
        {:error, reason} -> {{:error, reason}, state}
        other -> {{:error, {:unexpected_return, other}}, state}
      end
    else
      {{:ok, state.plugin_state}, state}
    end
  rescue
    error ->
      Log.warning(
        "Plugin #{inspect(state.plugin_id)} event callback crashed: #{Exception.message(error)}"
      )

      {{:error, {:crashed, error}}, state}
  catch
    kind, value -> {{:error, {:crashed, {kind, value}}}, state}
  end

  defp invoke_command(command, args, state) do
    if function_exported?(state.module, :handle_command, 3) do
      case state.module.handle_command(command, args, state.plugin_state) do
        {:ok, plugin_state, result} ->
          {{:ok, plugin_state, result}, %{state | plugin_state: plugin_state}}

        {:error, reason, plugin_state} ->
          {{:error, reason}, %{state | plugin_state: plugin_state}}

        other ->
          {{:error, {:unexpected_return, other}}, state}
      end
    else
      {{:error, :command_not_supported}, state}
    end
  rescue
    error -> {{:error, {:crashed, error}}, state}
  catch
    kind, value -> {{:error, {:crashed, {kind, value}}}, state}
  end
end
