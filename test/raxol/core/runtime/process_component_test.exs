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

    # One nightly (#1253) saw `{:ok, pid}` from `start_link/1` and then a
    # `:noproc` DOWN from the monitor taken right after it, which the old test
    # reported as a bare `assert_receive` timeout: it could not say whether
    # the owner died early, the component died on its own, or the component
    # outlived the owner. Monitoring both processes before anything else means
    # every exit arrives as a DOWN with a distinct pinned ref, so a mismatch
    # names the process; the `alive?` checks and the `refute_received` prove
    # neither died during start, before the owner is told to leave. The
    # `on_exit` releases the owner if an assertion fails, so a failed run
    # does not leak a process blocked in `receive`.
    test "stops when the process that owns it exits" do
      owner = spawn(fn -> receive do: (:exit -> :ok) end)

      on_exit(fn ->
        if Process.alive?(owner), do: send(owner, :exit)
      end)

      owner_ref = Process.monitor(owner)

      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 0},
          parent_pid: owner
        )

      component_ref = Process.monitor(pid)

      assert Process.alive?(owner), "owner died before the component started"
      assert Process.alive?(pid), "component died during start"
      refute_received {:DOWN, _, :process, _, _}

      send(owner, :exit)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
      assert_receive {:DOWN, ^component_ref, :process, ^pid, :normal}
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
end
