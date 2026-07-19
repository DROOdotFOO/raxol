defmodule Raxol.Terminal.Driver do
  @moduledoc """
  Handles raw terminal input/output and event generation.

  Responsibilities:
  - Setting terminal mode (raw, echo)
  - Reading input events via termbox2_nif NIF
  - Parsing input events into `Raxol.Core.Events.Event` structs
  - Detecting terminal resize events
  - Sending parsed events to the `Dispatcher`
  - Restoring terminal state on exit
  """

  alias Raxol.Core.Runtime.Log
  use Raxol.Core.Behaviours.BaseManager

  # Import Bitwise for bitwise operations
  # import Bitwise

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.Probe
  alias Raxol.Terminal.Driver.BackgroundQuery
  alias Raxol.Terminal.Driver.Dispatch
  alias Raxol.Terminal.Driver.EventTranslator
  alias Raxol.Terminal.Driver.InputBuffer
  alias Raxol.Terminal.Driver.TermboxLifecycle

  @compile {:no_warn_undefined, Raxol.Terminal.Driver.Dispatch}
  @compile {:no_warn_undefined, Raxol.Terminal.Driver.EventTranslator}
  @compile {:no_warn_undefined, Raxol.Terminal.Driver.InputBuffer}
  @compile {:no_warn_undefined, Raxol.Terminal.Driver.TermboxLifecycle}

  @input_buffer_flush_ms 50

  # Check if termbox2_nif is available at compile time
  @termbox2_available Code.ensure_loaded?(:termbox2_nif)

  import Raxol.Terminal.TerminalUtils, only: [has_terminal_device?: 0]

  alias Raxol.Terminal.Env

  # Constants for retry logic
  @max_init_retries 3
  # ms
  @init_retry_delay 1000

  # Allow nil initially
  @type dispatcher_pid :: pid() | nil
  @type original_stty :: String.t()
  @type termbox_state :: :uninitialized | :initialized | :failed

  defmodule State do
    @moduledoc false
    defstruct dispatcher_pid: nil,
              original_stty: nil,
              termbox_state: :uninitialized,
              init_retries: 0,
              io_terminal_state: nil,
              input_buffer: <<>>,
              flush_timer: nil,
              sigwinch_handler: nil,
              capabilities_probe: nil,
              capabilities_probe_timer: nil
  end

  # --- Public API ---

  @doc """
  Returns the current terminal backend being used.

  ## Examples

      iex> Raxol.Terminal.Driver.backend()
      :termbox2_nif

      iex> Raxol.Terminal.Driver.backend()
      :io_terminal
  """
  # The spec covers both possible return values across platforms.
  # On any given compilation, only one branch is reachable due to
  # @termbox2_available being a compile-time constant.
  @dialyzer {:nowarn_function, backend: 0}
  @spec backend() :: :termbox2_nif | :io_terminal
  def backend do
    if @termbox2_available, do: :termbox2_nif, else: :io_terminal
  end

  # BaseManager provides start_link/1 and start_link/2 automatically
  # We can override if needed but the dispatcher_pid is passed as init argument

  # --- BaseManager Callbacks ---

  # Logger.configure(level: :none) works at runtime but :none isn't in Logger's typespec
  @dialyzer {:nowarn_function, init_manager: 1}
  @impl true
  def init_manager(opts) do
    # Extract dispatcher_pid from opts - handle both keyword list and raw value
    dispatcher_pid = extract_dispatcher_pid(opts)

    mouse_enabled =
      if is_list(opts), do: Keyword.get(opts, :mouse, true), else: true

    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] init called with dispatcher: #{inspect(dispatcher_pid)}"
    )

    # Get original terminal settings using Erlang IO (no subprocess needed)
    output =
      case {:io.rows(), :io.columns()} do
        {{:ok, rows}, {:ok, cols}} -> "#{rows} #{cols}"
        _ -> "80 24"
      end

    state = %State{
      dispatcher_pid: dispatcher_pid,
      original_stty: output,
      termbox_state: :uninitialized,
      init_retries: 0
    }

    # Initialize terminal in raw mode only if attached to a TTY.
    # Use has_terminal_device?() instead of real_tty?() because the latter
    # relies on :io.columns() which fails in -noshell mode (mix run).
    tty_detected = has_terminal_device?()

    case {Env.test?(), tty_detected, dispatcher_pid} do
      {true, _, nil} ->
        Raxol.Core.Runtime.Log.info(
          "[Driver] Test environment detected, sending driver_ready event"
        )

        Raxol.Core.Runtime.Log.warning_with_context(
          "[Driver] No dispatcher_pid provided, skipping driver_ready and initial resize event",
          %{}
        )

        state = %{state | termbox_state: :initialized}
        {:ok, state}

      {true, _, pid} ->
        Raxol.Core.Runtime.Log.info(
          "[Driver] Test environment detected, sending driver_ready event"
        )

        send(pid, {:driver_ready, self()})

        Raxol.Core.Runtime.Log.info(
          "[Driver] Sending initial resize event to dispatcher_pid: #{inspect(pid)}"
        )

        Dispatch.send_initial_resize_event(pid)
        state = %{state | termbox_state: :initialized}
        {:ok, state}

      {_, _, nil} ->
        # No dispatcher — this is the Application supervisor's placeholder Driver.
        # Don't set up the terminal; the Lifecycle's Driver will do that.
        Raxol.Core.Runtime.Log.info(
          "[TerminalDriver] No dispatcher, skipping terminal setup."
        )

        {:ok, state}

      {_, true, _} ->
        Raxol.Core.Runtime.Log.info(
          "[TerminalDriver] TTY detected, initializing ANSI terminal..."
        )

        # Save original TTY settings via /dev/tty (System.cmd pipes stdin,
        # so we must redirect from /dev/tty for stty to affect the real terminal)
        original_stty = Raxol.Terminal.Driver.Stty.save()

        # Raw mode on the actual terminal: no echo, no line buffering, no signals
        Raxol.Terminal.Driver.Stty.raw!()

        # Suppress Logger console output so it doesn't corrupt the TUI
        Logger.configure(level: :none)

        # Enter alternate screen, hide cursor, disable DECAWM (autowrap,
        # \e[?7l): the frame writes full-terminal-width rows via \e[H, and
        # with autowrap on, the last cell of a full-width row advances the
        # cursor on its own, so the frame's own newline advances a *second*
        # time -- doubling every content row. See normalize_frame/1 in
        # Raxol.Core.Runtime.Rendering.Backends for the LF->CRLF half of the
        # fix. Restored in TermboxLifecycle.cleanup_terminal/1.
        IO.write("\e[?1049h\e[?25l\e[?7l")

        # Reset mouse tracking (may be left over from a crashed session)
        IO.write("\e[?1003l\e[?1006l\e[?1000l")

        # Enable SGR mouse mode (button events + SGR extended coordinates)
        if mouse_enabled do
          IO.write("\e[?1000h\e[?1006h")
        end

        # Enable terminal modes: focus reporting, bracketed paste
        IO.write("\e[?1004h\e[?2004h")

        # Send initial resize event if we have a dispatcher
        if dispatcher_pid,
          do: Dispatch.send_initial_resize_event(dispatcher_pid)

        # Subscribe to SIGWINCH so window resizes reach the app. Input data
        # arrives via the prim_tty reader trace, but SIGWINCH is delivered by
        # :erl_signal_server directly to user_drv, so we need our own handler.
        sigwinch_handler = install_sigwinch_handler()

        # Activate prim_tty reader for input. In -noshell mode, prim_tty
        # was initialized with tty => false, so the reader gets no select
        # notifications. start_stdin_reader triggers reinit with tty => true
        # and sets up trace interception of the reader's output.
        start_stdin_reader(self())

        # Query the terminal's capabilities (OSC 11 background + OSC 10
        # foreground + kitty keyboard flags + DECRQM 2026 sync-output +
        # XTVERSION identity) with a DA1 probe as the unsupported-terminal
        # sentinel -- the F0 capabilities pipeline (Probe -> ReplyScanner ->
        # Classifier). Replies are extracted from the input stream in
        # dispatch_raw_input/2 via route_capabilities_input/2. Must run
        # after start_stdin_reader: writing it earlier races prim_tty's
        # tty=>true reinit and can corrupt job control before a frame ever
        # renders. Any failure here degrades to "no capabilities detected"
        # rather than crashing init.
        state = start_capabilities_probe(state)

        state = %{
          state
          | termbox_state: :initialized,
            original_stty: original_stty,
            sigwinch_handler: sigwinch_handler,
            io_terminal_state: %{
              input_reader: Process.whereis(:user_drv_reader),
              tty_fd: nil,
              tty_port: nil
            }
        }

        {:ok, state}

      {_, false, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Not attached to a TTY. Skipping Termbox2Nif.tb_init(). Terminal features will be disabled.",
          %{}
        )

        {:ok, state}
    end
  end

  # --- BaseManager handle_info callbacks ---

  @impl true
  def handle_manager_info(:retry_init, %{init_retries: retries} = state)
      when retries < @max_init_retries do
    case TermboxLifecycle.initialize() do
      :ok ->
        Raxol.Core.Runtime.Log.info("Successfully initialized termbox on retry")
        {:noreply, %{state | termbox_state: :initialized}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Failed to initialize termbox on retry #{retries + 1}: #{inspect(reason)}"
        )

        Process.send_after(self(), :retry_init, @init_retry_delay)
        {:noreply, %{state | init_retries: retries + 1}}
    end
  end

  @impl true
  def handle_manager_info(:retry_init, state) do
    Raxol.Core.Runtime.Log.error(
      "Failed to initialize termbox after #{@max_init_retries} attempts. Terminal features will be disabled."
    )

    {:noreply, state}
  end

  @impl true
  def handle_manager_info(
        {:termbox_event, event_map},
        %{termbox_state: :initialized, dispatcher_pid: dispatcher_pid} = state
      ) do
    Raxol.Core.Runtime.Log.debug(
      "Received termbox event: #{inspect(event_map)}"
    )

    case EventTranslator.translate(event_map) do
      {:ok, %Event{} = event} ->
        # Only send if dispatcher_pid is known
        case dispatcher_pid do
          nil -> :ok
          pid -> Dispatch.send_event_to_dispatcher(pid, event)
        end

        {:noreply, state}

      :ignore ->
        # Event type we don't care about
        Raxol.Core.Runtime.Log.debug(
          "[Driver] Ignoring termbox event: #{inspect(event_map)}"
        )

        {:noreply, state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Failed to translate termbox event: #{inspect(reason)}. Event: #{inspect(event_map)}",
          %{}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_manager_info({:termbox_event, _event_map}, state) do
    # Ignore events if termbox is not initialized
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:termbox_error, reason}, state) do
    Raxol.Core.Runtime.Log.error(
      "Received termbox error: #{inspect(reason)}. Attempting recovery..."
    )

    case state.termbox_state do
      :initialized -> TermboxLifecycle.handle_recovery(reason, state)
      _ -> {:stop, {:termbox_error, reason}, state}
    end
  end

  # SIGWINCH arrived (via SigwinchHandler on :erl_signal_server) — the
  # terminal window was resized. Query the fresh size and dispatch a
  # resize event so the app and rendering engine can reflow.
  @impl true
  def handle_manager_info(:sigwinch, %{dispatcher_pid: pid} = state)
      when is_pid(pid) do
    Dispatch.send_resize_event(pid)
    {:noreply, state}
  end

  @impl true
  def handle_manager_info(:sigwinch, state), do: {:noreply, state}

  @impl true
  def handle_manager_info({:register_dispatcher, pid}, state)
      when is_pid(pid) do
    Raxol.Core.Runtime.Log.info("Registering dispatcher PID: #{inspect(pid)}")
    # Send initial size event now that we have the PID
    Dispatch.send_initial_resize_event(pid)
    {:noreply, %{state | dispatcher_pid: pid}}
  end

  @impl true
  def handle_manager_info(
        {:test_input, input_data},
        %{dispatcher_pid: nil} = state
      ) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Received test input before dispatcher registration: #{inspect(input_data)}",
      %{}
    )

    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:test_input, input_data}, state) do
    # Construct a basic event. Tests might need more specific event types later.
    # We need to parse the input_data into something the MockApp expects.
    Raxol.Core.Runtime.Log.debug(
      "[TerminalDriver.handle_cast - :test_input] Received input_data: #{inspect(input_data)}, state: #{inspect(state)}"
    )

    event = Dispatch.parse_test_input(input_data)

    Raxol.Core.Runtime.Log.debug(
      "[TerminalDriver.handle_cast - :test_input] Parsed event: #{inspect(event)}"
    )

    Raxol.Core.Runtime.Log.debug(
      "[TEST] Dispatching simulated event: #{inspect(event)}"
    )

    _ =
      Backpressure.cast(state.dispatcher_pid, {:dispatch, event},
        label: :driver_input,
        policy: :call_when_full
      )

    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:raw_input, data}, state) when is_binary(data) do
    buffer_and_dispatch(data, state)
  end

  # Trace messages from prim_tty reader — intercept input data
  @impl true
  def handle_manager_info(
        {:trace, _reader, :send, {_ref, {:data, data}}, _to},
        state
      ) do
    binary =
      cond do
        is_binary(data) -> data
        is_list(data) -> IO.iodata_to_binary(data)
        true -> <<>>
      end

    if byte_size(binary) > 0 do
      buffer_and_dispatch(binary, state)
    else
      {:noreply, state}
    end
  end

  # Ignore other trace messages from the reader (signals, receives, etc.)
  @impl true
  def handle_manager_info({:trace, _pid, :send, _msg, _to}, state) do
    {:noreply, state}
  end

  # Port data — accumulate and parse (buffering handles split escape sequences)
  @impl true
  def handle_manager_info({port, {:data, data}}, state) when is_port(port) do
    buffer_and_dispatch(data, state)
  end

  # Flush timer fired — dispatch whatever we have
  @impl true
  def handle_manager_info(:flush_input_buffer, state) do
    flush_buffer(%{state | flush_timer: nil})
  end

  # Port closed
  @impl true
  def handle_manager_info({port, :eof}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({port, {:exit_status, _status}}, state)
      when is_port(port) do
    {:noreply, state}
  end

  # The capabilities probe's clock seam (Probe's moduledoc §1b): the ONE
  # deadline timer scheduled by schedule_capabilities_clock/1 (rescheduled
  # at most once, on the probe's own extend-once rule). Firing this feeds
  # a `{:clock, now}` event to the pure reducer, which finalizes
  # classification whether the probe is still silently :awaiting (past its
  # deadline: silence = defaults, the guard against a terminal that
  # answers nothing at all) or in the post-sentinel :draining window
  # (closes unconditionally on the next clock tick, regardless of the
  # deadline -- same discipline the probe's own clock-seam tests exercise).
  @impl true
  def handle_manager_info(
        :capabilities_probe_clock,
        %{capabilities_probe: %Probe{}} = state
      ) do
    {:noreply, step_capabilities_clock(state)}
  end

  @impl true
  def handle_manager_info(:capabilities_probe_clock, state), do: {:noreply, state}

  @impl true
  def handle_manager_info(unhandled_message, state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "#{__MODULE__} received unhandled message: #{inspect(unhandled_message)}",
      %{}
    )

    {:noreply, state}
  end

  defp buffer_and_dispatch(data, state) do
    buffer = state.input_buffer <> data
    _ = if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    if InputBuffer.incomplete_escape?(buffer) do
      timer =
        Process.send_after(self(), :flush_input_buffer, @input_buffer_flush_ms)

      {:noreply, %{state | input_buffer: buffer, flush_timer: timer}}
    else
      flush_buffer(%{state | input_buffer: buffer, flush_timer: nil})
    end
  end

  defp dispatch_raw_input(data, state) do
    {data, state} = route_capabilities_input(data, state)
    events = parse_input_safely(data)

    Enum.each(events, fn event ->
      case state.dispatcher_pid do
        nil -> :ok
        pid -> Dispatch.send_event_to_dispatcher(pid, event)
      end
    end)

    {:noreply, state}
  end

  # Last-resort net: InputParser.parse/1 is written to be total over the
  # ANSI/CSI grammar, but a parser bug here must never crash the Driver --
  # terminate/2's cleanup write can race supervisor shutdown and take stdio
  # down before the terminal is restored. Drop this chunk rather than crash.
  defp parse_input_safely(data) do
    InputParser.parse(data)
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] InputParser crashed on raw input, dropping this chunk: " <>
          inspect(error),
        %{}
      )

      []
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] InputParser raised #{inspect(kind)} on raw input, dropping this chunk: " <>
          inspect(reason),
        %{}
      )

      []
  end

  # --- Capabilities probe (F0 pipeline): Probe -> ReplyScanner -> Classifier ---
  #
  # Bridges the live driver to the pure `Raxol.Terminal.Capabilities.Probe`
  # reducer -- the same clock-seam design InlineDriver drives synchronously
  # at init, but here async and non-blocking: init returns immediately
  # after the batched write, and replies (interleaved with real keystrokes)
  # arrive as ordinary `handle_manager_info` messages on the same trace/port
  # path that already feeds `dispatch_raw_input/2`. The ONE deadline timer
  # is the sole clock source (see the `:capabilities_probe_clock` handler
  # above); Probe's own extend-once rule is honored via
  # reschedule_capabilities_clock/1 on `{:extend_deadline, _}`.

  # Builds the probe, writes its batched query (+ tmux passthrough re-issue
  # when $TMUX is set -- Probe's own opt-in gate), and arms the deadline
  # timer. Any failure degrades to "no capabilities detected" -- the same
  # fail-open discipline the old OSC 11-only write had -- rather than
  # crashing init or leaving a stray timer/probe behind.
  defp start_capabilities_probe(state) do
    env = System.get_env()

    probe_opts = [
      now_ms: System.monotonic_time(:millisecond),
      tmux_passthrough?: true
    ]

    probe = Probe.new(env, probe_opts)
    {probe, actions} = Probe.step(probe, :start)

    {_leak, state} =
      apply_probe_actions(actions, %{state | capabilities_probe: probe})

    schedule_capabilities_clock(state)
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Failed to start capabilities probe, skipping capability detection: " <>
          inspect(error),
        %{}
      )

      state
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Capabilities probe start raised #{inspect(kind)}, skipping capability detection: " <>
          inspect(reason),
        %{}
      )

      state
  end

  # While a probe is live (`:awaiting`, `:draining`, or even `:done` --
  # Probe.step/2 keeps draining late replies losslessly forever, CAP-N-03),
  # route each raw input chunk through it. Returns `{clean_data, state}`
  # where `clean_data` is exactly the leak-free residual: real keystrokes
  # interleaved with reply bytes, in original order, with every recognized
  # reply frame stripped -- safe to hand to `parse_input_safely/1`. Any
  # exception abandons capability detection (drops the probe from state so
  # later chunks pass straight through) and degrades to passing this chunk
  # through untouched, exactly as the old OSC 11-only scan did.
  defp route_capabilities_input(data, %{capabilities_probe: %Probe{} = probe} = state) do
    {probe, actions} = Probe.step(probe, {:input, data})
    apply_probe_actions(actions, %{state | capabilities_probe: probe})
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Capabilities probe reply scan failed, falling back to no capability detection: " <>
          inspect(error),
        %{}
      )

      {data, %{state | capabilities_probe: nil, capabilities_probe_timer: nil}}
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Capabilities probe reply scan raised #{inspect(kind)}, falling back to no capability detection: " <>
          inspect(reason),
        %{}
      )

      {data, %{state | capabilities_probe: nil, capabilities_probe_timer: nil}}
  end

  defp route_capabilities_input(data, state), do: {data, state}

  # The clock tick: advances the reducer, then applies whatever actions
  # come back (typically just `{:done, caps}` the first time it fires; a
  # stray extra tick after :done is a documented no-op). Any failure
  # abandons capability detection rather than leaving a stale probe/timer.
  defp step_capabilities_clock(%{capabilities_probe: probe} = state) do
    {probe, actions} =
      Probe.step(probe, {:clock, System.monotonic_time(:millisecond)})

    {_leak, state} =
      apply_probe_actions(actions, %{
        state
        | capabilities_probe: probe,
          capabilities_probe_timer: nil
      })

    state
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Capabilities probe clock step failed, capability detection abandoned: " <>
          inspect(error),
        %{}
      )

      %{state | capabilities_probe: nil, capabilities_probe_timer: nil}
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Capabilities probe clock step raised #{inspect(kind)}, capability detection abandoned: " <>
          inspect(reason),
        %{}
      )

      %{state | capabilities_probe: nil, capabilities_probe_timer: nil}
  end

  # Applies a Probe action list left-to-right, threading state and
  # accumulating the leak-free residual. Returns `{leak_free_binary, state}`.
  defp apply_probe_actions(actions, state) do
    Enum.reduce(actions, {<<>>, state}, &apply_probe_action/2)
  end

  defp apply_probe_action({:write, iodata}, {leak, state}) do
    IO.write(iodata)
    {leak, state}
  end

  defp apply_probe_action({:passthrough, iodata}, {leak, state}) do
    IO.write(iodata)
    {leak, state}
  end

  defp apply_probe_action({:extend_deadline, _extend_ms}, {leak, state}) do
    {leak, reschedule_capabilities_clock(state)}
  end

  # CAP-N-03: bytes the scanner determined are NOT part of a capability
  # reply (interleaved real keystrokes) flow into the leak-free residual
  # instead of being silently dropped.
  defp apply_probe_action({:leak_free, binary}, {leak, state}) do
    {leak <> binary, state}
  end

  defp apply_probe_action({:done, caps}, {leak, state}) do
    {leak, finalize_capabilities(caps, state)}
  end

  # Classification completed: cache the session record (write-once,
  # CAP-P-13), preserve both pre-existing OSC 11 side effects for compat
  # (BackgroundQuery.store/1 -- the old persistent_term consumers and the
  # W2c shim fallback both still read through it -- and the
  # `:terminal_background` event), and additionally emit
  # `:terminal_capabilities` carrying the full classified record. Cancels
  # the now-moot deadline timer.
  defp finalize_capabilities(%Capabilities{} = caps, state) do
    Capabilities.cache(caps)

    case caps.background do
      {_, _, _} = rgb ->
        BackgroundQuery.store(rgb)

        dispatch_capabilities_event(state, %Event{
          type: :terminal_background,
          data: %{color: rgb}
        })

      nil ->
        :ok
    end

    dispatch_capabilities_event(state, %Event{
      type: :terminal_capabilities,
      data: %{capabilities: caps}
    })

    cancel_capabilities_timer(state)
  end

  defp dispatch_capabilities_event(%{dispatcher_pid: nil}, _event), do: :ok

  defp dispatch_capabilities_event(%{dispatcher_pid: pid}, event) do
    Dispatch.send_event_to_dispatcher(pid, event)
  end

  # Arms the ONE deadline timer at the probe's current (absolute,
  # monotonic-ms) deadline. A no-op when there is no live probe (e.g. the
  # write failed and start_capabilities_probe/1 left capabilities_probe nil).
  defp schedule_capabilities_clock(%{capabilities_probe: %Probe{deadline: deadline}} = state)
       when is_integer(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    timer = Process.send_after(self(), :capabilities_probe_clock, remaining)
    %{state | capabilities_probe_timer: timer}
  end

  defp schedule_capabilities_clock(state), do: state

  # Probe's extend-once rule (F0 §7 step 3) already updated
  # `probe.deadline` before returning the `{:extend_deadline, _}` action --
  # this just re-arms the ONE timer against that new deadline.
  defp reschedule_capabilities_clock(state) do
    state
    |> cancel_capabilities_timer()
    |> schedule_capabilities_clock()
  end

  defp cancel_capabilities_timer(%{capabilities_probe_timer: nil} = state), do: state

  defp cancel_capabilities_timer(%{capabilities_probe_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | capabilities_probe_timer: nil}
  end

  # Forward cast messages to handle_info for test_input
  @impl true
  def handle_manager_cast({:test_input, input_data}, state) do
    handle_manager_info({:test_input, input_data}, state)
  end

  # Private helper to extract dispatcher_pid from init opts
  defp extract_dispatcher_pid(opts) when is_list(opts) do
    Keyword.get(opts, :dispatcher_pid)
  end

  defp extract_dispatcher_pid(pid) when is_pid(pid), do: pid
  defp extract_dispatcher_pid(_), do: nil

  def terminate(_reason, %{termbox_state: :initialized} = state) do
    Raxol.Core.Runtime.Log.info("Terminal Driver terminating.")
    remove_sigwinch_handler(state)
    TermboxLifecycle.cleanup_terminal(state)
  end

  def terminate(_reason, _state) do
    Raxol.Core.Runtime.Log.info(
      "Terminal Driver terminating (not initialized)."
    )

    :ok
  end

  @doc """
  Processes a terminal title change event.
  """
  def process_title_change(title, state) when is_binary(title) do
    _ =
      if not Env.test?() and has_terminal_device?() do
        if @termbox2_available do
          :termbox2_nif.tb_set_title(title)
        end
      end

    {:noreply, state}
  end

  @doc """
  Processes a terminal position change event.
  """
  def process_position_change(x, y, state)
      when is_integer(x) and is_integer(y) do
    _ =
      if not Env.test?() and has_terminal_device?() do
        if @termbox2_available do
          :termbox2_nif.tb_set_position(x, y)
        else
          0
        end
      end

    {:noreply, state}
  end

  # --- Input reader ---
  # In -noshell mode (mix run), user_drv initializes prim_tty with
  # tty => false, so the reader process never receives select notifications
  # and blocks forever. Trigger a reinit via user_drv:start_shell (which
  # spawns a fresh reader that arms select notifications), then trace the
  # reader's sends to intercept input data before user_drv forwards it.
  defp start_stdin_reader(_driver_pid) do
    # `initial_shell` must be the literal atom `:noshell`, never an MFA
    # (even a no-op one): user_drv only skips shell-spawning when
    # initial_shell =:= :noshell. Any other value falls into
    # init_local_shell/2, which spawns a real shell via group:start/3; that
    # process exits immediately and drops user_drv into its JCL "User
    # switch command" prompt, which swallows every subsequent stdin byte
    # (including the terminal's OSC 11 / DA reply) as a job-control command
    # instead of forwarding it, and can bring the node down before a frame
    # ever renders.
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

    # Re-fetch after the reinit above: input=>raw may (re)spawn the reader.
    reader = Process.whereis(:user_drv_reader)

    if reader do
      # Trace the reader's sends to intercept data before user_drv
      # forwards it. The reader sends {ref, {:data, bytes}} to user_drv.
      :erlang.trace(reader, true, [:send])

      # :noshell means user_drv never issues the one-time read kick a real
      # shell gets on startup (prim_tty:read/1 via init_shell/2), so the
      # reader arms a select notification and then idles forever -- no
      # crash, no keystrokes. Send the kick ourselves; :infinity makes it
      # self-sustaining (the reader re-arms to :infinity after every read).
      send(reader, {:read, :infinity})
    end

    # No spawned reader pid to track -- input arrives via trace messages
    # in handle_manager_info.
    nil
  end

  # --- SIGWINCH subscription ---
  # OTP's prim_tty delivers SIGWINCH from :erl_signal_server straight to
  # user_drv (not through the reader we trace), so we install our own
  # gen_event handler that pings this process on window resize.

  defp install_sigwinch_handler do
    handler_id = {Raxol.Terminal.Driver.SigwinchHandler, self()}

    case :gen_event.add_handler(
           :erl_signal_server,
           handler_id,
           %{driver: self()}
         ) do
      :ok ->
        handler_id

      other ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[Driver] Could not install SIGWINCH handler (window resize " <>
            "events disabled): #{inspect(other)}",
          %{}
        )

        nil
    end
  catch
    _, _ -> nil
  end

  defp remove_sigwinch_handler(%{sigwinch_handler: nil}), do: :ok

  defp remove_sigwinch_handler(%{sigwinch_handler: handler_id}) do
    _ = :gen_event.delete_handler(:erl_signal_server, handler_id, :normal)
    :ok
  catch
    _, _ -> :ok
  end

  # --- Input buffering ---
  # Escape sequences may span multiple messages, so we buffer until complete.

  defp flush_buffer(%{input_buffer: <<>>} = state), do: {:noreply, state}

  defp flush_buffer(state) do
    dispatch_raw_input(state.input_buffer, %{state | input_buffer: <<>>})
  end
end
