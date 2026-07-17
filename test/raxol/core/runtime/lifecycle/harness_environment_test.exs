defmodule Raxol.Core.Runtime.Lifecycle.HarnessEnvironmentTest do
  @moduledoc """
  F0-env (harness TEA migration, Phase 0): the `environment: :harness`
  Lifecycle profile.

  Contract under test (docs/proposals/in-flight/harness-tea-migration.md §3):

  * children -- Dispatcher + rendering Engine + terminal output backend,
    NO terminal input Driver (the harness SessionPump owns stdin via its
    own InlineDriver) and NO plugin manager;
  * byte-quiet boot -- booting the Lifecycle writes NOTHING: no alt-screen
    enter/leave, no screen clear, no capability probe, and no spontaneous
    first frame. The pump owns alt-screen enter-before-first-frame and
    leave-as-last-byte, so the runtime must never paint until a frame is
    requested;
  * the first requested frame renders through the real pipeline
    (view -> Preparer -> LayoutEngine -> UIRenderer -> ScreenBuffer ->
    terminal backend) to the injected device, as a keyframe whose leading
    `\\e[2J` belongs to the FRAME (it composes with an already-entered alt
    screen) -- and subsequent unchanged frames emit zero bytes (the
    incremental row-diff vocabulary, not the ssh full-clear vocabulary);
  * DEC-2026 sync bracketing is boot-opt-in
    (`engine_start_opts: [sync_output: true]`), never probed at boot.

  Synchronization note: no sleeps. `Dispatcher.init/1` enqueues
  `{:runtime_initialized, _}` and `{:plugin_manager_ready, _}` into the
  Lifecycle's mailbox before `start_link/2` returns, so a
  `:get_full_state` call is processed after both; any boot-triggered
  render cast would already sit in the Engine's mailbox by then, and the
  follow-up `:get_buffer` call is processed after it. Every byte a boot
  could ever emit has therefore arrived in the test mailbox before
  `refute_received` runs.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Lifecycle

  defmodule F0EnvApp do
    @moduledoc false
    @behaviour Raxol.Core.Runtime.Application

    @impl true
    def init(_), do: %{}
    @impl true
    def update(_msg, model), do: {model, []}
    @impl true
    def view(_model), do: %{type: :text, content: "F0-ENV-FRAME"}
    @impl true
    def subscriptions(_model), do: []
  end

  defp boot(extra_opts \\ []) do
    test_pid = self()

    writer = fn bytes ->
      send(test_pid, {:tty, IO.iodata_to_binary(bytes)})
    end

    {:ok, lifecycle} =
      Lifecycle.start_link(
        F0EnvApp,
        [
          environment: :harness,
          io_writer: writer,
          width: 40,
          height: 10
        ] ++ extra_opts
      )

    # Serialize teardown between tests: await full termination (the
    # parent-exit contract tears the tree down when the test process
    # dies) so a late registry-table cleanup can't race the next boot.
    on_exit(fn ->
      ref = Process.monitor(lifecycle)
      Lifecycle.stop(lifecycle)
      assert_receive {:DOWN, ^ref, :process, _, _}, 10_000
    end)

    lifecycle
  end

  # Forces the Lifecycle to have processed both readiness messages and the
  # Engine to have processed anything boot enqueued at it. Deterministic:
  # after this returns, all boot-time output (if any) is in our mailbox.
  defp settle(lifecycle) do
    state = GenServer.call(lifecycle, :get_full_state)
    {:ok, _buffer} = GenServer.call(state.rendering_engine_pid, :get_buffer)
    state
  end

  defp stop_and_await(lifecycle) do
    ref = Process.monitor(lifecycle)
    Lifecycle.stop(lifecycle)
    assert_receive {:DOWN, ^ref, :process, _, _}, 10_000
  end

  describe "profile composition" do
    test "starts Dispatcher + Engine, skips input driver and plugin manager" do
      lifecycle = boot()
      state = GenServer.call(lifecycle, :get_full_state)

      assert is_pid(state.dispatcher_pid)
      assert is_pid(state.rendering_engine_pid)
      assert state.driver_pid == nil
      assert state.plugin_manager == nil

      # Supervision-tree shape: the render-path children are linked
      # children of the Lifecycle (started from its init/1).
      {:links, links} = Process.info(lifecycle, :links)
      assert state.dispatcher_pid in links
      assert state.rendering_engine_pid in links

      # The Engine runs the :harness profile, sync bracket off by default.
      engine = GenServer.call(state.rendering_engine_pid, {:get_state})
      assert engine.environment == :harness
      assert engine.sync_output == false

      # No global registered name: the pump reaches everything by pid.
      assert Process.info(lifecycle, :registered_name) ==
               {:registered_name, []}
    end

    test "two :harness lifecycles for the same app coexist" do
      a = boot()
      b = boot()

      assert Process.alive?(a)
      assert Process.alive?(b)

      state_a = GenServer.call(a, :get_full_state)
      state_b = GenServer.call(b, :get_full_state)
      assert state_a.dispatcher_pid != state_b.dispatcher_pid
    end
  end

  describe "byte-quiet boot" do
    test "boot emits zero bytes to the device before a frame is requested" do
      lifecycle = boot()
      settle(lifecycle)

      refute_received {:tty, _}
    end

    test "boot never emits alt-screen/clear control bytes to stdout" do
      # No io_writer here: this pins the bare-IO.write deployment path
      # (Engine group leader inherited from the boot caller).
      captured =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, lifecycle} =
            Lifecycle.start_link(F0EnvApp,
              environment: :harness,
              width: 40,
              height: 10
            )

          state = GenServer.call(lifecycle, :get_full_state)

          {:ok, _} =
            GenServer.call(state.rendering_engine_pid, :get_buffer)

          stop_and_await(lifecycle)
        end)

      refute captured =~ "\e[?1049"
      refute captured =~ "\e[?47"
      refute captured =~ "\e[2J"
      refute captured =~ "\e[3J"
      refute captured =~ "\e[H"
      refute captured =~ "\e[?2026"
    end

    test "alternate_screen option cannot make :harness touch the device" do
      # The pump owns \e[?1049h (enter-before-first-frame) and \e[?1049l
      # (leave-as-last-byte). Even explicitly opting the Lifecycle into
      # alt-screen management must stay mute on this profile -- enter at
      # boot AND leave at terminate.
      lifecycle = boot(alternate_screen: true)
      settle(lifecycle)
      refute_received {:tty, _}

      stop_and_await(lifecycle)
      refute_received {:tty, _}
    end
  end

  describe "rendering to the device" do
    test "first requested frame renders through the Engine as a keyframe" do
      lifecycle = boot()
      state = settle(lifecycle)
      refute_received {:tty, _}

      assert :ok =
               GenServer.call(state.rendering_engine_pid, :render_frame_sync)

      assert_receive {:tty, frame}
      assert frame =~ "F0-ENV-FRAME"

      # The keyframe clear belongs to the frame itself -- it composes with
      # the alt screen the pump already entered. Never an alt-screen or
      # sync-bracket byte from the runtime without opt-in.
      assert String.starts_with?(frame, "\e[2J")
      refute frame =~ "\e[?1049"
      refute frame =~ "\e[?2026"
    end

    test "an unchanged second frame emits zero bytes (incremental diff)" do
      lifecycle = boot()
      state = settle(lifecycle)

      assert :ok =
               GenServer.call(state.rendering_engine_pid, :render_frame_sync)

      assert_receive {:tty, first}
      assert first =~ "F0-ENV-FRAME"

      assert :ok =
               GenServer.call(state.rendering_engine_pid, :render_frame_sync)

      assert_receive {:tty, second}
      assert second == ""
    end

    test "DEC-2026 sync bracket is boot-opt-in, never probed" do
      lifecycle = boot(engine_start_opts: [sync_output: true])
      state = settle(lifecycle)

      # Opting in must not add boot bytes either.
      refute_received {:tty, _}

      assert :ok =
               GenServer.call(state.rendering_engine_pid, :render_frame_sync)

      assert_receive {:tty, "\e[?2026h"}
      assert_receive {:tty, frame}
      assert frame =~ "F0-ENV-FRAME"
      assert_receive {:tty, "\e[?2026l"}
    end
  end
end
