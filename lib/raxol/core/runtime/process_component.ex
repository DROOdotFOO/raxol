defmodule Raxol.Core.Runtime.ProcessComponent do
  @moduledoc """
  A GenServer wrapping a single component module for crash isolation.

  Each ProcessComponent runs in its own process under `Raxol.DynamicSupervisor`,
  so a crash in one component does not bring down the rest of the application.

  The rendering engine that draws a `process_component/2` node owns its
  process: it starts it on the first frame the node is in the view, keeps it
  (and the component's state) across frames, and stops it when the node
  leaves the view or the engine stops. A process also stops when its owner
  (`:parent_pid`) exits. The supervisor does not restart a crashed component;
  the frame draws a placeholder in its place and the next frame starts it
  again with fresh state from `init/1`.

  ## Usage

  Components used with ProcessComponent must implement:
  - `init/1` - receives props, returns initial state
  - `render/2` - receives state and context, returns element tree
  - `update/2` (optional) - receives message and state, returns new state.
    When the node's props change, the running component receives
    `{:update_props, new_props}` here; its state is otherwise kept.

  Use the `process_component/2` View DSL helper to embed process components:

      process_component(MyHeavyWidget, %{path: "/tmp"})
  """

  use GenServer, restart: :temporary

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

  @doc """
  Replaces the component's props, keeping its state. The component receives
  `{:update_props, props}` through `update/2`, if it exports one.
  """
  def update_props(pid, props) do
    GenServer.call(pid, {:update_props, props})
  end

  def get_render_tree(pid, context) do
    GenServer.call(pid, {:render, context})
  end

  @impl true
  def init(%{module: module, props: props, parent_pid: parent_pid, id: id}) do
    Raxol.Core.Runtime.Log.info(
      "[ProcessComponent] Starting #{inspect(module)} (#{id})"
    )

    Process.monitor(parent_pid)

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
  def handle_call({:update_props, props}, _from, %__MODULE__{} = pc) do
    new_state = dispatch_update(pc.module, {:update_props, props}, pc.state)
    {:reply, :ok, %{pc | props: props, state: new_state}}
  end

  @impl true
  def handle_call({:render, context}, _from, %__MODULE__{} = pc) do
    tree = dispatch_render(pc.module, pc.state, context, pc.id)
    {:reply, tree, pc}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown}, state}

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, owner, _reason},
        %__MODULE__{parent_pid: owner} = pc
      ),
      do: {:stop, :normal, pc}

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
