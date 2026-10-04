defmodule Raxol.Core.Runtime.Rendering.EngineTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Engine

  defmodule NilViewApp do
    def view(_model), do: nil
  end

  defmodule GatedDispatcher do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, %{owner: owner, calls: 0, waiting: %{}}}

    @impl true
    def handle_call(:get_render_context, from, state) do
      call = state.calls + 1
      send(state.owner, {:render_context_requested, call})

      {:noreply,
       %{state | calls: call, waiting: Map.put(state.waiting, call, from)}}
    end

    @impl true
    def handle_cast({:release, call}, state) do
      {from, waiting} = Map.pop!(state.waiting, call)
      GenServer.reply(from, {:ok, %{model: %{}, theme_id: nil}})
      {:noreply, %{state | waiting: waiting}}
    end
  end

  describe "start_link/1 and init/1" do
    test "starts with keyword list opts" do
      {:ok, pid} =
        Engine.start_link(
          name: :"engine_test_#{System.unique_integer([:positive])}",
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 100,
          height: 50,
          environment: :agent
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with map opts" do
      name = :"engine_map_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Engine.start_link(%{
          name: name,
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 80,
          height: 24,
          environment: :agent
        })

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initializes with correct dimensions" do
      name = :"engine_dims_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Engine.start_link(
          name: name,
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 120,
          height: 60,
          environment: :agent
        )

      state = GenServer.call(pid, {:get_state})
      assert state.width == 120
      assert state.height == 60
      assert state.buffer != nil
      GenServer.stop(pid)
    end

    test "defaults to 80x24 when dimensions not provided" do
      name = :"engine_default_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Engine.start_link(
          name: name,
          app_module: __MODULE__,
          dispatcher_pid: self(),
          environment: :agent
        )

      state = GenServer.call(pid, {:get_state})
      assert state.width == 80
      assert state.height == 24
      GenServer.stop(pid)
    end

    test "clamps an initial size past the terminal size ceiling" do
      {:ok, pid} =
        Engine.start_link(
          name: :"engine_init_cap_#{System.unique_integer([:positive])}",
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 100_000,
          height: 100_000,
          environment: :agent
        )

      state = GenServer.call(pid, {:get_state})
      assert {state.width, state.height} == {4096, 256}
      assert {state.buffer.width, state.buffer.height} == {4096, 256}
      GenServer.stop(pid)
    end
  end

  describe "handle_cast {:update_size, ...}" do
    test "updates dimensions and creates new buffer" do
      name = :"engine_resize_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Engine.start_link(
          name: name,
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 80,
          height: 24,
          environment: :agent
        )

      GenServer.cast(pid, {:update_size, %{width: 200, height: 50}})
      # Give the cast time to process
      :timer.sleep(10)

      state = GenServer.call(pid, {:get_state})
      assert state.width == 200
      assert state.height == 50
      GenServer.stop(pid)
    end

    # The resize a remote client (SSH window_change) or any other surface
    # sends: the engine lays out, allocates and draws at this size.
    test "clamps a size past the terminal size ceiling" do
      {:ok, pid} =
        Engine.start_link(
          name: :"engine_resize_cap_#{System.unique_integer([:positive])}",
          app_module: __MODULE__,
          dispatcher_pid: self(),
          width: 80,
          height: 24,
          environment: :agent
        )

      GenServer.cast(
        pid,
        {:update_size, %{width: 4_294_967_295, height: 4_294_967_295}}
      )

      state = GenServer.call(pid, {:get_state})
      assert {state.width, state.height} == {4096, 256}
      assert {state.buffer.width, state.buffer.height} == {4096, 256}
      assert length(state.buffer.cells) == 256
      GenServer.stop(pid)
    end
  end

  describe "handle_call {:update_props, ...}" do
    test "returns :ok" do
      name = :"engine_props_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Engine.start_link(
          name: name,
          app_module: __MODULE__,
          dispatcher_pid: self(),
          environment: :agent
        )

      assert :ok = GenServer.call(pid, {:update_props, %{some: :prop}})
      GenServer.stop(pid)
    end
  end

  describe "asynchronous render resilience" do
    test "coalesces a queued burst into one trailing latest-state render" do
      dispatcher = start_supervised!({GatedDispatcher, self()})

      engine =
        start_supervised!(
          {Engine,
           app_module: NilViewApp,
           dispatcher_pid: dispatcher,
           width: 10,
           height: 3,
           environment: :agent},
          id: make_ref()
        )

      GenServer.cast(engine, :render_frame)
      assert_receive {:render_context_requested, 1}

      for _ <- 1..20, do: GenServer.cast(engine, :render_frame)
      GenServer.cast(dispatcher, {:release, 1})

      assert_receive {:render_context_requested, 2}
      GenServer.cast(dispatcher, {:release, 2})

      refute_receive {:render_context_requested, 3}, 100
      assert %Engine.State{} = GenServer.call(engine, {:get_state})
    end

    test "a dispatcher timeout skips the frame without terminating the engine" do
      dispatcher = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(dispatcher, :kill) end)

      engine =
        start_supervised!(
          {Engine,
           app_module: NilViewApp,
           dispatcher_pid: dispatcher,
           dispatcher_timeout: 25,
           width: 10,
           height: 3,
           environment: :agent},
          id: make_ref()
        )

      GenServer.cast(engine, :render_frame)

      assert %Engine.State{} = GenServer.call(engine, {:get_state}, 500)
      assert Process.alive?(engine)
    end
  end
end
