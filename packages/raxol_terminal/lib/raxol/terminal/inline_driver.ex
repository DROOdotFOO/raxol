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

  ## Teardown-on-quit is NOT reliably wired through Lifecycle (unit T28)

  Neither app-level quit path reliably reaches this `terminate/2` today
  (both measured, not assumed -- see the tests referenced below). The
  driver's teardown itself is correct and deterministic; the gap is that
  Lifecycle does not dependably *invoke* it on shutdown.

    * **`Raxol.stop/1`** (in-process graceful stop):
      `Lifecycle.handle_cast(:shutdown)` stops its dependents in order --
      the rendering engine, THEN this driver -- via
      `GenServer.stop(pid, :shutdown, _)`. Neither `Lifecycle` nor its
      caller traps exits, so the rendering engine's `:shutdown` exit RACES
      back through the link: if it kills `Lifecycle` before the
      `GenServer.stop(driver, ...)` line is reached, this `terminate/2`
      never runs. Measured **~50% miss under ExUnit load** (a bare
      `mix run` happens to win the race every time, which is why it can
      look reliable in isolation). So teardown-on-graceful-stop is present
      but nondeterministic.

    * **OTP default SIGTERM -> `init:stop/0`** (the real VM tree-unwind a
      production `kill -TERM` / container stop triggers): teardown is
      **never reached**. The tree unwind does not route through
      `Lifecycle`'s own `handle_cast(:shutdown)` at all, so this
      `terminate/2` is skipped every time (measured under a real pty: no
      `\\e[r`, no modes-off in the capture). This is the stdio-shutdown
      race the termbox `driver.ex` already flags (~line 494) surfacing as
      a total miss on the inline path.

  Both are the same Lifecycle-level defect, tracked as **unit T28
  (graceful shutdown deterministically reaches driver terminate)**. It
  reproduces identically with `environment: :terminal` and the termbox
  driver -- not specific to the inline profile. Until T28 lands, reliable
  production teardown-on-quit **relies on T28** (or on the app arranging
  its own SIGTERM handler that stops the driver / calls `Raxol.stop/1`
  and retries, as the Tier B `LC-P-SIGTERM` test does). The gap is pinned
  by two skipped, tagged tests (`@tag :pending_t28` in
  `test/harness/t2d_teardown_positive_test.exs`) -- one per path -- that
  fail today and whose `skip:` T28's builder removes when the fix lands.
  The driver's own teardown is meanwhile proven deterministically by
  stopping the driver process directly (`LC-P-CLEAN`).

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
  alias Raxol.Terminal.InlineDriver.Sequences
  alias Raxol.Terminal.TerminalUtils

  @default_rows 24

  defmodule State do
    @moduledoc false
    defstruct dispatcher_pid: nil,
              subscriber: nil,
              device: :stdio,
              stty_module: Raxol.Terminal.Driver.Stty,
              stty_enabled?: false,
              tty?: false,
              rows: 24,
              original_stty: nil,
              torn_down?: false

    @type t :: %__MODULE__{
            dispatcher_pid: pid() | nil,
            subscriber: pid() | nil,
            device: IO.device(),
            stty_module: module(),
            stty_enabled?: boolean(),
            tty?: boolean(),
            rows: pos_integer(),
            original_stty: String.t() | nil,
            torn_down?: boolean()
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
    device = Keyword.get(opts, :device, :stdio)
    stty_module = Keyword.get(opts, :stty, Stty)

    tty? = Keyword.get(opts, :tty?, TerminalUtils.has_terminal_device?())
    install_reader? = Keyword.get(opts, :install_reader?, tty?)
    stty_enabled? = Keyword.get(opts, :stty_enabled?, tty?)
    rows = Keyword.get(opts, :rows, detect_rows(stty_module))

    state = %State{
      dispatcher_pid: dispatcher_pid,
      subscriber: subscriber,
      device: device,
      stty_module: stty_module,
      stty_enabled?: stty_enabled?,
      tty?: tty?,
      rows: rows
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

    run_post_raw_setup(opts, device, subscriber, install_reader?, state)

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

    if install_reader?, do: start_stdin_reader()

    opts
    |> maybe_run_probe(device, subscriber)
    |> case do
      nil -> :ok
      caps -> Capabilities.cache(caps)
    end
  rescue
    error ->
      restore_stranded_raw_mode(state.stty_module, state.stty_enabled?, state.original_stty)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      restore_stranded_raw_mode(state.stty_module, state.stty_enabled?, state.original_stty)
      :erlang.raise(kind, reason, __STACKTRACE__)
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

  # --- Input dispatch ---

  defp dispatch_input(<<>>, state), do: {:noreply, state}

  defp dispatch_input(data, state) do
    data
    |> safe_parse()
    |> Enum.each(&notify(state.subscriber, &1))

    {:noreply, state}
  end

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
