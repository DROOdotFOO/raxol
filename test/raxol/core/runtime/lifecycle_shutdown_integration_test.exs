defmodule Raxol.Core.Runtime.LifecycleShutdownIntegrationTest do
  @moduledoc """
  T28a (Facet 1): on graceful stop, the Terminal Driver's terminate/2 must
  actually run (mode reset, scroll-region reset, stty restore), and it must
  run BEFORE the rendering engine and the rest of the process tree are torn
  down.

  Confirmed diagnosis (T2d review, quoted precisely):
    (a) Lifecycle start_links every child from its init/1, so children are
        LINKED to Lifecycle, and Lifecycle did NOT trap exits.
    (b) Lifecycle.terminate/2 -> terminate_manager stopped ONLY plugin_manager
        + registry, never driver_pid.
    (c) The only driver stop was handle_cast(:shutdown), one line AFTER
        stop_process(rendering_engine_pid) -- stop_process does
        GenServer.stop(pid, :shutdown), whose :shutdown link signal killed
        the non-trapping Lifecycle BEFORE the driver's own stop_process call
        ran -> driver orphaned, terminate never fired. Measured ~50% miss
        under ExUnit load (a RACE, not a deterministic miss).

  The fix: trap exits + move the full child teardown into terminate/2 as the
  single source of truth for shutdown ordering (driver FIRST), reached
  identically whether triggered by our own :shutdown cast, an external
  abnormal exit signal, or a genuine child crash.

  Two describe blocks:

  * "graceful shutdown ordering" -- reachability + driver-first ordering via
    lightweight recording doubles (the `:driver_module`/`:engine_module` test
    seam in `Raxol.Core.Runtime.Lifecycle.Initializer`), plus a
    many-iterations determinism sweep (the bug was a race, so one green run
    isn't proof).

  * "trap_exit contract" -- the safety net for what trap_exit itself risks:
    a genuine child CRASH must still die-together AND propagate the crash
    reason verbatim (supervisor-restart semantics), while ALSO running the
    driver teardown on the crash path (Opus addition -- pins
    teardown-on-crash as intended, not incidental); a `:normal` NON-parent
    peer exit must NOT take Lifecycle down (unchanged from the untrapped
    process); the start_link PARENT exiting now brings Lifecycle down
    gracefully with teardown (the one intended trap_exit change -- gen_server
    dies with its parent, and we clean up first); and terminate/2 over
    nil/already-dead child pids must be an idempotent no-op.

  NOTE: Facet 2 (default SIGTERM/`:init.stop/0` never reaches an unsupervised
  Lifecycle) and its opt-in SIGTERM handler were SPLIT OUT to T28b after the
  triad review found a deadlock in the handler. This file is Facet 1 only.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Application
  alias Raxol.Core.Runtime.Lifecycle

  defmodule TestApp do
    @moduledoc false
    @behaviour Application

    @impl Application
    def init(_), do: %{}
    @impl Application
    def update(_msg, model), do: {model, []}
    @impl Application
    def view(_model), do: %{type: :text, content: "T28"}
    @impl Application
    def subscriptions(_model), do: []
  end

  # A recording double standing in for Raxol.Terminal.Driver. It doesn't
  # touch a real tty/termbox2 at all -- it just proves its terminate/2 was
  # reached, sending a bare tag to the recorder. Ordering between the driver
  # and the engine is asserted from the ARRIVAL SEQUENCE of these tags in the
  # recorder's mailbox, NOT from timestamps: Shutdown.stop_process/2 is a
  # synchronous GenServer.stop, so the driver's terminate/2 fully completes
  # (enqueueing its tag) before the engine is even asked to stop, and a local
  # send enqueues synchronously -- so :driver_terminated is strictly ahead of
  # :engine_terminated in the mailbox. Timestamps are unsafe here: a coarse
  # monotonic clock (Windows, ~15ms granularity) collapses two
  # microsecond-apart events to the SAME value, which broke a `<` assert in CI.
  defmodule RecordingDriver do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      recorder = Keyword.fetch!(opts, :recorder)
      GenServer.start_link(__MODULE__, recorder)
    end

    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}

    @impl true
    def handle_call(_msg, _from, state), do: {:reply, :ok, state}

    @impl true
    def terminate(_reason, recorder) do
      send(recorder, :driver_terminated)
      :ok
    end
  end

  # Same idea, standing in for Raxol.Core.Runtime.Rendering.Engine.
  defmodule RecordingEngine do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      recorder = Keyword.fetch!(opts, :recorder)
      GenServer.start_link(__MODULE__, recorder)
    end

    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}

    @impl true
    def handle_call(_msg, _from, state), do: {:reply, :ok, state}

    @impl true
    def terminate(_reason, recorder) do
      send(recorder, :engine_terminated)
      :ok
    end
  end

  setup_all do
    case start_supervised(Raxol.DynamicSupervisor) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {{:already_started, _pid}, _}} -> :ok
    end

    case start_supervised(Raxol.Terminal.Registry) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {{:already_started, _pid}, _}} ->
        :ok

      {:error, reason} ->
        raise "Failed to start Raxol.Terminal.Registry: #{inspect(reason)}"
    end

    if Process.whereis(:raxol_event_subscriptions) == nil do
      {:ok, _} =
        Registry.start_link(keys: :duplicate, name: :raxol_event_subscriptions)
    end

    case start_supervised(
           {Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "Failed to start Raxol.Core.UserPreferences: #{inspect(reason)}"
    end

    :ok
  end

  defp start_lifecycle(recorder) do
    Lifecycle.start_link(TestApp,
      environment: :terminal,
      name: :"t28_lifecycle_#{System.unique_integer([:positive])}",
      driver_module: RecordingDriver,
      driver_start_opts: [recorder: recorder],
      engine_module: RecordingEngine,
      engine_start_opts: [recorder: recorder]
    )
  end

  # Receives the next teardown event in MAILBOX ARRIVAL ORDER -- returns
  # :driver or :engine for whichever tag is next in the mailbox, ignoring
  # unrelated messages (e.g. the monitor :DOWN, which always arrives after
  # both teardowns since Lifecycle only exits once terminate/2 has fully
  # run). This is the platform-independent way to assert stop ORDER: the
  # sequence in which the tags land IS the order the children were stopped.
  # No clock, no timestamp deltas.
  defp next_teardown_event(timeout \\ 2_000) do
    receive do
      :driver_terminated -> :driver
      :engine_terminated -> :engine
    after
      timeout ->
        flunk("expected a teardown event (:driver/:engine) within #{timeout}ms")
    end
  end

  describe "graceful shutdown ordering (T28a / Facet 1)" do
    test "Lifecycle.stop/1 runs the driver's terminate/2 before the rendering engine's" do
      {:ok, pid} = start_lifecycle(self())
      # start_link links the caller (this test process) to Lifecycle. We
      # only want to observe it via monitor, not die if it exits abnormally.
      Process.unlink(pid)
      ref = Process.monitor(pid)

      Lifecycle.stop(pid)

      # Ordering asserted from ARRIVAL SEQUENCE (see next_teardown_event/1),
      # never timestamps. The first teardown tag to arrive must be the
      # driver's; the second the engine's.
      assert next_teardown_event() == :driver,
             "Terminal Driver's terminate/2 must run FIRST on graceful stop -- " <>
               "if it never ran it was orphaned when the untrapped exit signal " <>
               "from a sibling killed Lifecycle before the driver's stop_process " <>
               "call; if the engine ran first the driver-first ordering regressed."

      assert next_teardown_event() == :engine,
             "Rendering Engine's terminate/2 must run SECOND (after the driver)."

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "an external supervisor-style :shutdown exit signal also reaches the driver's terminate/2" do
      {:ok, pid} = start_lifecycle(self())
      Process.unlink(pid)
      ref = Process.monitor(pid)

      # Simulates what an OTP Supervisor does when tearing down a linked
      # child: a raw exit signal, NOT a call through our own Lifecycle.stop/1
      # cast API.
      Process.exit(pid, :shutdown)

      assert next_teardown_event() == :driver,
             "Terminal Driver's terminate/2 must run FIRST on an external " <>
               ":shutdown exit signal (e.g. supervisor teardown)."

      assert next_teardown_event() == :engine

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    # The pre-fix bug was a RACE (~50% miss under ExUnit load per the T2d
    # measurement), not a deterministic miss -- a single passing run above
    # doesn't rule out remaining flakiness. trap_exit removes the race by
    # construction (Lifecycle can no longer die from a sibling's exit
    # signal, full stop), so this should be 100% deterministic now. Prove
    # it empirically over many iterations rather than asserting it once.
    test "is deterministic across many repeated stop cycles (no residual raciness)" do
      for i <- 1..30 do
        {:ok, pid} = start_lifecycle(self())
        Process.unlink(pid)
        ref = Process.monitor(pid)

        Lifecycle.stop(pid)

        # Sequence-position ordering (platform-independent; no clock). The
        # driver tag must arrive before the engine tag, every iteration.
        assert next_teardown_event() == :driver,
               "iteration #{i}: driver did not tear down FIRST " <>
                 "(missed entirely -> the race is back; or engine-first -> " <>
                 "ordering regressed)"

        assert next_teardown_event() == :engine,
               "iteration #{i}: engine did not tear down SECOND"

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      end
    end
  end

  describe "trap_exit contract (T28a safety net)" do
    # THE #1 risk of adding trap_exit: it must NOT silently swallow a genuine
    # child crash. Pre-trap, an abnormal child exit killed Lifecycle (and the
    # whole tree) and a supervisor saw that reason and restarted. Post-trap,
    # we must preserve that EXACTLY -- the tree still dies, and the crash
    # reason still propagates verbatim as Lifecycle's own exit reason. This
    # test is red-if-broken (e.g. if the abnormal-EXIT clause ever regressed
    # to {:noreply, state}, Lifecycle would linger and the tree would survive
    # a crash it must not survive).
    #
    # Opus addition (double duty): also assert the DRIVER teardown ran on the
    # crash path. terminate/2 now performs the full driver-first teardown
    # before the crash reason propagates upward -- a deliberate behavioral
    # addition (bounded latency), pinned here so it can't silently regress.
    test "a genuine child CRASH dies-together, propagates the reason verbatim, AND runs driver teardown first" do
      {:ok, pid} = start_lifecycle(self())
      Process.unlink(pid)
      ref = Process.monitor(pid)

      # Reach in for a real child pid and crash it abnormally, exactly as an
      # unexpected fault would. The rendering engine is a sibling of the
      # driver; killing it abnormally is a genuine "a child died" event.
      state = :sys.get_state(pid)
      engine_pid = state.rendering_engine_pid
      assert is_pid(engine_pid) and Process.alive?(engine_pid)

      Process.exit(engine_pid, :boom)

      # (1) Driver teardown still ran despite the crash -- teardown-on-crash
      # is pinned, not incidental.
      assert_receive :driver_terminated,
                     2_000,
                     "driver teardown did NOT run on the crash path -- " <>
                       "terminate/2's driver-first sequence must run before the " <>
                       "crash reason propagates."

      # (2) The tree dies WITH the crash reason (supervisor-restart parity):
      # trap_exit must not swallow the crash into a benign stop.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason},
                     2_000,
                     "Lifecycle did not die on a child crash -- trap_exit must " <>
                       "not swallow abnormal child exits."

      assert reason == :boom,
             "crash reason must propagate verbatim (supervisor sees the same " <>
               "restart trigger as pre-trap), got: #{inspect(reason)}"
    end

    # Contract check (grok-composer, peer case): a linked NON-PARENT peer
    # exiting :normal must NOT take Lifecycle down. An untrapped process
    # silently drops a :normal exit signal from a link, so a :normal peer
    # exit never took the old Lifecycle down -- and must not take the new one
    # down either. This is exactly what the source-agnostic :normal
    # handle_info clause guarantees (a peer, unlike the parent, is dispatched
    # to handle_info and ignored).
    test "a linked NON-parent peer exiting :normal does NOT take Lifecycle down" do
      {:ok, pid} = start_lifecycle(self())
      Process.unlink(pid)
      ref = Process.monitor(pid)

      # A separate process that LINKS to the Lifecycle but is NOT its
      # start_link parent, then exits :normal.
      peer =
        spawn(fn ->
          Process.link(pid)

          receive do
            :please_exit_normal -> :ok
          end
        end)

      send(peer, :please_exit_normal)

      # Lifecycle must survive the peer's :normal exit.
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      assert Process.alive?(pid),
             "a :normal peer exit must not take Lifecycle down " <>
               "(matches the pre-trap_exit process, which drops :normal signals)"

      # cleanup
      Lifecycle.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    # Contract check (grok-composer, parent case): with trap_exit, the ONE
    # intended change is for the start_link PARENT. gen_server intercepts the
    # parent's EXIT (before handle_info) and terminates with that reason --
    # standard OTP "a gen_server dies with its parent". So a parent exit now
    # brings Lifecycle down GRACEFULLY through terminate/2, running the
    # driver-first teardown. Pre-trap the terminal was NOT restored on a
    # parent exit (linger on :normal, no-teardown death on crash); this is
    # the desired behavior for an owns-the-node caller. Pinned here so the
    # drift is documented AND tested, not silent.
    test "the start_link parent exiting brings Lifecycle down gracefully, running driver teardown" do
      test_pid = self()

      # A separate process becomes the start_link caller (parent), LINKED to
      # the Lifecycle. spawn (not spawn_link) so this test process is
      # insulated from it.
      parent =
        spawn(fn ->
          {:ok, pid} = start_lifecycle(test_pid)
          send(test_pid, {:lifecycle_started, pid})

          receive do
            :please_exit_normal -> :ok
          end

          # falls off the end -> exits :normal
        end)

      assert_receive {:lifecycle_started, pid}, 2_000
      ref = Process.monitor(pid)

      send(parent, :please_exit_normal)

      # The parent's exit must drive a GRACEFUL teardown: driver terminate/2
      # runs (terminal restored), then Lifecycle goes down.
      assert_receive :driver_terminated,
                     2_000,
                     "a parent exit must run the driver-first teardown " <>
                       "(a gen_server dies with its parent -- and we clean up first)."

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    # Idempotency: terminate/2's driver-first sequence must be a safe no-op
    # over nil and already-dead child pids (Shutdown.stop_process/2 guards
    # both), so a double-stop or a terminate reached after children already
    # died never raises.
    test "terminate/2 over nil and already-dead child pids is an idempotent no-op" do
      {:ok, dead} = Agent.start(fn -> :ok end)
      Agent.stop(dead)
      refute Process.alive?(dead)

      state = %Lifecycle.State{
        app_module: TestApp,
        app_name: :t28_idempotent,
        options: [environment: :terminal],
        driver_pid: dead,
        rendering_engine_pid: nil,
        dispatcher_pid: dead,
        plugin_manager: nil,
        command_registry_table: nil,
        alternate_screen: false
      }

      # Must not raise; returns :ok from terminate_manager.
      assert Lifecycle.terminate(:shutdown, state) == :ok
    end
  end
end
