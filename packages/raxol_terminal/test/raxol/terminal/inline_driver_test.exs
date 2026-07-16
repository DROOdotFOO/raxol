defmodule Raxol.Terminal.InlineDriverTest do
  @moduledoc """
  Unit T2d GenServer-level tests (`Raxol.Terminal.InlineDriver`). Tier A of
  `harness-ui-testing/03-lifecycle.md`: Oracle A (byte capture via an
  injected `StringIO` device) with no pty and no termbox. The full
  exit-class matrix + pty-dependent facts (real SIGTERM, kernel stty
  residual, $EDITOR/SIGTSTP handoff -- T25's unit, not this one) live in
  `test/harness/t2d_teardown_positive_test.exs` and
  `t2d_teardown_negative_test.exs`.

  `async: false`: `Raxol.Terminal.Capabilities` caches into
  `:persistent_term`, which is process-global.
  """

  use ExUnit.Case, async: false

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.InlineDriver
  alias Raxol.Test.InlineDriverMockStty

  setup do
    Capabilities.reset_cache()
    {:ok, _} = InlineDriverMockStty.start_link()

    on_exit(fn ->
      Capabilities.reset_cache()
      InlineDriverMockStty.stop()
    end)

    {:ok, sio} = StringIO.open("")
    %{sio: sio}
  end

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  # A ready-made %State{} for testing emit_teardown/2 directly, without a
  # GenServer -- exactly the pure seam the suite design calls for.
  defp state(overrides) do
    struct(
      %InlineDriver.State{
        device: :stdio,
        stty_module: InlineDriverMockStty,
        stty_enabled?: true,
        rows: 24
      },
      overrides
    )
  end

  describe "init -- LC-P-NOALT" do
    test "writes init bytes with no 1049h", %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      # init_manager runs synchronously before start_link returns, so the
      # bytes are already in the StringIO by the time we get here.
      output = contents(sio)
      refute output =~ "\e[?1049h"
      assert output =~ "\e[?1004h"
      assert output =~ "\e[?2004h"

      GenServer.stop(pid)
    end

    test "does not touch the injected stty module when stty_enabled? is false",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      assert InlineDriverMockStty.calls() == []
      GenServer.stop(pid)
    end

    test "saves + enters raw mode via the injected stty module when enabled",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false
        )

      assert [{:save}, {:raw!}] = InlineDriverMockStty.calls()
      GenServer.stop(pid)
    end

    test "capabilities opt skips the probe and caches the record directly", %{
      sio: sio
    } do
      caps = %Capabilities{tier: :rich, sync_output: true}

      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          capabilities: caps
        )

      assert Capabilities.cached() == {:ok, caps}
      assert Capabilities.sync_output?()
      GenServer.stop(pid)
    end

    test "probe?: false skips probing entirely (nothing cached)", %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      assert Capabilities.cached() == :error
      GenServer.stop(pid)
    end
  end

  describe "emit_teardown/2 -- the pure seam" do
    test "writes the canonical teardown sequence and restores stty", %{
      sio: sio
    } do
      st = state(device: sio, original_stty: "saved-settings")

      new_st = InlineDriver.emit_teardown(sio, st)

      output = contents(sio)
      assert output =~ "\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l"
      assert output =~ "\e[r"
      assert output =~ "\e[?7h\e[?25h"
      assert output =~ "\e[24;1H\r\n"
      assert new_st.torn_down? == true

      assert [{:restore, "saved-settings"}] = InlineDriverMockStty.calls()
    end

    test "LC-P-CSIR: contains CSI r (the canonical order's release-region step)",
         %{sio: sio} do
      st = state(device: sio)
      InlineDriver.emit_teardown(sio, st)
      assert contents(sio) =~ "\e[r"
    end

    test "LC-N-DOUBLE: idempotent -- a torn-down state is returned unchanged and writes nothing",
         %{sio: sio} do
      st = state(device: sio, original_stty: "saved-settings")

      st = InlineDriver.emit_teardown(sio, st)
      first_output = contents(sio)

      st2 = InlineDriver.emit_teardown(sio, st)
      second_output = contents(sio)

      assert st2 == st
      assert second_output == first_output
      # only ONE restore call -- no double stty invocation
      assert [{:restore, "saved-settings"}] = InlineDriverMockStty.calls()
    end

    test "safe when no scroll region was ever set (T2d sets none -- that's T2a's job)",
         %{sio: sio} do
      # T2d never issues CSI ? r itself to set a non-default region; CSI r
      # (no params) resets to the full screen either way, so emitting it
      # here is a documented no-op, not a hazard.
      st = state(device: sio)
      new_st = InlineDriver.emit_teardown(sio, st)
      assert new_st.torn_down?
      assert contents(sio) =~ "\e[r"
    end

    test "respects stty_enabled?: false (no stty calls at all)", %{sio: sio} do
      st = state(device: sio, stty_enabled?: false)
      InlineDriver.emit_teardown(sio, st)
      assert InlineDriverMockStty.calls() == []
    end
  end

  describe "terminate/2 -- exit classes" do
    test "LC-P-CLEAN: graceful GenServer.stop emits full teardown", %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: true,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          rows: 30
        )

      InlineDriverMockStty.stop()
      {:ok, _} = InlineDriverMockStty.start_link()

      :ok = GenServer.stop(pid, :normal)

      output = contents(sio)
      assert output =~ "\e[r"
      assert output =~ "\e[30;1H\r\n"
      assert [{:restore, _}] = InlineDriverMockStty.calls()
    end

    test "LC-P-CRASH: terminate/2 emits full teardown regardless of reason",
         %{sio: sio} do
      # `:gen_server` invokes `terminate/2` with whatever reason killed the
      # process -- `:normal`, `:shutdown`, or the exception a crashed
      # callback raised -- and this is orthogonal to `trap_exit` (that flag
      # only gates *external* exit signals; a callback's own raise always
      # reaches this process's own terminate/2). Driving `terminate/2`
      # directly with an exception-shaped reason is the deterministic way
      # to prove it does not special-case the happy path.
      state = %InlineDriver.State{
        device: sio,
        stty_module: InlineDriverMockStty,
        stty_enabled?: true,
        rows: 24
      }

      assert :ok = InlineDriver.terminate(%RuntimeError{message: "boom"}, state)

      output = contents(sio)
      assert output =~ "\e[r"
      assert output =~ "\e[?7h\e[?25h"
      assert [{:restore, nil}] = InlineDriverMockStty.calls()
    end
  end

  describe "init crash safety -- raw mode must not be left stranded" do
    test "a raise after raw!() (e.g. a bad probe option) is rescued: init fails but the tty is restored",
         %{sio: sio} do
      # `probe_opts: [budget_ms: "boom"]` reaches `Probe.step(probe,
      # :start)`'s `p.now0 + p.budget_ms` with a non-numeric budget,
      # raising `ArithmeticError` from deep inside `maybe_run_probe/3` --
      # well after `stty.raw!()` (and the init-bytes write) has already
      # run. Without the init_manager/1 try/rescue this would strand the
      # tty raw with no restore at all.
      #
      # Called directly (not via `start_link/1`): a raise inside a
      # GenServer's own `init/1` is NOT the same as an `{:error, _}`
      # return -- `:gen_server`/`:proc_lib` still crash the (linked) new
      # process, and that crash's EXIT signal reaches the caller too
      # (unless it traps exits), which would take this test process down
      # with it. Calling `init_manager/1` as a plain function isolates
      # exactly the code path this fix changes, with none of that OTP
      # linking machinery in the way.
      opts = [
        device: sio,
        tty?: true,
        stty_enabled?: true,
        stty: InlineDriverMockStty,
        install_reader?: false,
        probe?: true,
        probe_opts: [budget_ms: "boom"]
      ]

      assert_raise ArithmeticError, fn ->
        InlineDriver.init_manager(opts)
      end

      # save + raw! happened (the tty WAS put in raw mode) and, crucially,
      # restore ran too -- with the very settings save/0 captured, not a
      # bare `sane!` fallback -- proving the tty was not left stranded.
      assert [{:save}, {:raw!}, {:restore, "mock-original-settings"}] =
               InlineDriverMockStty.calls()
    end
  end

  describe "input dispatch" do
    test "trace-shaped input messages are parsed and forwarded to the subscriber",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      send(pid, {:trace, self(), :send, {make_ref(), {:data, "a"}}, self()})

      assert_receive {:inline_input, %Raxol.Core.Events.Event{type: :key, data: %{char: "a"}}},
                     1_000

      GenServer.stop(pid)
    end

    @tag :unix_only
    test "port-shaped input messages are parsed and forwarded too", %{
      sio: sio
    } do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      port = Port.open({:spawn, "cat"}, [:binary])

      send(pid, {port, {:data, "q"}})

      assert_receive {:inline_input, %Raxol.Core.Events.Event{type: :key, data: %{char: "q"}}},
                     1_000

      Port.close(port)
      GenServer.stop(pid)
    end

    test "no subscriber: input is parsed and silently dropped, no crash", %{
      sio: sio
    } do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      send(pid, {:trace, self(), :send, {make_ref(), {:data, "z"}}, self()})
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
