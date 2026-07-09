defmodule Raxol.Core.Runtime.ProcessComponent do
  @moduledoc """
  A GenServer wrapping a single component module for crash isolation.

  Each ProcessComponent runs in its own process under `Raxol.DynamicSupervisor`,
  so a crash in one component does not bring down the rest of the application.
  On crash, the DynamicSupervisor restarts the component with fresh state.

  ## Usage

  Components used with ProcessComponent must implement:
  - `init/1` - receives props, returns initial state
  - `render/2` - receives state and context, returns element tree
  - `update/2` (optional) - receives message and state, returns new state

  Use the `process_component/2` View DSL helper to embed process components:

      process_component(MyHeavyWidget, %{path: "/tmp"})
  """

  use GenServer

  defstruct [:module, :state, :props, :parent_pid, :id]

  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    props = Keyword.get(opts, :props, %{})
    parent_pid = Keyword.get(opts, :parent_pid, self())
    id = Keyword.get(opts, :id, "pc-#{inspect(module)}")

    GenServer.start_link(__MODULE__, %{
      module: module,
      props: props,
      parent_pid: parent_pid,
      id: id
    })
  end

  def send_update(pid, message) do
    GenServer.call(pid, {:update, message})
  end

  def get_render_tree(pid, context) do
    GenServer.call(pid, {:render, context})
  end

  @impl true
  def init(%{module: module, props: props, parent_pid: parent_pid, id: id}) do
    Raxol.Core.Runtime.Log.info(
      "[ProcessComponent] Starting #{inspect(module)} (#{id})"
    )

    component_state = initialize_component(module, props)

    component_state = maybe_mount(module, component_state)

    {:ok,
     %__MODULE__{
       module: module,
       state: component_state,
       props: props,
       parent_pid: parent_pid,
       id: id
     }}
  end

  @impl true
  def handle_call({:update, message}, _from, %__MODULE__{} = pc) do
    new_state = dispatch_update(pc.module, message, pc.state)
    {:reply, :ok, %{pc | state: new_state}}
  end

  @impl true
  def handle_call({:render, context}, _from, %__MODULE__{} = pc) do
    tree = dispatch_render(pc.module, pc.state, context, pc.id)
    {:reply, tree, pc}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown}, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp initialize_component(module, props) do
    case function_exported?(module, :init, 1) do
      true -> normalize_init_result(module.init(props))
      false -> %{}
    end
  end

  defp normalize_init_result({:ok, state}), do: state
  defp normalize_init_result(state) when is_map(state), do: state
  defp normalize_init_result(_), do: %{}

  defp maybe_mount(module, state) do
    case function_exported?(module, :mount, 1) do
      true -> module.mount(state)
      false -> state
    end
  end

  defp dispatch_update(module, message, state) do
    case function_exported?(module, :update, 2) do
      true -> module.update(message, state)
      false -> state
    end
  end

  defp dispatch_render(module, state, context, id) do
    case function_exported?(module, :render, 2) do
      true -> module.render(state, context)
      false -> %{type: :text, content: "[#{id}]", style: %{}}
    end
  end
end
