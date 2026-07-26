defmodule Raxol.Terminal.InlineDriverTest do
  @moduledoc """
  Unit T2d GenServer-level tests (`Raxol.Terminal.InlineDriver`). Tier A:
  Oracle A (byte capture via an injected `StringIO` device) with no pty
  and no termbox. The full exit-class matrix + pty-dependent facts (real
  SIGTERM, kernel stty residual, $EDITOR/SIGTSTP handoff -- T25's unit,
  not this one) live in `test/harness/t2d_teardown_positive_test.exs` and
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

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{type: :key, data: %{char: "a"}}},
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

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{type: :key, data: %{char: "q"}}},
                     1_000

      Port.close(port)
      GenServer.stop(pid)
    end

    test "raw_sink receives the PRE-parse chunk verbatim, alongside the parsed event",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          raw_sink: self(),
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      chunk = "a\e[A"
      send(pid, {:trace, self(), :send, {make_ref(), {:data, chunk}}, self()})

      # The raw chunk arrives exactly as read, before parsing split it.
      assert_receive {:inline_raw_input, ^chunk}, 1_000
      # And the parsed event path is unchanged.
      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{type: :key, data: %{char: "a"}}},
                     1_000

      GenServer.stop(pid)
    end

    test "no raw_sink (the default): no raw message is ever sent", %{sio: sio} do
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

      assert_receive {:inline_input, _event}, 1_000
      refute_received {:inline_raw_input, _chunk}

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

  # A bracketed paste that spans more than one OS read chunk must still
  # reach the subscriber as ONE atomic :paste event -- never fragmented
  # into raw key events. The disease this rules out: the paste tail
  # re-parsed as keystrokes, where a pasted CR (`\r`) becomes an :enter
  # (a spurious SUBMIT), a pasted TAB becomes a :tab (a spurious steer),
  # and a pasted ESC becomes an :escape (a spurious interrupt). See
  # `InputParser`'s stateless-per-chunk contract and the driver's paste
  # reassembly buffer.
  describe "bracketed paste reassembly across read chunks" do
    setup %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false
        )

      %{pid: pid}
    end

    defp feed_chunk(pid, data),
      do:
        send(pid, {:trace, self(), :send, {make_ref(), {:data, data}}, self()})

    test "a paste split mid-body (before its first newline) does not submit",
         %{pid: pid} do
      # The split lands right before the first CR -- the exact boundary that,
      # unbuffered, parses the tail's `\r` as :enter and submits the draft.
      feed_chunk(pid, "\e[200~line one")
      feed_chunk(pid, "\rline two\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "line one\rline two"}
                      }},
                     1_000

      # No stray key events (no :enter/:tab/:key) leaked from the paste body.
      refute_received {:inline_input, %Raxol.Core.Events.Event{type: :key}}

      GenServer.stop(pid)
    end

    test "a paste split across three chunks reassembles whole", %{pid: pid} do
      feed_chunk(pid, "\e[200~alpha\t")
      feed_chunk(pid, "beta\r\n")
      feed_chunk(pid, "gamma\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "alpha\tbeta\r\ngamma"}
                      }},
                     1_000

      refute_received {:inline_input, %Raxol.Core.Events.Event{type: :key}}

      GenServer.stop(pid)
    end

    test "real key events before an unterminated paste still flush immediately",
         %{pid: pid} do
      # A keystroke ahead of a paste open in the same chunk must not be held
      # hostage by the pending paste tail.
      feed_chunk(pid, "a\e[200~partial")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{type: :key, data: %{char: "a"}}},
                     1_000

      feed_chunk(pid, " rest\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "partial rest"}
                      }},
                     1_000

      GenServer.stop(pid)
    end

    test "a single-chunk paste is unaffected (no regression)", %{pid: pid} do
      feed_chunk(pid, "\e[200~whole\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "whole"}
                      }},
                     1_000

      GenServer.stop(pid)
    end

    test "a torn OPEN marker split across chunks does not leak bytes or fire :enter",
         %{pid: pid} do
      # The open marker's OWN bytes are torn mid-sequence: chunk1 ends
      # "...\e[20", chunk2 begins "0~...". Unbuffered, chunk1's tail is not
      # a complete 6-byte marker at all, so `unterminated_open/1` saw zero
      # opens and let it all through as raw keystrokes; chunk2 then arrived
      # with no memory of the split, so "\e[200~" never re-formed and the
      # embedded `\r` fired :enter (a spurious SUBMIT) with "rm -rf"
      # following as ordinary keys a shell-like consumer would execute.
      feed_chunk(pid, "x\e[20")
      feed_chunk(pid, "0~evil\rrm -rf\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :key,
                        data: %{char: "x"}
                      }},
                     1_000

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "evil\rrm -rf"}
                      }},
                     1_000

      # No stray key events (in particular no spurious :enter) leaked from
      # the paste body or the torn marker's bytes -- "x"'s event above is
      # already consumed by the assert_receive, so this catches anything
      # else.
      refute_received {:inline_input, %Raxol.Core.Events.Event{type: :key}}

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # The event-clocked isig guard (the real-terminal ^C trap):
  # prim_tty can re-own the termios with ISIG on at times no boot-window
  # poll can bound, so the driver re-checks the LIVE flags every
  # `isig_guard_every` input chunks (event-clocked -- no wall-time
  # timer), re-asserts raw! on a flip, and tells the subscriber so an
  # embedder can render an honest notice.
  # ---------------------------------------------------------------------

  describe "event-clocked isig guard" do
    defp feed(pid, n) do
      for _ <- 1..n do
        send(pid, {:trace, self(), :send, {make_ref(), {:data, "x"}}, self()})
      end
    end

    test "re-asserts are silent janitorial work — counted, never announced (the SIGINT trap owns ^C)",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          isig_guard_every: 3,
          # ISIG reads ON at every guard check (the prim_tty flip-war's
          # steady state on some hosts — it wins any stty race). Not
          # news: ^C reaches the subscriber via the trapped-signal path
          # regardless, so NO round ever notifies — the counter alone
          # records the churn (the first-N-threshold approach failed
          # exactly here in the field: round 2 was still noise).
          isig_flags_reader: fn -> false end
        )

      calls_before = Enum.count(InlineDriverMockStty.calls(), &(&1 == {:raw!}))

      feed(pid, 3)
      refute_receive {:inline_isig_reasserted}, 300

      assert Enum.count(InlineDriverMockStty.calls(), &(&1 == {:raw!})) >
               calls_before

      feed(pid, 3)
      refute_receive {:inline_isig_reasserted}, 300

      # The report goes through the REAL GenServer call path (regression:
      # a clause defined below the module's catch-all was unreachable and
      # returned {:error, :not_implemented} to the demo's POST line).
      report = InlineDriver.isig_report(pid)
      assert report.reasserts == 2
      assert report.isig_off? == false
      assert is_boolean(report.boot_confirmed?)

      GenServer.stop(pid)
    end

    test "a healthy tty (isig already off) is never re-asserted and never notified",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          isig_guard_every: 2,
          isig_flags_reader: fn -> true end
        )

      calls_before = Enum.count(InlineDriverMockStty.calls(), &(&1 == {:raw!}))

      feed(pid, 6)
      refute_receive {:inline_isig_reasserted}, 300

      assert Enum.count(InlineDriverMockStty.calls(), &(&1 == {:raw!})) ==
               calls_before

      GenServer.stop(pid)
    end

    test "guard off by default when readerless: no flags reads on the input path",
         %{sio: sio} do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          isig_flags_reader: fn -> raise "flags reader must not run" end
        )

      feed(pid, 8)
      refute_receive {:inline_isig_reasserted}, 200
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "the wall-clock floor bounds stty re-asserts under a burst (no fork-per-chunk)",
         %{sio: sio} do
      # `isig_guard_every: 1` is due on every chunk, but a real (stty-forking)
      # re-assert must not fire per byte: a fast paste / key-repeat delivers a
      # burst of chunks, and forking a subprocess each one serializes input
      # behind subprocess latency (and lets a flood amplify into unbounded
      # spawns). With a large wall-clock floor, a 20-chunk burst re-asserts at
      # most ONCE (the first), not 20 times. `isig_flags_reader: false` = ISIG
      # reads on, so every guard that actually runs re-asserts.
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          isig_guard_every: 1,
          isig_guard_interval_ms: 10_000,
          isig_flags_reader: fn -> false end
        )

      feed(pid, 20)

      # isig_report/1 is a GenServer call: it barriers behind all 20 chunks.
      assert InlineDriver.isig_report(pid).reasserts <= 1

      GenServer.stop(pid)
    end

    test "with the floor disabled (interval 0) the guard runs every chunk — pre-fix cost documented",
         %{sio: sio} do
      # The teeth for the test above: same burst, floor off, one fork PER chunk.
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: true,
          stty: InlineDriverMockStty,
          install_reader?: false,
          probe?: false,
          isig_guard_every: 1,
          isig_guard_interval_ms: 0,
          isig_flags_reader: fn -> false end
        )

      feed(pid, 5)

      assert InlineDriver.isig_report(pid).reasserts == 5

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # A held SHORT paste-open prefix (a lone ESC, or a torn `ESC[200~` head)
  # is far more often the Escape key or a torn CSI than a real paste. It is
  # buffered in `paste_pending` awaiting the marker's completion; without a
  # deadline it stays hostage until the NEXT keystroke arrives, so `:escape`
  # never fires on its own. The flush deadline releases it.
  # ---------------------------------------------------------------------
  describe "held paste-open prefix flush deadline" do
    defp start_flush_driver(sio, flush_ms) do
      {:ok, pid} =
        InlineDriver.start_link(
          device: sio,
          subscriber: self(),
          tty?: false,
          stty_enabled?: false,
          install_reader?: false,
          probe?: false,
          paste_flush_ms: flush_ms
        )

      pid
    end

    test "a lone ESC flushes to :escape after the deadline with no following keystroke",
         %{sio: sio} do
      pid = start_flush_driver(sio, 15)

      feed_chunk(pid, "\e")

      # Barrier: the ESC chunk is processed and held, nothing parsed yet.
      :sys.get_state(pid)
      refute_received {:inline_input, _}

      # Fires on its own once the idle deadline elapses.
      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :key,
                        data: %{key: :escape}
                      }},
                     1_000

      GenServer.stop(pid)
    end

    test "the held ESC fires exactly once (no stale-timer double-fire)",
         %{sio: sio} do
      pid = start_flush_driver(sio, 15)

      feed_chunk(pid, "\e")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{data: %{key: :escape}}},
                     1_000

      refute_receive {:inline_input, _}, 60

      GenServer.stop(pid)
    end

    test "a genuine multi-chunk paste is never fragmented by the deadline",
         %{sio: sio} do
      # The open marker + content is longer than the marker, so it is NOT a
      # flushable prefix: the deadline must leave the reassembly untouched
      # even across a gap wider than the flush window.
      pid = start_flush_driver(sio, 10)

      feed_chunk(pid, "\e[200~hello")
      # Wait well past the flush deadline before the close arrives.
      Process.sleep(40)
      feed_chunk(pid, "world\e[201~")

      assert_receive {:inline_input,
                      %Raxol.Core.Events.Event{
                        type: :paste,
                        data: %{text: "helloworld"}
                      }},
                     1_000

      # No spurious :escape or key leaked from the held bytes.
      refute_received {:inline_input, %Raxol.Core.Events.Event{type: :key}}

      GenServer.stop(pid)
    end
  end
end
