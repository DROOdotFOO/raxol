defmodule Raxol.Terminal.Registry do
  @moduledoc """
  Registry for terminal processes and components.

  This registry provides a way to register and lookup terminal-related processes
  such as emulators, sessions, and other terminal components.
  """

  use Raxol.Core.Behaviours.BaseManager

  # BaseManager provides start_link/1 with proper option handling
  # Users should pass name: __MODULE__ in options if they want the default name

  @doc """
  Registers a process under a given name.
  """
  def register(name, pid) do
    GenServer.call(__MODULE__, {:register, name, pid})
  end

  @doc """
  Looks up a process by name.
  """
  def lookup(name) do
    GenServer.call(__MODULE__, {:lookup, name})
  end

  @doc """
  Unregisters a process.
  """
  def unregister(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc """
  Lists all registered processes.
  """
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    # Use ETS table for efficient lookups
    table =
      :ets.new(:terminal_registry, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

    {:ok, %{table: table, name: Keyword.get(opts, :name, __MODULE__)}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register, name, pid}, _from, state) do
    case :ets.insert_new(:terminal_registry, {name, pid}) do
      true ->
        # Monitor the process so we can clean up when it dies
        Process.monitor(pid)
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :already_registered}, state}
    end
  end

  def handle_manager_call({:lookup, name}, _from, state) do
    case :ets.lookup(:terminal_registry, name) do
      [{^name, pid}] -> {:reply, {:ok, pid}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:unregister, name}, _from, state) do
    :ets.delete(:terminal_registry, name)
    {:reply, :ok, state}
  end

  def handle_manager_call(:list_all, _from, state) do
    processes = :ets.tab2list(:terminal_registry)
    {:reply, processes, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up dead processes
    :ets.match_delete(:terminal_registry, {:_, pid})
    {:noreply, state}
  end

  # Other info messages handled by BaseManager's default implementation
end
