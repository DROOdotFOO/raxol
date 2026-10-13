defmodule Raxol.Core.Runtime.ProcessComponent do
  @moduledoc """
  A GenServer wrapping a single component module for crash isolation.

  Each ProcessComponent runs in its own process under `Raxol.DynamicSupervisor`,
  so a crash in one component does not bring down the rest of the application.

  The rendering engine that draws a `process_component/2` node owns its
  process: it starts it on the first frame the node is in the view, keeps it
  (and the component's state) across frames, and stops it when the node
  leaves the view or the engine stops. A process also stops when its owner
  (`:parent_pid`, required) exits. The supervisor does not restart a crashed
  component; the frame draws a placeholder in its place and a later frame
  starts it again with fresh state from `init/1`.

  ## Start-up

  `start_link/1` only checks that the module is loaded (an unloadable module
  is `{:error, {:module_not_available, module, reason}}` and no process is
  started) and returns as soon as the process exists. `init/1` and `mount/1`
  run afterwards inside the new process, so a slow `init/1` holds up neither
  the caller nor the supervisor that starts every component in the VM. Once
  both have run, the owner receives `{:process_component_ready, pid}`, once;
  until then the engine draws a "starting" placeholder for the node. A call
  such as `get_render_tree/2` made before that simply waits.

  `init/1` must return `{:ok, state}` or a bare map. `{:error, reason}` stops
  the process with `reason`; anything else stops it with
  `{:bad_init_return, value}`. Nothing is silently turned into empty state.

  ## Usage

  Components used with ProcessComponent must implement:
  - `init/1` - receives props, returns `{:ok, state}`, a state map, or
    `{:error, reason}`
  - `render/2` - receives state and context, returns element tree
  - `update/2` (optional) - receives message and state, returns new state
  - `update_props/2` (optional) - receives the node's changed props and the
    state, returns new state. A component that exports it keeps its state
    across props changes; one that doesn't is re-initialised from the new
    props through `init/1` (and `mount/1`) in the same process, after
    `unmount/1` has seen the old state.
  - `mount/1` (optional) - receives the initial state after `init/1`, returns
    the state to continue with
  - `unmount/1` (optional) - the mirror of `mount/1`: receives the live state
    when the component stops for any reason (its node left the view, the
    engine or owner stopped, the supervisor shut it down, a crash) or just
    before a re-init. Its return value is ignored, and an exception raised
    in it is logged and does not change why or whether the component stops.
    It does not run for a component whose `init/1` failed.

  Crash reports and `:sys.get_status/1` show the component module and id
  only; its state and props are redacted, since props routinely carry
  credentials.

  Use the `process_component/2` View DSL helper to embed process components:

      process_component(MyHeavyWidget, %{path: "/tmp"})
  """

  use GenServer, restart: :temporary

  alias Raxol.Core.Runtime.Log

  defstruct [:module, :state, :props, :parent_pid, :id, ready?: false]

  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    parent_pid = Keyword.fetch!(opts, :parent_pid)
    props = Keyword.get(opts, :props, %{})
    id = Keyword.get(opts, :id, "pc-#{inspect(module)}")

    # function_exported?/3 (used for every optional callback below) does not
    # load code, so an unloaded module would look like one with no callbacks
    # and render as a bare placeholder. Load it here, once, before anything
    # dispatches on it.
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        GenServer.start_link(__MODULE__, %{
          module: module,
          props: props,
          parent_pid: parent_pid,
          id: id
        })

      {:error, reason} ->
        {:error, {:module_not_available, module, reason}}
    end
  end

  def send_update(pid, message) do
    GenServer.call(pid, {:update, message})
  end

  @doc """
  Replaces the component's props in its running process. A component that
  exports `update_props/2` gets `update_props(props, state)` and keeps the
  state it returns; any other has `unmount/1` called on its current state
  and is re-initialised from `props` through `init/1` (and `mount/1`, if
  exported). A re-init whose `init/1` fails stops the process with that
  reason, and this call exits.
  """
  def update_props(pid, props) do
    GenServer.call(pid, {:update_props, props})
  end

  def get_render_tree(pid, context) do
    GenServer.call(pid, {:render, context})
  end

  @impl true
  def init(%{module: module, props: props, parent_pid: parent_pid, id: id}) do
    Log.info("[ProcessComponent] Starting #{inspect(module)} (#{id})")

    # Trapping exits is what makes terminate/2, and so unmount/1, run when
    # the supervisor shuts the component down.
    Process.flag(:trap_exit, true)
    Process.monitor(parent_pid)

    {:ok,
     %__MODULE__{
       module: module,
       state: nil,
       props: props,
       parent_pid: parent_pid,
       id: id,
       ready?: false
     }, {:continue, :init_component}}
  end

  @impl true
  def handle_continue(:init_component, %__MODULE__{} = pc) do
    case initialize_component(pc.module, pc.props) do
      {:ok, state} ->
        send(pc.parent_pid, {:process_component_ready, self()})
        {:noreply, %{pc | state: state, ready?: true}}

      {:error, reason} ->
        {:stop, reason, pc}
    end
  end

  @impl true
  def handle_call({:update, message}, _from, %__MODULE__{} = pc) do
    new_state = dispatch_update(pc.module, message, pc.state)
    {:reply, :ok, %{pc | state: new_state}}
  end

  @impl true
  def handle_call({:update_props, props}, _from, %__MODULE__{} = pc) do
    case dispatch_update_props(pc, props) do
      {:ok, new_state} ->
        {:reply, :ok, %{pc | props: props, state: new_state}}

      {:error, reason} ->
        # The old state was unmounted before the re-init was attempted;
        # marking the component not ready keeps terminate/2 from unmounting
        # it a second time.
        {:stop, reason, %{pc | props: props, state: nil, ready?: false}}
    end
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

  # Trapping exits turns a linked process's crash into a message. Without
  # this clause it would be swallowed, where a non-trapping process would
  # have died with it; the exit from the parent never gets here, gen_server
  # handles that itself.
  def handle_info({:EXIT, _pid, reason}, %__MODULE__{} = pc),
    do: {:stop, reason, pc}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{ready?: true} = pc) do
    safe_unmount(pc)
    :ok
  end

  def terminate(_reason, _pc), do: :ok

  # Crash reports and :sys.get_status/1 get the module and id only. The
  # state and props are the component's own business, and props are where
  # tokens and keys get passed in.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, pc} ->
        {:state, redact(pc)}

      {:log, log} ->
        {:log, Enum.map(log, &redact_log_event/1)}

      {:message, {:update_props, _props}} ->
        {:message, {:update_props, :redacted}}

      other ->
        other
    end)
  end

  defp redact(%__MODULE__{module: module, id: id}),
    do: %{module: module, id: id, state: :redacted, props: :redacted}

  defp redact_log_event({:out, reply, to, pc}),
    do: {:out, reply, to, redact(pc)}

  defp redact_log_event({:noreply, pc}), do: {:noreply, redact(pc)}
  defp redact_log_event(event), do: event

  defp initialize_component(module, props) do
    result =
      case function_exported?(module, :init, 1) do
        true -> module.init(props)
        false -> {:ok, %{}}
      end

    case result do
      {:ok, state} -> {:ok, maybe_mount(module, state)}
      state when is_map(state) -> {:ok, maybe_mount(module, state)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_init_return, other}}
    end
  end

  defp maybe_mount(module, state) do
    case function_exported?(module, :mount, 1) do
      true -> module.mount(state)
      false -> state
    end
  end

  defp safe_unmount(%__MODULE__{module: module, id: id, state: state}) do
    if function_exported?(module, :unmount, 1) do
      try do
        module.unmount(state)
      catch
        kind, reason ->
          Log.error_with_context(
            "[ProcessComponent] unmount/1 of #{inspect(module)} (#{id}) failed: " <>
              Exception.format(kind, reason, __STACKTRACE__),
            %{module: module, id: id}
          )
      end
    end

    :ok
  end

  defp dispatch_update(module, message, state) do
    case function_exported?(module, :update, 2) do
      true -> module.update(message, state)
      false -> state
    end
  end

  defp dispatch_update_props(%__MODULE__{module: module} = pc, props) do
    case function_exported?(module, :update_props, 2) do
      true ->
        {:ok, module.update_props(props, pc.state)}

      false ->
        safe_unmount(pc)
        initialize_component(module, props)
    end
  end

  defp dispatch_render(module, state, context, id) do
    case function_exported?(module, :render, 2) do
      true -> module.render(state, context)
      false -> %{type: :text, content: "[#{id}]", style: %{}}
    end
  end
end
