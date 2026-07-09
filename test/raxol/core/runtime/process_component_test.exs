defmodule Raxol.Core.Runtime.ProcessComponentTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.ProcessComponent

  defmodule TestWidget do
    def init(props) do
      {:ok, %{count: Map.get(props, :initial, 0)}}
    end

    def update(:increment, state) do
      %{state | count: state.count + 1}
    end

    def update(:crash, _state) do
      raise "intentional crash"
    end

    def render(state, _context) do
      %{type: :text, content: "Count: #{state.count}", style: %{}}
    end
  end

  defmodule MountableWidget do
    def init(_props) do
      {:ok, %{mounted: false}}
    end

    def mount(state) do
      %{state | mounted: true}
    end

    def render(state, _context) do
      %{type: :text, content: "mounted=#{state.mounted}", style: %{}}
    end
  end

  describe "lifecycle" do
    test "starts and renders" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 5}
        )

      tree = ProcessComponent.get_render_tree(pid, %{})
      assert tree == %{type: :text, content: "Count: 5", style: %{}}

      GenServer.stop(pid)
    end

    test "handles updates" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 0}
        )

      :ok = ProcessComponent.send_update(pid, :increment)
      :ok = ProcessComponent.send_update(pid, :increment)

      tree = ProcessComponent.get_render_tree(pid, %{})
      assert tree == %{type: :text, content: "Count: 2", style: %{}}

      GenServer.stop(pid)
    end

    test "calls mount/1 if exported" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: MountableWidget,
          props: %{}
        )

      tree = ProcessComponent.get_render_tree(pid, %{})
      assert tree == %{type: :text, content: "mounted=true", style: %{}}

      GenServer.stop(pid)
    end
  end

  describe "crash isolation" do
    test "component crash does not affect caller" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 0}
        )

      # The crash should terminate the GenServer
      Process.flag(:trap_exit, true)

      catch_exit(ProcessComponent.send_update(pid, :crash))

      refute Process.alive?(pid)
      # The test process (caller) is still alive
      assert Process.alive?(self())
    end
  end

  describe "process_component view helper" do
    test "returns correct map structure" do
      result = Raxol.Core.Renderer.View.process_component(TestWidget, %{initial: 1})

      assert result == %{
               type: :process_component,
               module: TestWidget,
               props: %{initial: 1},
               id: "pc-#{inspect(TestWidget)}"
             }
    end
  end
end
