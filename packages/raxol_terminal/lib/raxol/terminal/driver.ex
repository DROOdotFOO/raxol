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
              bg_query_pending: false
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

        # Enter alternate screen, hide cursor
        IO.write("\e[?1049h\e[?25l")

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

        # Query the terminal background (OSC 11) with a DA probe as the
        # unsupported-terminal sentinel; replies are extracted from the
        # input stream in dispatch_raw_input/2. Written only after the
        # stdin reader is activated: writing it earlier raced the prim_tty
        # tty=>true reinit that start_stdin_reader triggers (via
        # user_drv's :start_shell), corrupting job control and crashing
        # the whole node before a frame ever rendered. Any failure here
        # degrades to "no background detected" rather than crashing init.
        bg_query_pending = write_background_query()

        state = %{
          state
          | termbox_state: :initialized,
            bg_query_pending: bg_query_pending,
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
    {data, state} = handle_bg_query_reply(data, state)
    events = InputParser.parse(data)

    Enum.each(events, fn event ->
      case state.dispatcher_pid do
        nil -> :ok
        pid -> Dispatch.send_event_to_dispatcher(pid, event)
      end
    end)

    {:noreply, state}
  end

  # Writes the OSC 11 background query and returns whether a reply should
  # be awaited. On any failure (e.g. stdio unavailable), skip the query
  # entirely rather than leave the driver waiting on a reply that will
  # never come or crashing init — background detection simply falls back
  # to "no background detected" (BackgroundQuery.detected_background/0
  # returns :error, and callers ground on that).
  defp write_background_query do
    IO.write(BackgroundQuery.query_sequence())
    true
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] Failed to write OSC 11 background query, skipping background detection: " <>
          inspect(error),
        %{}
      )

      false
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] OSC 11 background query write raised #{inspect(kind)}, skipping background detection: " <>
          inspect(reason),
        %{}
      )

      false
  end

  # While an OSC 11 background query is pending, extract its reply (and the
  # DA probe reply) from the input stream so they never reach the key parser.
  # Fail-safe by construction: any exception while scanning/parsing the
  # reply degrades to "no background detected" and passes the raw chunk
  # through untouched, so a malformed or unexpected reply can never crash
  # the driver or block real input from reaching the key parser.
  defp handle_bg_query_reply(data, %{bg_query_pending: true} = state) do
    case BackgroundQuery.scan(data) do
      {{:ok, rgb}, cleaned} ->
        BackgroundQuery.store(rgb)

        if state.dispatcher_pid do
          Dispatch.send_event_to_dispatcher(
            state.dispatcher_pid,
            %Event{type: :terminal_background, data: %{color: rgb}}
          )
        end

        {cleaned, %{state | bg_query_pending: false}}

      {:unsupported, cleaned} ->
        {cleaned, %{state | bg_query_pending: false}}

      {:pending, data} ->
        {data, state}
    end
  rescue
    error ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] OSC 11 reply scan failed, falling back to no background detected: " <>
          inspect(error),
        %{}
      )

      {data, %{state | bg_query_pending: false}}
  catch
    kind, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "[Driver] OSC 11 reply scan raised #{inspect(kind)}, falling back to no background detected: " <>
          inspect(reason),
        %{}
      )

      {data, %{state | bg_query_pending: false}}
  end

  defp handle_bg_query_reply(data, state), do: {data, state}

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
  # In -noshell mode (mix run), prim_tty is initialized with tty => false,
  # so its reader process never receives select notifications. We trigger
  # reinit via user_drv:start_shell, then trace-intercept the reader's
  # data messages.
  defp start_stdin_reader(_driver_pid) do
    # In -noshell mode, user_drv initializes prim_tty with tty => false,
    # so the NIF never sets up the terminal fd for select notifications.
    # The reader process exists but is blocked waiting for events that
    # never arrive.
    #
    # Fix: call user_drv:start_shell to trigger prim_tty:reinit with
    # input => raw, which spawns a fresh prim_tty reader that immediately
    # arms select notifications on the terminal fd (see prim_tty:reader/3,
    # which calls tty_select/2 before init_ack). Then trace the reader to
    # intercept input data before it reaches user_drv.
    #
    # IMPORTANT: `initial_shell` must be the literal atom `:noshell`, never
    # an MFA (even a no-op one). user_drv's {start_shell, Args} handler only
    # takes the "no shell" branch (init_noshell/1, which spawns nothing) when
    # initial_shell =:= noshell; any other value — including a custom MFA
    # that returns immediately — falls into init_local_shell/2, which spawns
    # a real shell process via `group:start/3`. That process exits the
    # instant our MFA returns, and user_drv reacts by printing
    # "*** ERROR: Shell process terminated! (^G to start new job) ***" and
    # dropping into its JCL "User switch command -->" prompt for the rest of
    # the session. From then on every byte we read from stdin — including
    # the terminal's own reply to our OSC 11 / DA startup query — is
    # interpreted as a job-control command instead of reaching our trace,
    # and the JCL handler killing/reassigning stdio brings the whole node
    # down before a frame ever renders. Passing `:noshell` here skips shell
    # spawning entirely: no process to die, no JCL prompt, no hijacked
    # input. See packages/raxol_terminal/test/raxol/terminal/driver_init_order_test.exs
    # for the accompanying regression test.
    #
    # Second gotcha: `:noshell` means user_drv never calls the one-time
    # `prim_tty:read(tty)` kick that a real shell gets via init_shell/2
    # (`[prim_tty:read(tty) || shell_started =/= false]` — for :noshell
    # `shell_started` is permanently `false`, so that comprehension is a
    # no-op). Without that kick the reader process arms a select
    # notification, flags itself ready, and then just idles forever: per
    # prim_tty's reader_loop/2, an actual read only happens in response to
    # an explicit `{read, N}` message, and nothing ever sends one in
    # noshell mode. That reads as "no crash, but no keystrokes either" —
    # easy to miss because rendering still happens (the initial frame
    # doesn't depend on stdin). We replicate the kick ourselves by sending
    # `{:read, :infinity}` straight to the reader pid, exactly what
    # prim_tty:read/1 does internally; the reader has no sender guard on
    # that message, and `:infinity` makes it self-sustaining (it re-arms
    # to `:infinity` after every read, see prim_tty's reader_read/2).
    user_drv = Process.whereis(:user_drv)

    if user_drv do
      # Activate the terminal fd by triggering prim_tty reinit, without
      # spawning any shell process (see comment above for why).
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

      # Kick the reader into continuous-read mode (see comment above) —
      # without this, :noshell leaves it armed-but-idle and no keystroke
      # ever arrives.
      send(reader, {:read, :infinity})
    end

    # Return nil — no spawned reader pid to track. Input arrives via
    # trace messages in handle_manager_info.
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
