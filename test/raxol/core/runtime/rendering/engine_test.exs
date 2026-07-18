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

  describe "the paint gate (:suspend_painting / :resume_painting)" do
    # Unit U6-b of the harness TEA migration. The SessionPump gates Engine
    # painting around its editor bracket and teardown (PumpContract §7);
    # these tests pin the three laws the pump relies on: frames drop while
    # gated (nothing races the tty handoff), resume restores painting, and
    # resume forces a keyframe (dropped frames leave the backend buffer
    # arbitrarily stale).

    defmodule RenderContextStub do
      @moduledoc false
      use GenServer

      def start_link(recorder),
        do: GenServer.start_link(__MODULE__, recorder)

      @impl true
      def init(recorder), do: {:ok, recorder}

      @impl true
      def handle_call(:get_render_context, _from, recorder) do
        send(recorder, :render_context_requested)
        {:reply, {:ok, %{model: %{}, theme_id: :default}}, recorder}
      end
    end

    defmodule NilViewApp do
      @moduledoc false
      def view(_model), do: nil
    end

    defp gated_engine do
      {:ok, stub} = RenderContextStub.start_link(self())

      {:ok, pid} =
        Engine.start_link(
          name: :"engine_gate_#{System.unique_integer([:positive])}",
          app_module: NilViewApp,
          dispatcher_pid: stub,
          environment: :agent
        )

      pid
    end

    test "a :render_frame cast while suspended never touches the dispatcher" do
      pid = gated_engine()

      assert :ok = GenServer.call(pid, :suspend_painting)
      GenServer.cast(pid, :render_frame)

      # {:get_state} is the sync point: it replies only after the engine
      # processed every earlier mailbox message, so the cast above HAS
      # been handled by the time we look for its side effect -- a missing
      # gate could not hide behind scheduling.
      state = GenServer.call(pid, {:get_state})
      assert state.painting? == false

      # The dropped frame must not even ASK for the render context: asking
      # is the first step of painting, and any paint byte would race the
      # pump's tty handoff.
      refute_received :render_context_requested
      GenServer.stop(pid)
    end

    test "resume restores painting and forces the keyframe" do
      pid = gated_engine()

      assert :ok = GenServer.call(pid, :suspend_painting)
      assert :ok = GenServer.call(pid, :resume_painting)

      state = GenServer.call(pid, {:get_state})
      assert state.painting? == true
      assert state.force_repaint == true

      GenServer.cast(pid, :render_frame)
      assert_receive :render_context_requested, 500
      GenServer.stop(pid)
    end

    test "painting flows by default (the gate is opt-in)" do
      pid = gated_engine()

      GenServer.cast(pid, :render_frame)
      assert_receive :render_context_requested, 500
      GenServer.stop(pid)
    end
  end
end
