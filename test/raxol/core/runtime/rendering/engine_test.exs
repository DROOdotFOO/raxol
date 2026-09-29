defmodule Raxol.Core.Runtime.Rendering.EngineTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Engine

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
end
