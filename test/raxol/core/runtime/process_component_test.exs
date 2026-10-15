defmodule Raxol.Core.Runtime.ProcessComponentTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import ExUnit.CaptureLog

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

  # Returns its state as a bare map and exports neither mount/1 nor
  # unmount/1, so the optional hooks are exercised as absent.
  defmodule BareWidget do
    def init(props), do: %{count: Map.get(props, :initial, 0)}

    def render(state, _context) do
      %{type: :text, content: "bare=#{state.count}", style: %{}}
    end
  end

  # Reports every lifecycle step to the test process named in its props, and
  # fails init on demand, so tests can assert the order of init, mount, the
  # ready message and unmount. It has no update_props/2, so a props change
  # goes through the unmount + re-init path.
  defmodule LifecycleWidget do
    def init(%{test: test} = props) do
      send(test, {:init, self(), props})

      case props do
        %{fail: reason} ->
          {:error, reason}

        %{bad: value} ->
          value

        _ ->
          {:ok,
           %{
             test: test,
             tag: Map.get(props, :tag),
             secret: Map.get(props, :secret)
           }}
      end
    end

    def mount(state) do
      send(state.test, {:mounted, self()})
      state
    end

    def unmount(state) do
      send(state.test, {:unmounted, self(), state})
      :ignored
    end

    def render(state, _context) do
      %{type: :text, content: "tag=#{state.tag}", style: %{}}
    end
  end

  defmodule RaisingUnmountWidget do
    def init(%{test: test}), do: {:ok, %{test: test}}

    def unmount(state) do
      send(state.test, {:unmount_called, self()})
      raise "unmount boom"
    end

    def render(_state, _context), do: %{type: :text, content: "x", style: %{}}
  end

  describe "lifecycle" do
    test "starts and renders" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 5},
          parent_pid: self()
        )

      tree = ProcessComponent.get_render_tree(pid, %{})
      assert tree == %{type: :text, content: "Count: 5", style: %{}}

      GenServer.stop(pid)
    end

    test "handles updates" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 0},
          parent_pid: self()
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
          props: %{},
          parent_pid: self()
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

    test "parent_pid is required" do
      assert_raise KeyError, fn ->
        ProcessComponent.start_link(module: TestWidget, props: %{})
      end
    end

    test "a module that cannot be loaded is refused without a process" do
      Process.flag(:trap_exit, true)
      {:links, links} = Process.info(self(), :links)

      assert {:error, {:module_not_available, Raxol.Does.Not.Exist, :nofile}} =
               ProcessComponent.start_link(
                 module: Raxol.Does.Not.Exist,
                 parent_pid: self()
               )

      assert {:links, ^links} = Process.info(self(), :links)
      refute_received {:EXIT, _, _}
    end
  end

  describe "init contract" do
    test "{:ok, map} and a bare map are both accepted as state" do
      {:ok, ok_pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 1},
          parent_pid: self()
        )

      {:ok, bare_pid} =
        ProcessComponent.start_link(
          module: BareWidget,
          props: %{initial: 2},
          parent_pid: self()
        )

      assert %{content: "Count: 1"} =
               ProcessComponent.get_render_tree(ok_pid, %{})

      assert %{content: "bare=2"} =
               ProcessComponent.get_render_tree(bare_pid, %{})

      assert_receive {:process_component_ready, ^ok_pid}
      assert_receive {:process_component_ready, ^bare_pid}

      GenServer.stop(ok_pid)
      GenServer.stop(bare_pid)
    end

    test "{:error, reason} from init/1 stops the process with that reason" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, pid} =
            ProcessComponent.start_link(
              module: LifecycleWidget,
              props: %{test: self(), fail: :no_resource, secret: "s3cr3t-token"},
              parent_pid: self()
            )

          assert_receive {:EXIT, ^pid, :no_resource}
          refute_received {:process_component_ready, ^pid}
          refute_received {:mounted, ^pid}
          refute_received {:unmounted, ^pid, _}
        end)

      # The crash report names the component but carries no props values.
      assert log =~ "LifecycleWidget"
      refute log =~ "s3cr3t-token"
    end

    test "a return that is neither {:ok, _}, {:error, _} nor a map stops the process" do
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        {:ok, pid} =
          ProcessComponent.start_link(
            module: LifecycleWidget,
            props: %{test: self(), bad: :not_a_state},
            parent_pid: self()
          )

        assert_receive {:EXIT, ^pid, {:bad_init_return, :not_a_state}}
        refute_received {:process_component_ready, ^pid}
      end)
    end
  end

  describe "ready message" do
    test "reaches parent_pid once, after init/1 and mount/1" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), tag: :a},
          parent_pid: self()
        )

      assert next_message() == {:init, pid, %{test: self(), tag: :a}}
      assert next_message() == {:mounted, pid}
      assert next_message() == {:process_component_ready, pid}

      # A props change re-initialises the component in place; that is not a
      # new start, so the owner must not be told "ready" a second time.
      :ok = ProcessComponent.update_props(pid, %{test: self(), tag: :b})

      assert next_message() ==
               {:unmounted, pid, %{test: self(), tag: :a, secret: nil}}

      assert next_message() == {:init, pid, %{test: self(), tag: :b}}
      assert next_message() == {:mounted, pid}

      assert %{content: "tag=b"} = ProcessComponent.get_render_tree(pid, %{})
      refute_received {:process_component_ready, ^pid}

      GenServer.stop(pid)
    end

    test "is sent to parent_pid, not to the caller of start_link" do
      owner = spawn(fn -> receive do: (:exit -> :ok) end)
      on_exit(fn -> send(owner, :exit) end)

      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self()},
          parent_pid: owner
        )

      assert_receive {:mounted, ^pid}
      refute_receive {:process_component_ready, ^pid}

      GenServer.stop(pid)
    end
  end

  describe "unmount/1" do
    test "runs with the live state on GenServer.stop" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), tag: :stop},
          parent_pid: self()
        )

      assert_receive {:process_component_ready, ^pid}
      :ok = GenServer.stop(pid)

      assert_received {:unmounted, ^pid, %{tag: :stop}}
    end

    test "runs on supervisor shutdown" do
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {ProcessComponent,
           module: LifecycleWidget,
           props: %{test: self(), tag: :sup},
           parent_pid: self()}
        )

      assert_receive {:process_component_ready, ^pid}
      ref = Process.monitor(pid)

      :ok = DynamicSupervisor.terminate_child(sup, pid)

      assert_receive {:unmounted, ^pid, %{tag: :sup}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    end

    test "runs when the owner exits" do
      owner = spawn(fn -> receive do: (:exit -> :ok) end)
      on_exit(fn -> send(owner, :exit) end)

      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), tag: :owner},
          parent_pid: owner
        )

      assert_receive {:mounted, ^pid}
      ref = Process.monitor(pid)
      send(owner, :exit)

      assert_receive {:unmounted, ^pid, %{tag: :owner}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "does not run for a component that never became ready" do
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        {:ok, pid} =
          ProcessComponent.start_link(
            module: LifecycleWidget,
            props: %{test: self(), fail: :boom},
            parent_pid: self()
          )

        assert_receive {:EXIT, ^pid, :boom}
        refute_received {:unmounted, ^pid, _}
      end)
    end

    test "runs on the old state before a re-init, and a failed re-init stops the process with its reason" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), tag: :old},
          parent_pid: self()
        )

      assert_receive {:process_component_ready, ^pid}

      capture_log(fn ->
        catch_exit(
          ProcessComponent.update_props(pid, %{
            test: self(),
            fail: :reinit_failed
          })
        )

        assert_receive {:EXIT, ^pid, :reinit_failed}
      end)

      assert_received {:unmounted, ^pid, %{tag: :old}}
      assert_received {:init, ^pid, %{fail: :reinit_failed}}
      # The old state was already unmounted; terminate must not do it twice.
      refute_received {:unmounted, ^pid, _}
    end

    test "an exception in unmount/1 is logged and does not change the exit reason" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: RaisingUnmountWidget,
          props: %{test: self()},
          parent_pid: self()
        )

      assert_receive {:process_component_ready, ^pid}
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          :ok = GenServer.stop(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert_received {:unmount_called, ^pid}
      assert log =~ "unmount boom"
      assert log =~ "RaisingUnmountWidget"
    end
  end

  describe "exit handling" do
    test "a crash in a linked process stops the component with that reason" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), tag: :linked},
          parent_pid: self()
        )

      assert_receive {:process_component_ready, ^pid}
      ref = Process.monitor(pid)

      capture_log(fn ->
        spawn(fn ->
          Process.link(pid)
          exit(:linked_crash)
        end)

        assert_receive {:DOWN, ^ref, :process, ^pid, :linked_crash}
      end)

      # The component was live, so its teardown hook still ran.
      assert_received {:unmounted, ^pid, %{tag: :linked}}
    end
  end

  describe "format_status/1" do
    test "hides state and props from :sys.get_status" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: LifecycleWidget,
          props: %{test: self(), secret: "s3cr3t-token"},
          parent_pid: self()
        )

      assert_receive {:process_component_ready, ^pid}

      status = inspect(:sys.get_status(pid), limit: :infinity)

      refute status =~ "s3cr3t-token"
      assert status =~ "LifecycleWidget"
      assert status =~ "redacted"

      GenServer.stop(pid)
    end
  end

  describe "crash isolation" do
    test "component crash does not affect caller" do
      {:ok, pid} =
        ProcessComponent.start_link(
          module: TestWidget,
          props: %{initial: 0},
          parent_pid: self()
        )

      # The crash should terminate the GenServer
      Process.flag(:trap_exit, true)

      catch_exit(ProcessComponent.send_update(pid, :crash))

      refute Process.alive?(pid)
      # The test process (caller) is still alive
      assert Process.alive?(self())
    end
  end

  defp next_message do
    receive do
      message -> message
    after
      1_000 -> flunk("no message arrived")
    end
  end
end
