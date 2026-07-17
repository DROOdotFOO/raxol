defmodule Raxol.Terminal.InlineDriver do
  @moduledoc """
  Inline driver profile (unit T2d,
  `docs/proposals/in-flight/harness-ui-roadmap.md`; suite design in
  `harness-ui-testing/03-lifecycle.md`).

  A sibling of `Raxol.Terminal.Driver`, not a replacement: today's driver
  enters the alternate screen at init (`\\e[?1049h`) and termbox owns the
  whole tty. This module never does either. It puts the tty in raw mode
  (no echo, no line buffering, no signal generation), runs T1's capability
  probe over the same input fd, and streams parsed key events to a
  subscriber -- all while leaving the terminal's native scrollback
  completely alone. T2b (printed-history append) and T2a (scroll-region
  manager) are separate units layered on top; this module sets no scroll
  region itself.

  ## Constructor options

    * `:dispatcher_pid` -- the default subscriber for parsed input events
      (see below). May be `nil` (headless use).
    * `:subscriber` -- overrides `:dispatcher_pid` as the input-event
      target, for tests that want a separate collector.
    * `:raw_sink` -- optional pid that receives every PRE-parse input
      chunk as `{:inline_raw_input, binary()}`, exactly as it arrived
      from the tty reader, before `InputParser` sees it. Debug/observability
      seam (byte-level input tracing); default `nil` -- when unset, nothing
      changes on the input path.
    * `:device` -- output sink. Default `:stdio`. Accepts `:stdio` or any
      `t:IO.device/0` (a `StringIO` pid works great in tests -- everything
      here is written via plain `IO.write/2`, never raw port writes).
      **This is the suite design's hard requirement**: the output device
      is a parameter, not a hardcoded `:stdio` write, so Tier A
      (`harness-ui-testing/03-lifecycle.md` §1.1) can capture bytes with
      no pty and no termbox.
    * `:stty` -- module implementing `save/0`, `raw!/0`, `restore/1`
      (default `Raxol.Terminal.Driver.Stty`). Inject a recording stub in
      tests so OS-level tty state is never touched by a pure test run.
      Note: `raw!/0`'s termios flags include `-isig`, so once raw mode is
      entered the kernel stops generating SIGINT/SIGTSTP from Ctrl-C /
      Ctrl-Z -- interrupt delivery and job control become this driver's
      responsibility (or the app's) until teardown restores the saved
      settings.
    * `:tty?` -- override real-tty detection (default
      `Raxol.Terminal.TerminalUtils.has_terminal_device?/0`). Drives the
      default of `:install_reader?` and `:stty_enabled?` below.
    * `:stty_enabled?` -- whether to actually invoke the injected `:stty`
      module (default: same as `:tty?`). Kept independent of `:tty?` so a
      test can force the byte-emission path (`tty?: true`) while keeping
      `stty_enabled?: false` -- the real OS tty of whatever process is
      running the test suite is never touched by Tier A.
    * `:install_reader?` -- whether to hook the prim_tty trace-based stdin
      reader (default: same as `:tty?`). Independent for the same reason.
    * `:rows` -- terminal height used for the final teardown cursor move
      (default: detected via `:io.rows/0`, falling back to the injected
      `:stty` module's `size/0`, falling back to 24).
    * `:probe?` -- whether to run the T1 capability probe at startup
      (default `true`). Tests that only care about teardown ordering can
      pass `false` to skip the (bounded, ~100ms local / ~1s SSH) wait.
    * `:capabilities` -- a pre-computed `%Raxol.Terminal.Capabilities{}`.
      When given, the probe is skipped entirely and this record is cached
      directly -- the fastest test seam, and also useful for embedding
      contexts that already know the answer.
    * `:probe_opts` -- forwarded verbatim to
      `Raxol.Terminal.Capabilities.Probe.new/2` (`:budget_ms`,
      `:extend_ms`, `:now_ms`, `:tmux_passthrough?`, `:platform`).
    * `:probe_env` -- the env map the probe seeds from (default
      `System.get_env/0`).

  ## The output-device + teardown seam

  `emit_teardown/2` is the pure(-ish) seam the suite design calls for: it
  takes the output device and a driver state and writes the canonical
  teardown byte sequence (`Raxol.Terminal.InlineDriver.Sequences`),
  restores the OS tty via the injected stty module, and returns an updated
  state with `torn_down?: true`. It is idempotent -- a state that already
  has `torn_down?: true` is returned unchanged and nothing is written, so
  calling it twice (a signal handler AND `terminate/2`, say) can never
  double-emit `\\e[r` or reposition the cursor twice (LC-N-DOUBLE).

  `terminate/2` is the only caller in this module. It runs whenever THIS
  process terminates for a reachable reason: a direct `GenServer.stop/1`
  on the driver, or a crash inside any `handle_manager_*` callback (a
  raised error inside a GenServer callback still runs that same process's
  own `terminate/2` -- orthogonal to `trap_exit`, which only gates
  *external* exit signals). `System.halt` and `SIGKILL` run no cleanup at
  all -- documented residual, not a gap in this module (`kill -9` cannot
  be caught by anything running in the killed process).

  ## Teardown-on-quit through Lifecycle: graceful stop FIXED (T28a), SIGTERM open (T28b)

  The driver's teardown itself is correct and deterministic; whether
  Lifecycle *invokes* it on shutdown was unit T28's subject, since split
  into two facets with different fates:

    * **`Raxol.stop/1`** (in-process graceful stop): **deterministic
      since T28a** (merged). `Lifecycle` now traps exits and drives
      teardown from its own `terminate/2`, driver-first, so a dependent's
      `:shutdown` exit can no longer race back through the link and kill
      `Lifecycle` before this driver is stopped -- this `terminate/2`
      runs by construction. (Pre-T28a this was a measured ~50% miss under
      ExUnit load.) Enforced by the now-unskipped graceful-stop test in
      `test/harness/t2d_teardown_positive_test.exs`.

    * **OTP default SIGTERM -> `init:stop/0`** (the real VM tree-unwind a
      production `kill -TERM` / container stop triggers): teardown is
      still **never reached**. The tree unwind does not route through
      `Lifecycle` at all, so this `terminate/2` is skipped every time
      (measured under a real pty: no `\\e[r`, no modes-off in the
      capture). This is the stdio-shutdown race the termbox `driver.ex`
      already flags (~line 494) surfacing as a total miss on the inline
      path. Tracked as **unit T28b** (the first SIGTERM handler attempt
      self-deadlocked in `:erl_signal_server` and was reworked). Until
      T28b lands, production SIGTERM teardown relies on the app arranging
      its own handler that calls `Raxol.stop/1` (as the Tier B
      `LC-P-SIGTERM` test does); the gap stays pinned by the remaining
      skipped `@tag :pending_t28b` test. The driver's own teardown is
      meanwhile proven deterministically by stopping the driver process
      directly (`LC-P-CLEAN`).

  ## Input contract

  Parsed input events are sent to the subscriber as
  `{:inline_input, %Raxol.Core.Events.Event{}}` messages -- a simple
  pid/message contract, intentionally thin. Unit T13a wires the real
  Dispatcher; until then this seam is the whole contract.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.Probe
  alias Raxol.Terminal.Driver.Stty
  alias Raxol.Terminal.InlineDriver.CursorReport
  alias Raxol.Terminal.InlineDriver.Sequences
  alias Raxol.Terminal.TerminalUtils

  @default_rows 24
  # The DSR cursor probe's default reply deadline. This is a LIVENESS
  # bound on a real device round-trip (write `CSI 6n`, read the CPR off
  # the same fd) -- not a rendering clock: a local terminal answers in
  # single-digit milliseconds, an SSH hop in tens; a device that has not
  # answered within this bound (a pipe, a dumb terminal) is treated as
  # one that never will, and the caller falls back honestly.
  @default_cursor_probe_budget_ms 300
  @isig_confirmations 3

  defmodule State do
    @moduledoc false
    defstruct dispatcher_pid: nil,
              subscriber: nil,
              raw_sink: nil,
              device: :stdio,
              stty_module: Raxol.Terminal.Driver.Stty,
              stty_enabled?: false,
              tty?: false,
              rows: 24,
              original_stty: nil,
              torn_down?: false,
              isig_guard_every: 0,
              isig_guard_count: 0,
              isig_flags_reader: nil,
              isig_boot_confirmed?: false,
              isig_reasserts: 0

    @type t :: %__MODULE__{
            dispatcher_pid: pid() | nil,
            subscriber: pid() | nil,
            raw_sink: pid() | nil,
            device: IO.device(),
            stty_module: module(),
            stty_enabled?: boolean(),
            tty?: boolean(),
            rows: pos_integer(),
            original_stty: String.t() | nil,
            torn_down?: boolean(),
            isig_guard_every: non_neg_integer(),
            isig_guard_count: non_neg_integer(),
            isig_flags_reader: (-> boolean()) | nil,
            isig_boot_confirmed?: boolean(),
            isig_reasserts: non_neg_integer()
          }
  end

  # --- BaseManager callbacks ---

  @impl true
  def init_manager(opts) do
    # Trap exits so an EXTERNAL exit signal delivered to THIS process (e.g.
    # a supervisor's `GenServer.stop(driver, :shutdown)`, which is how
    # `Raxol.stop/1` reaches us) routes through terminate/2 rather than
    # killing the process before cleanup. NOTE: this does NOT close the
    # SIGTERM/`init:stop` gap on its own -- that VM-unwind path never stops
    # this driver in the first place (see the "Teardown-on-quit (T28)"
    # moduledoc section). Callback crashes and this process's own
    # `{:stop, ...}` returns already run terminate/2 regardless of trap_exit.
    Process.flag(:trap_exit, true)

    dispatcher_pid = extract_pid(Keyword.get(opts, :dispatcher_pid))
    subscriber = extract_pid(Keyword.get(opts, :subscriber, dispatcher_pid))
    raw_sink = extract_pid(Keyword.get(opts, :raw_sink))
    device = Keyword.get(opts, :device, :stdio)
    stty_module = Keyword.get(opts, :stty, Stty)

    tty? = Keyword.get(opts, :tty?, TerminalUtils.has_terminal_device?())
    install_reader? = Keyword.get(opts, :install_reader?, tty?)
    stty_enabled? = Keyword.get(opts, :stty_enabled?, tty?)
    rows = Keyword.get(opts, :rows, detect_rows(stty_module))

    # The event-clocked isig guard (see maybe_guard_isig/1): defaults to
    # checking on EVERY input chunk when a real reader owns the tty --
    # V's field data showed prim_tty can re-own the termios with ISIG on
    # at any point, so the cadence must win within one keypress-to-
    # keypress window. `0` disables (the readerless/test default).
    isig_guard_every =
      Keyword.get(
        opts,
        :isig_guard_every,
        if(install_reader? and stty_enabled?, do: 1, else: 0)
      )

    isig_flags_reader =
      Keyword.get(opts, :isig_flags_reader, &Stty.isig_off?/0)

    state = %State{
      dispatcher_pid: dispatcher_pid,
      subscriber: subscriber,
      raw_sink: raw_sink,
      device: device,
      stty_module: stty_module,
      stty_enabled?: stty_enabled?,
      tty?: tty?,
      rows: rows,
      isig_guard_every: isig_guard_every,
      isig_flags_reader: isig_flags_reader
    }

    state =
      if stty_enabled? do
        %{
          state
          | original_stty: normalize_saved_stty(safe_stty_call(stty_module, :save, []))
        }
      else
        state
      end

    if stty_enabled?, do: safe_stty_call(stty_module, :raw!, [])

    state = run_post_raw_setup(opts, device, subscriber, install_reader?, state)

    {:ok, state}
  end

  # Everything here runs with the OS tty already switched to raw mode. A
  # raise anywhere in this block -- a bad probe option, a
  # `user_drv`/`user_drv_reader` pid race inside `start_stdin_reader/0`,
  # anything -- would otherwise strand the tty raw with no recovery: OTP
  # never completes `init/1` on an uncaught raise, so THIS process's own
  # `terminate/2` is never invoked (there is no live `%State{}` for it to
  # run against), and `emit_teardown/2` -- the only place that restores
  # the saved settings -- is unreachable. Trap the whole post-raw!()
  # sequence here instead: restore proactively (falling back to `stty
  # sane` when there's no saved snapshot to return to), then re-raise so
  # `init_manager/1`'s documented raise-to-fail-fast contract is
  # unchanged. (raw!()-last is infeasible: the probe below genuinely
  # needs the tty already in raw mode to read replies un-echoed.)
  defp run_post_raw_setup(opts, device, subscriber, install_reader?, state) do
    # No \e[?1049h anywhere on this path -- LC-P-NOALT.
    IO.write(device, Sequences.init_bytes())

    state =
      if install_reader? do
        start_stdin_reader()

        # Re-assert raw termios AFTER the reader is armed: user_drv's
        # `{:start_shell, %{input: :raw}}` makes prim_tty re-initialize
        # the termios with ITS raw settings, which keep ISIG ENABLED --
        # silently clobbering the `-isig` this module's moduledoc
        # promises. With ISIG back on, ^C becomes SIGINT (the VM BREAK
        # menu printed over the frame, or a silent drop under +Bi)
        # instead of byte 0x03 to the subscriber -- observed live as
        # "the pilot cannot exit". prim_tty applies its termios
        # ASYNCHRONOUSLY after the call returns, so a single immediate
        # re-assert loses the race: verify-then-assert with a bounded
        # budget instead, reading the LIVE flags (the referent, not this
        # module's own bookkeeping) until `-isig` sticks. The outcome is
        # RECORDED (isig_boot_confirmed?) for `isig_report/1`, and the
        # event-clocked guard (maybe_guard_isig/1) keeps watching from
        # here on -- nothing is ever written to the tty on the give-up
        # path (no bytes may leak into the claimed frame); an embedder's
        # probe (the live demo's boot POST line) is the honest reporting
        # channel.
        if state.stty_enabled? do
          confirmed? =
            reassert_raw_until_isig_off(state.stty_module) == :confirmed

          %{state | isig_boot_confirmed?: confirmed?}
        else
          state
        end
      else
        state
      end

    opts
    |> maybe_run_probe(device, subscriber)
    |> case do
      nil -> :ok
      caps -> Capabilities.cache(caps)
    end

    state
  rescue
    error ->
      restore_stranded_raw_mode(
        state.stty_module,
        state.stty_enabled?,
        state.original_stty
      )

      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      restore_stranded_raw_mode(
        state.stty_module,
        state.stty_enabled?,
        state.original_stty
      )

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @impl true
  def handle_manager_call({:probe_cursor, budget_ms}, _from, %State{} = state) do
    {:reply, run_cursor_probe(state, budget_ms), state}
  end

  # NOTE: every handle_manager_call clause must sit ABOVE the catch-all
  # below -- a clause defined after it is unreachable (caught live: the
  # first :isig_report landing in the catch-all fed {:error,
  # :not_implemented} to the demo's POST line).
  def handle_manager_call(:isig_report, _from, state) do
    report = %{
      boot_confirmed?: state.isig_boot_confirmed?,
      reasserts: state.isig_reasserts,
      isig_off?: state.isig_flags_reader && state.isig_flags_reader.()
    }

    {:reply, report, state}
  end

  # BaseManager's default (warn + {:error, :not_implemented}) is replaced
  # the moment any handle_manager_call clause is defined -- restore it
  # for every request this driver does not understand.
  @impl true
  def handle_manager_call(request, _from, state) do
    Log.warning_with_context(
      "[InlineDriver] unhandled call: #{inspect(request)}",
      %{}
    )

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_manager_info(
        {:trace, _reader, :send, {_ref, {:data, data}}, _to},
        state
      ) do
    dispatch_input(to_binary_data(data), state)
  end

  @impl true
  def handle_manager_info({port, {:data, data}}, state) when is_port(port) do
    dispatch_input(to_binary_data(data), state)
  end

  @impl true
  def handle_manager_info({:trace, _pid, :send, _msg, _to}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({port, :eof}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({port, {:exit_status, _status}}, state)
      when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{} = state) do
    # terminate/2 is the SOLE caller of emit_teardown/2 today, and the
    # process is dying, so discarding the returned `torn_down?: true` state
    # is intentional (nothing reads it after this). If a second caller is
    # ever added -- e.g. a signal handler that runs teardown pre-emptively
    # -- it MUST thread the returned state back into the GenServer state so
    # this terminate/2 call sees `torn_down?: true` and the idempotency
    # guard fires (otherwise CSI r / cursor reposition double-emits).
    _ = emit_teardown(state.device, state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- The teardown seam ---

  @doc """
  Writes the canonical teardown byte sequence to `device` and restores the
  OS tty (via `state.stty_module`, unless `state.stty_enabled?` is
  `false`). Idempotent: a `state` with `torn_down?: true` is returned
  unchanged, writing nothing (LC-N-DOUBLE).
  """
  @spec emit_teardown(IO.device(), State.t()) :: State.t()
  def emit_teardown(_device, %State{torn_down?: true} = state), do: state

  def emit_teardown(device, %State{} = state) do
    IO.write(device, Sequences.teardown_bytes(state.rows))

    if state.stty_enabled? do
      safe_stty_call(state.stty_module, :restore, [state.original_stty])
    end

    %{state | torn_down?: true}
  end

  # --- The DSR cursor probe (GUEST-BOOT seam) ---

  @doc """
  Asks the real terminal where the shell left the cursor: writes DSR-6
  (`Sequences.cursor_position_request/0`, `CSI 6n`) to the driver's
  device and reads the CPR reply (`CSI row ; col R`) off the driver's
  own input stream. This is the substrate for GUEST-BOOT placement
  (`Raxol.UI.Rendering.PaintAuthority.InlineAuthority`'s `:boot_cursor`
  option): boot the surface exactly where the user's shell stopped,
  instead of pushing a blank screen first.

  Returns:

    * `{:ok, {row, col}}` — 1-based, straight from the terminal's reply.
    * `{:error, :no_tty}` — the driver was constructed with
      `tty?: false` (piped/CI). ZERO bytes are written: a device that
      cannot answer must not be probed at all.
    * `{:error, :timeout}` — no CPR arrived within `:budget_ms`
      (default #{@default_cursor_probe_budget_ms}ms). The budget is a
      LIVENESS bound on the device round-trip, not a rendering clock —
      see the module attribute note. On timeout every byte read while
      waiting has already been forwarded to the subscriber as ordinary
      input; nothing is dropped.

  ## The consumption contract (why this lives on the driver)

  The CPR reply arrives interleaved with real keystrokes on the same
  fd this driver already owns. Scanning happens INSIDE the driver
  process (`Raxol.Terminal.InlineDriver.CursorReport`, the pure
  scanner), before `InputParser` ever sees the bytes, because a CPR is
  not representable as "just another event": `InputParser` decodes a
  row-1 reply (`\\e[1;<n>R`) as a modified F3 keypress — the classic
  DSR/F3 wire collision — so letting it through would deliver a
  phantom key event to the app. Keystrokes interleaved with (or split
  around) the reply are forwarded to the subscriber in arrival order,
  never dropped.

  ## Caller discipline

    * Probe BEFORE the first paint, at most once per claim: this writes
      bytes to the device, so it is strictly opt-in (nothing in
      `init_manager/1` ever emits it).
    * The result is only placement-honest while nothing else has
      written to the device between the reply and the boot that
      consumes it.
    * Residual: a reply that arrives AFTER the deadline lapses flows
      down the ordinary input path, where `InputParser` consumes it
      silently — except the row-1 form, which surfaces as a phantom
      modified-F3 keypress. Bound the exposure by probing when the
      terminal is idle (boot), which is the only supported call site.
  """
  @spec probe_cursor(GenServer.server(), keyword()) ::
          {:ok, CursorReport.position()} | {:error, :timeout | :no_tty}
  def probe_cursor(server, opts \\ []) do
    budget_ms =
      Keyword.get(opts, :budget_ms, @default_cursor_probe_budget_ms)

    GenServer.call(server, {:probe_cursor, budget_ms}, budget_ms + 5_000)
  end

  defp run_cursor_probe(%State{tty?: false}, _budget_ms),
    do: {:error, :no_tty}

  defp run_cursor_probe(%State{} = state, budget_ms) do
    IO.write(state.device, Sequences.cursor_position_request())
    deadline = System.monotonic_time(:millisecond) + budget_ms
    cursor_probe_loop(<<>>, deadline, state)
  end

  # Absolute-deadline receive loop (same discipline as probe_loop/3
  # below: re-derive `remaining` every iteration so a flooding terminal
  # can never extend the probe). Runs inside the driver's own
  # handle_manager_call, so the reader's trace/port messages land in
  # this process's mailbox and the selective receive picks them up.
  defp cursor_probe_loop(buffer, deadline, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:trace, _reader, :send, {_ref, {:data, data}}, _to} ->
        cursor_probe_ingest(buffer, to_binary_data(data), deadline, state)

      {port, {:data, data}} when is_port(port) ->
        cursor_probe_ingest(buffer, to_binary_data(data), deadline, state)
    after
      remaining ->
        forward_probe_leftover(buffer, state)
        {:error, :timeout}
    end
  end

  defp cursor_probe_ingest(buffer, chunk, deadline, state) do
    # The raw tap sees every chunk exactly as it arrived (its documented
    # contract) -- only the PARSED path is CPR-free. Forwarded leftovers
    # below go through the parse-only path so the tap never sees a byte
    # twice.
    notify_raw(state.raw_sink, chunk)

    case CursorReport.scan(buffer <> chunk) do
      {:reply, pos, leading, trailing} ->
        forward_probe_leftover(leading, state)
        forward_probe_leftover(trailing, state)
        {:ok, pos}

      {:pending, forward, keep} ->
        forward_probe_leftover(forward, state)
        cursor_probe_loop(keep, deadline, state)
    end
  end

  # Parse-only forward (raw_sink already saw these bytes at arrival):
  # keystrokes interleaved with the CPR reply still reach the subscriber
  # in order -- the leak-free rule.
  defp forward_probe_leftover(<<>>, _state), do: :ok

  defp forward_probe_leftover(bytes, state) do
    bytes
    |> safe_parse()
    |> Enum.each(&notify(state.subscriber, &1))

    :ok
  end

  # --- The isig diagnosis (the ^C byte-path report) ---

  @doc """
  The isig diagnosis for embedder-level reporting (the live demo's boot
  POST line): which mechanism last held `-isig` and how often the
  event-clocked guard has had to re-assert it.

    * `boot_confirmed?` -- the post-reader-arm verify loop saw `-isig`
      hold for #{@isig_confirmations} consecutive reads at claim time;
    * `reasserts` -- how many times the per-input-event guard found
      ISIG flipped back ON mid-session and re-asserted;
    * `isig_off?` -- the LIVE flags right now, read through the same
      injectable reader the guard uses.
  """
  @spec isig_report(GenServer.server()) :: %{
          boot_confirmed?: boolean(),
          reasserts: non_neg_integer(),
          isig_off?: boolean()
        }
  def isig_report(server), do: GenServer.call(server, :isig_report)

  # (Its handle_manager_call clause lives with the other call clauses,
  # ABOVE the module's catch-all -- see the ordering note there.)

  # --- Input dispatch ---

  defp dispatch_input(<<>>, state), do: {:noreply, state}

  defp dispatch_input(data, state) do
    notify_raw(state.raw_sink, data)

    data
    |> safe_parse()
    |> Enum.each(&notify(state.subscriber, &1))

    # AFTER forwarding: the guard's stty spawn must never delay the
    # keystroke that carried us here -- it protects the NEXT one.
    {:noreply, maybe_guard_isig(state)}
  end

  defp notify_raw(nil, _data), do: :ok

  defp notify_raw(pid, data) when is_pid(pid),
    do: send(pid, {:inline_raw_input, data})

  defp notify(nil, _event), do: :ok

  defp notify(pid, event) when is_pid(pid),
    do: send(pid, {:inline_input, event})

  defp safe_parse(data) do
    InputParser.parse(data)
  rescue
    error ->
      Log.warning_with_context(
        "[InlineDriver] InputParser crashed on raw input, dropping this chunk: " <>
          Exception.message(error),
        %{}
      )

      []
  catch
    kind, reason ->
      Log.warning_with_context(
        "[InlineDriver] InputParser raised #{inspect(kind)} on raw input, dropping this chunk: " <>
          inspect(reason),
        %{}
      )

      []
  end

  defp to_binary_data(data) when is_binary(data), do: data
  defp to_binary_data(data) when is_list(data), do: IO.iodata_to_binary(data)
  defp to_binary_data(_data), do: <<>>

  # --- The T1 probe, driven with an absolute-deadline loop ---
  #
  # STATE doc wiring note (carried from T1's review, restated here because
  # this is the first driver-level consumer of Probe): re-derive
  # `remaining = deadline - now` on EVERY receive iteration. A resetting
  # `after budget_ms` would let a flooding terminal (input arriving faster
  # than the timeout keeps firing) extend the probe indefinitely; deriving
  # `remaining` from the fixed absolute deadline each time means it can't.

  defp maybe_run_probe(opts, device, subscriber) do
    case Keyword.get(opts, :capabilities) do
      %Capabilities{} = caps ->
        caps

      nil ->
        if Keyword.get(opts, :probe?, true) do
          run_probe(opts, device, subscriber)
        else
          nil
        end
    end
  end

  defp run_probe(opts, device, subscriber) do
    env = Keyword.get(opts, :probe_env, System.get_env())

    probe_opts =
      opts
      |> Keyword.get(:probe_opts, [])
      |> Keyword.put_new(:now_ms, System.monotonic_time(:millisecond))

    probe = Probe.new(env, probe_opts)
    {probe, actions} = Probe.step(probe, :start)
    run_probe_actions(actions, device, subscriber)
    probe_loop(probe, device, subscriber)
  end

  defp probe_loop(probe, device, subscriber) do
    case Probe.result(probe) do
      {:done, caps} ->
        caps

      :pending ->
        remaining = max(probe.deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:trace, _reader, :send, {_ref, {:data, data}}, _to} ->
            step_probe_input(probe, device, subscriber, to_binary_data(data))

          {port, {:data, data}} when is_port(port) ->
            step_probe_input(probe, device, subscriber, to_binary_data(data))
        after
          remaining ->
            {probe, actions} =
              Probe.step(probe, {:clock, System.monotonic_time(:millisecond)})

            run_probe_actions(actions, device, subscriber)
            probe_loop(probe, device, subscriber)
        end
    end
  end

  defp step_probe_input(probe, device, subscriber, binary) do
    {probe, actions} = Probe.step(probe, {:input, binary})
    run_probe_actions(actions, device, subscriber)
    probe_loop(probe, device, subscriber)
  end

  defp run_probe_actions(actions, device, subscriber) do
    Enum.each(actions, &run_probe_action(&1, device, subscriber))
  end

  defp run_probe_action({:write, iodata}, device, _subscriber),
    do: IO.write(device, iodata)

  defp run_probe_action({:passthrough, iodata}, device, _subscriber),
    do: IO.write(device, iodata)

  defp run_probe_action({:extend_deadline, _ms}, _device, _subscriber), do: :ok

  # CAP-N-03: bytes the scanner determined are NOT part of a capability
  # reply (interleaved real keystrokes) still reach the subscriber instead
  # of being silently dropped.
  defp run_probe_action({:leak_free, binary}, _device, subscriber) do
    binary
    |> safe_parse()
    |> Enum.each(&notify(subscriber, &1))
  end

  defp run_probe_action({:done, _caps}, _device, _subscriber), do: :ok

  # --- Input reader activation ---
  #
  # Mirrors Raxol.Terminal.Driver's start_stdin_reader/1 (driver.ex):
  # duplicated deliberately rather than shared, since this module must not
  # touch driver.ex (the inline profile is an additive sibling, not a
  # refactor of the termbox path). In -noshell mode (`mix run`), user_drv
  # initializes prim_tty with tty => false, so the reader never receives
  # select notifications; reinitializing via user_drv's :start_shell with
  # `initial_shell: :noshell` (never an MFA -- anything else spawns a real
  # shell and drops user_drv into a JCL prompt that swallows all input)
  # arms it, and tracing the reader's sends intercepts input data before
  # user_drv forwards it anywhere else.
  defp start_stdin_reader do
    user_drv = Process.whereis(:user_drv)

    if user_drv do
      try do
        :gen_statem.call(
          user_drv,
          {:start_shell, %{initial_shell: :noshell, input: :raw}}
        )
      catch
        _, _ -> :ok
      end
    end

    reader = Process.whereis(:user_drv_reader)

    if reader do
      :erlang.trace(reader, true, [:send])
      send(reader, {:read, :infinity})
    end

    :ok
  end

  # Bounded verify-then-assert for the post-reader-arm `-isig`
  # guarantee (see run_post_raw_setup/5's comment). prim_tty's termios
  # write lands asynchronously, so ONE successful read is not proof the
  # race is won -- it may simply not have landed yet. This therefore
  # demands `@isig_confirmations` CONSECUTIVE 50ms-spaced reads showing
  # `-isig`, re-asserting raw! and restarting the confirmation count on
  # any flip-back, bounded by `attempts` total iterations (~3s boot-
  # window liveness bound; two-three passes in practice). Only reachable
  # with `install_reader?: true` on a real tty; the injected-stty test
  # paths all run readerless. On a device where the flags never confirm
  # (e.g. no controlling tty, where stty cannot run at all), this gives
  # up silently -- nothing here may write bytes to the claimed frame;
  # the result is recorded for `isig_report/1` and the embedder's probe
  # (the live demo's boot POST termios line) is the honest reporting
  # channel.
  defp reassert_raw_until_isig_off(stty_module, attempts \\ 60) do
    do_reassert_isig(stty_module, attempts, 0)
  end

  defp do_reassert_isig(_stty_module, 0, _confirmed), do: :gave_up

  defp do_reassert_isig(_stty_module, _attempts, @isig_confirmations),
    do: :confirmed

  defp do_reassert_isig(stty_module, attempts, confirmed) do
    confirmed =
      if Stty.isig_off?() do
        confirmed + 1
      else
        safe_stty_call(stty_module, :raw!, [])
        0
      end

    Process.sleep(50)
    do_reassert_isig(stty_module, attempts - 1, confirmed)
  end

  # The event-clocked isig guard: every `isig_guard_every` input chunks
  # (V's field data -- prim_tty can re-own the termios with ISIG on at
  # any point, so the default cadence is EVERY chunk: the flip is
  # caught within one keypress-to-keypress window), read the LIVE flags
  # through the injectable reader; on a flip, re-assert raw! and tell
  # the subscriber (`{:inline_isig_reasserted}`) so the embedder can
  # render an honest notice and the pilot sees it happen. `0` disables.
  defp maybe_guard_isig(%State{isig_guard_every: every} = state)
       when is_integer(every) and every > 0 do
    count = state.isig_guard_count + 1

    if count >= every do
      guard_isig_now(%{state | isig_guard_count: 0})
    else
      %{state | isig_guard_count: count}
    end
  end

  defp maybe_guard_isig(state), do: state

  defp guard_isig_now(state) do
    if state.isig_flags_reader.() do
      state
    else
      safe_stty_call(state.stty_module, :raw!, [])

      if is_pid(state.subscriber),
        do: send(state.subscriber, {:inline_isig_reasserted})

      %{state | isig_reasserts: state.isig_reasserts + 1}
    end
  end

  # --- Small helpers ---

  defp extract_pid(pid) when is_pid(pid), do: pid
  defp extract_pid(_), do: nil

  defp detect_rows(stty_module) do
    case :io.rows() do
      {:ok, rows} when is_integer(rows) and rows > 0 ->
        rows

      _ ->
        case safe_stty_call(stty_module, :size, []) do
          {:ok, _cols, rows} -> rows
          _ -> @default_rows
        end
    end
  end

  defp safe_stty_call(module, fun, args) do
    apply(module, fun, args)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # `safe_stty_call/3` returns the atom `:error` (not `nil`) when the
  # injected `:stty` module's `save/0` raises/throws -- coerce that to
  # `nil` so `State.original_stty` always matches its own `String.t() |
  # nil` type, never the bare `:error` atom.
  defp normalize_saved_stty(:error), do: nil
  defp normalize_saved_stty(saved), do: saved

  defp restore_stranded_raw_mode(_stty_module, false, _original_stty), do: :ok

  defp restore_stranded_raw_mode(stty_module, true, original_stty) do
    safe_stty_call(stty_module, :restore, [original_stty])
    :ok
  end
end
