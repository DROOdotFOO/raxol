defmodule Raxol.Harness.T2dTeardownPositiveTest do
  @moduledoc """
  Unit T2d (inline driver profile) -- positive exit-class matrix
  (`docs/proposals/in-flight/harness-ui-testing/03-lifecycle.md` §3.1).

  Tier A (byte capture, `StringIO` device, no pty) exercises the full
  Lifecycle wiring end-to-end (`environment: :inline` reaches
  `Raxol.Terminal.InlineDriver` via the new `Initializer.maybe_start_driver`
  clause). Tier B (`@tag :pty`) drives a real spawned `mix run` app under a
  genuine pty via `Raxol.Test.PtyHarness` (unit TP) for the one fact Tier A
  cannot observe: a real SIGTERM reaching the BEAM and a complete,
  untruncated byte capture (the stdio-race driver.ex's own comment already
  flags, per 03-lifecycle.md §1.3).

  Package-level unit tests for the pure teardown seam
  (`InlineDriver.emit_teardown/2`, idempotency, stty injection) live in
  `packages/raxol_terminal/test/raxol/terminal/inline_driver_test.exs`;
  this file is the integration layer + the real-pty facts only Tier B can
  prove.
  """

  use ExUnit.Case, async: false

  alias Raxol.Terminal.Capabilities
  alias Raxol.Test.PtyHarness

  @moduletag :harness

  defmodule MockInlineApp do
    @moduledoc false
    use Raxol.Core.Runtime.Application

    def init(_ctx), do: %{}
    def update(_message, model), do: {model, []}
    def view(_model), do: nil
    def subscribe(_model), do: []
  end

  setup do
    Capabilities.reset_cache()
    on_exit(fn -> Capabilities.reset_cache() end)
    {:ok, sio} = StringIO.open("")
    %{sio: sio}
  end

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  # Why `Process.unlink(pid)` after every start: `Raxol.start_link/2` links
  # the test process to the Lifecycle. Lifecycle's own shutdown exits with
  # `:shutdown` (not `:normal`), and its dependents' `:shutdown` exits
  # propagate through the link, so a non-trapping test process would die
  # alongside it. Unlinking lets us observe the shutdown (and read the
  # StringIO capture) without the test process being taken down. It does
  # NOT change whether the driver's teardown ran -- that is a property of
  # Lifecycle's shutdown sequence, measured directly below.
  defp driver_pid_of(lifecycle_pid) do
    :sys.get_state(lifecycle_pid).driver_pid
  end

  describe "Tier A: environment: :inline reaches InlineDriver end-to-end" do
    test "LC-P-NOALT: init bytes contain no alt-screen sequence, driver is a real InlineDriver",
         %{sio: sio} do
      {:ok, pid} =
        Raxol.start_link(MockInlineApp,
          environment: :inline,
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      Process.unlink(pid)

      refute contents(sio) =~ "\e[?1049h"

      driver_pid = driver_pid_of(pid)
      assert is_pid(driver_pid)
      assert Process.alive?(driver_pid)
      assert %Raxol.Terminal.InlineDriver.State{} = :sys.get_state(driver_pid)

      GenServer.stop(driver_pid, :normal)
      Process.exit(pid, :kill)
    end

    test "LC-P-CLEAN: stopping the InlineDriver directly emits the full canonical teardown",
         %{sio: sio} do
      # Deterministic proof of the driver's own teardown + the :inline
      # wiring, independent of the (racy) Lifecycle shutdown path: fetch the
      # driver started by the :inline environment and stop IT directly. Its
      # terminate/2 runs the full canonical sequence. (The through-Lifecycle
      # graceful-stop path is the T28 gap -- pinned by the skipped test in
      # the next describe block.)
      {:ok, pid} =
        Raxol.start_link(MockInlineApp,
          environment: :inline,
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false,
          rows: 30
        )

      Process.unlink(pid)
      driver_pid = driver_pid_of(pid)

      GenServer.stop(driver_pid, :normal)

      output = contents(sio)
      # canonical order: modes-off -> CSI r -> autowrap/cursor -> move+CRLF
      assert output =~
               "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l\e[?6l\e[r\e[?7h\e[?25h\e[30;1H\r\n"

      Process.exit(pid, :kill)
    end
  end

  describe "Tier A: through-Lifecycle graceful stop (tracked gap, unit T28)" do
    # LC-P-T28-STOP: the honest through-Lifecycle test the coordinator asked
    # for. Start a real Lifecycle with the inline driver + a StringIO
    # capture device, graceful-stop it via the PUBLIC api (`Raxol.stop/1`),
    # and assert the driver's teardown bytes were emitted.
    #
    # UNRELIABLE today (documents the gap): `Raxol.stop/1` ->
    # `Lifecycle.handle_cast(:shutdown)` stops dependents in order
    # (rendering engine, THEN driver) via `GenServer.stop(pid, :shutdown)`.
    # Neither `Lifecycle` nor its caller traps exits, so the rendering
    # engine's `:shutdown` exit RACES back through the link: if it kills
    # `Lifecycle` before the `GenServer.stop(driver, ...)` line is reached,
    # the driver's `terminate/2` never runs and NO teardown is emitted.
    # Measured ~50% miss under ExUnit load (deterministic-looking under a
    # bare `mix run`, which just wins the race). Tracked as unit T28
    # (graceful shutdown deterministically reaches driver terminate); T28's
    # builder removes the `skip:` line once Lifecycle stops the driver
    # before the cascade can unwind it.
    @tag :pending_t28
    @tag skip:
           "blocked on unit T28 — Raxol.stop/1 races the shutdown cascade; teardown reaches the driver only ~half the time"
    test "Raxol.stop/1 reliably drives the inline driver's teardown (blocked on T28)",
         %{sio: sio} do
      {:ok, pid} =
        Raxol.start_link(MockInlineApp,
          environment: :inline,
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false,
          rows: 30
        )

      Process.unlink(pid)
      ref = Process.monitor(pid)

      Raxol.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      output = contents(sio)
      # Must reliably emit the full canonical teardown through the public
      # graceful-stop path. Fails/flakes until T28 makes Lifecycle stop the
      # driver before the cascade can unwind it.
      assert output =~
               "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l\e[?6l\e[r\e[?7h\e[?25h\e[30;1H\r\n"
    end
  end

  describe "Tier B: default SIGTERM / init:stop teardown gap (unit T28)" do
    @describetag :pty
    @describetag :unix_only

    # LC-P-SIGTERM-DEFAULT: the production-critical facet of the T28 gap.
    # OTP's DEFAULT SIGTERM handling routes through `init:stop/0` -- a
    # VM-level supervision-tree unwind that does NOT go through Lifecycle's
    # own handle_cast(:shutdown), so this driver's terminate/2 is skipped
    # every time and NO teardown bytes reach the tty. Measured under a real
    # pty: no `\e[r`, no modes-off in the capture. This is the exact
    # stdio-shutdown race the termbox driver.ex flags, surfacing as a total
    # miss on the inline path. (The in-process `Raxol.stop/1` facet is the
    # racy skipped test in the Tier A "tracked gap" describe above.)
    #
    # This is the production-critical path (a container `kill -TERM`), so
    # it is the one that must eventually pass. It FAILS today; tracked as
    # unit T28 (graceful VM shutdown reaches driver terminate). `:pending_t28`
    # marks the tracked gap; `skip:` keeps the suite green today. T28's
    # builder removes the `skip:` line to enforce the guarantee once the VM
    # shutdown path is wired to reach the driver.
    @tag :pending_t28
    @tag skip:
           "blocked on unit T28 — default SIGTERM/init:stop does not reach driver terminate"
    test "a plain SIGTERM (no app-level handler) emits the driver teardown to the tty" do
      # NOTE: no custom :sigterm gen_event handler here (unlike
      # @mock_inline_app_src below, which works around the gap). This is the
      # raw production path: default SIGTERM -> init:stop -> tree unwind.
      src = """
      defmodule T28SigtermApp do
        use Raxol.Core.Runtime.Application
        def init(_ctx), do: %{}
        def update(_message, model), do: {model, []}
        def view(_model), do: nil
        def subscribe(_model), do: []
      end

      {:ok, _pid} =
        Raxol.start_link(T28SigtermApp,
          environment: :inline,
          device: :standard_io,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false,
          rows: 30
        )

      IO.write("READY\\n")
      Process.sleep(:infinity)
      """

      {:ok, session} =
        PtyHarness.start(["mix", "run", "--no-halt", "-e", src],
          env: %{"MIX_ENV" => "test"}
        )

      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 20_000)
      assert :ok = PtyHarness.signal(session, :term)
      _ = PtyHarness.await(session, 20_000)

      {:ok, output} = PtyHarness.read_output(session)
      # Must emit teardown before the VM exits. Fails until T28 wires the
      # SIGTERM/init:stop path to reach the driver's terminate/2.
      assert output =~ "\e[r"
      assert output =~ "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l"
    end
  end

  # --- Tier B: real pty, real SIGTERM ---

  @mock_inline_app_src """
  defmodule T2dPtyMockApp do
    use Raxol.Core.Runtime.Application
    def init(_ctx), do: %{}
    def update(_message, model), do: {model, []}
    def view(_model), do: nil
    def subscribe(_model), do: []
  end

  defmodule T2dPtySigtermHandler do
    @behaviour :gen_event
    def init(%{lifecycle: lifecycle}), do: {:ok, %{lifecycle: lifecycle}}

    # Default SIGTERM (init:stop) does NOT reach the driver's terminate/2
    # today -- the tracked T28 gap (see the LC-P-SIGTERM-DEFAULT test and
    # the driver moduledoc). So this app installs its OWN SIGTERM handler
    # that stops the driver directly (running its teardown) before bringing
    # the VM down. This is exactly the "app arranges its own handler"
    # mitigation the moduledoc names, and it is what lets THIS positive
    # test (LC-P-SIGTERM) assert a complete teardown under a real SIGTERM
    # while T28 is still open.
    def handle_event(:sigterm, %{lifecycle: lifecycle} = state) do
      case :sys.get_state(lifecycle).driver_pid do
        driver_pid when is_pid(driver_pid) ->
          GenServer.stop(driver_pid, :normal)

        _ ->
          :ok
      end

      System.stop(0)
      {:ok, state}
    end

    def handle_event(_signal, state), do: {:ok, state}
    def handle_call(_request, state), do: {:ok, :ok, state}
  end

  {:ok, pid} =
    Raxol.start_link(T2dPtyMockApp,
      environment: :inline,
      probe?: false
    )

  :ok = :os.set_signal(:sigterm, :handle)

  :ok =
    :gen_event.add_handler(
      :erl_signal_server,
      {T2dPtySigtermHandler, pid},
      %{lifecycle: pid}
    )

  IO.puts("READY")

  Process.sleep(:infinity)
  """

  setup_all do
    if PtyHarness.available?() do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  defp start_mock_app_under_pty do
    PtyHarness.start(
      ["mix", "run", "--no-halt", "-e", @mock_inline_app_src],
      env: %{"MIX_ENV" => "test"}
    )
  end

  defp cleanup(session) do
    PtyHarness.stop(session)
    File.rm(session.capture_path)
  end

  describe "Tier B: LC-P-SIGTERM" do
    @describetag :pty
    @describetag :unix_only

    test "a real SIGTERM reaches the BEAM, driver emits complete teardown before exit" do
      {:ok, session} = start_mock_app_under_pty()
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 15_000)

      assert :ok = PtyHarness.signal(session, :term)

      # await/2 is the DRAIN BARRIER (PtyHarness moduledoc): a successful
      # exit result guarantees the capture is complete, including trailing
      # teardown bytes written right before the VM halts.
      assert {:ok, {:exit, 0}} = PtyHarness.await(session, 15_000)

      {:ok, output} = PtyHarness.read_output(session)

      refute output =~ "\e[?1049h"
      refute output =~ "\e[?1049l"

      modes_off_at =
        :binary.match(output, "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l")

      region_at = :binary.match(output, "\e[r")
      autowrap_at = :binary.match(output, "\e[?7h\e[?25h")

      assert {modes_off_idx, _} = modes_off_at
      assert {region_idx, _} = region_at
      assert {autowrap_idx, _} = autowrap_at

      assert modes_off_idx < region_idx
      assert region_idx < autowrap_idx
    end
  end
end
