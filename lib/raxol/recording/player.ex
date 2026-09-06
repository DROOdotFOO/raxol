defmodule Raxol.Recording.Player do
  @moduledoc """
  Replays recorded terminal sessions from `.cast` files.

  Writes output events to the terminal at their recorded timing,
  with interactive controls for pause, speed, seek, and quit.

  ## Usage

      Player.play("demo.cast")
      Player.play("demo.cast", speed: 2.0)
      Player.play(session, speed: 0.5, max_delay: 3.0)

  ## Controls during playback

    * `space` - Pause / resume
    * `+` / `=` - Increase speed (1x -> 2x -> 4x -> 8x)
    * `-` - Decrease speed (8x -> 4x -> 2x -> 1x -> 0.5x -> 0.25x)
    * `>` / `.` - Skip forward 5 seconds
    * `<` / `,` - Skip backward 5 seconds
    * `0`..`9` - Jump to 0%-90% of recording
    * `q` / `ESC` - Quit
  """

  alias Raxol.Core.Buffer
  alias Raxol.Core.Renderer
  alias Raxol.Recording.{Asciicast, Index, Session}
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.Components.Input.Scrubber

  @default_speed 1.0
  @default_max_delay 5.0
  @speed_steps [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
  @seek_step_us 5_000_000
  @status_hints "space:pause +/-:speed </>:seek q:quit"
  @min_track 3
  @max_track 40

  @doc """
  Plays a .cast file or session struct.

  ## Options

    * `:speed` - Playback speed multiplier (default: 1.0). 2.0 = double speed.
    * `:max_delay` - Cap on delay between events in seconds (default: 5.0).
    * `:interactive` - Enable keyboard controls (default: true).
    * `:index` - A `Raxol.Recording.Index` for the same session. Optional: with
      no index, seeking replays the recording's prefix from the start, which is
      O(n) per seek. With one, a seek repaints from the nearest keyframe.
  """
  @spec play(Path.t() | Session.t(), keyword()) :: :ok | {:error, term()}
  def play(path_or_session, opts \\ [])

  def play(path, opts) when is_binary(path) do
    case Asciicast.read(path) do
      {:ok, session} -> play(session, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def play(%Session{} = session, opts) do
    interactive = Keyword.get(opts, :interactive, true)

    if interactive do
      play_interactive(session, opts)
    else
      play_simple(session, opts)
    end
  end

  # -- Simple (non-interactive) playback --

  defp play_simple(%Session{} = session, opts) do
    speed = Keyword.get(opts, :speed, @default_speed)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)

    enter_alt_screen(session)
    play_events_simple(session.events, 0, speed, max_delay)
    leave_alt_screen()

    :ok
  end

  defp play_events_simple([], _prev_us, _speed, _max_delay), do: :ok

  defp play_events_simple(
         [{elapsed_us, :output, data} | rest],
         prev_us,
         speed,
         max_delay
       ) do
    delay_us = elapsed_us - prev_us
    delay_ms = round(delay_us / 1_000 / speed)
    max_delay_ms = round(max_delay * 1_000)

    if delay_ms > 0 do
      Process.sleep(min(delay_ms, max_delay_ms))
    end

    IO.write(data)
    play_events_simple(rest, elapsed_us, speed, max_delay)
  end

  defp play_events_simple([_ | rest], prev_us, speed, max_delay) do
    play_events_simple(rest, prev_us, speed, max_delay)
  end

  # -- Interactive playback --

  defp play_interactive(%Session{} = session, opts) do
    speed = Keyword.get(opts, :speed, @default_speed)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    events = session.events
    total_us = total_duration_us(events)

    state = %{
      events: events,
      event_count: length(events),
      index: 0,
      speed: speed,
      max_delay: max_delay,
      paused: false,
      total_us: total_us,
      input_marks: input_marks(events),
      keyframe_index: Keyword.get(opts, :index),
      session: session
    }

    enter_alt_screen(session)
    old_settings = set_raw_mode()
    reader = start_input_reader()

    try do
      show_status_bar(state)
      loop(state)
    after
      Process.unlink(reader)
      Process.exit(reader, :kill)
      restore_terminal(old_settings)
      leave_alt_screen()
    end

    :ok
  end

  defp loop(%{index: idx, event_count: count}) when idx >= count, do: :ok

  defp loop(%{paused: true} = state) do
    case read_key(100) do
      :none -> loop(state)
      key -> handle_key(key, state)
    end
  end

  defp loop(state) do
    {elapsed_us, :output, data} = current_event(state)
    prev_us = prev_elapsed_us(state)

    delay_us = elapsed_us - prev_us
    delay_ms = round(delay_us / 1_000 / state.speed)
    max_delay_ms = round(state.max_delay * 1_000)
    actual_delay = Raxol.Core.Utils.Math.clamp(delay_ms, 0, max_delay_ms)

    case wait_with_input(actual_delay) do
      :timeout ->
        IO.write(data)
        %{state | index: state.index + 1} |> continue()

      key ->
        handle_key(key, state)
    end
  end

  defp handle_key(:quit, _state), do: :ok
  defp handle_key(:unknown, state), do: loop(state)

  defp handle_key(:pause, state),
    do: %{state | paused: !state.paused} |> continue()

  defp handle_key(:speed_up, state),
    do: %{state | speed: next_speed(state.speed)} |> continue()

  defp handle_key(:speed_down, state),
    do: %{state | speed: prev_speed(state.speed)} |> continue()

  defp handle_key(:seek_forward, state),
    do: seek(state, @seek_step_us) |> continue()

  defp handle_key(:seek_backward, state),
    do: seek(state, -@seek_step_us) |> continue()

  defp handle_key({:jump, pct}, state),
    do: jump_to_percent(state, pct) |> continue()

  defp continue(state) do
    show_status_bar(state)
    loop(state)
  end

  # -- Seeking --

  defp seek(state, delta_us) do
    current_us = current_elapsed_us(state)
    target_us = current_us + delta_us
    jump_to_us(state, target_us)
  end

  defp jump_to_percent(state, pct) do
    target_us = round(state.total_us * pct / 100)
    jump_to_us(state, target_us)
  end

  @doc false
  @spec jump_to_us(map(), integer()) :: map()
  def jump_to_us(state, target_us) do
    target_us = Raxol.Core.Utils.Math.clamp(target_us, 0, state.total_us)

    idx =
      Enum.find_index(state.events, fn {elapsed_us, _, _} ->
        elapsed_us >= target_us
      end) || state.event_count

    repaint(state, target_us, idx)

    %{state | index: idx}
  end

  # No index: nothing to seek from, so clear the screen and rewrite every
  # output event from the start of the recording. O(n) per seek.
  defp repaint(%{keyframe_index: nil} = state, _target_us, idx) do
    IO.write("\e[2J\e[H")

    state.events
    |> Enum.take(idx)
    |> Enum.each(fn
      {_, :output, data} -> IO.write(data)
      _ -> :ok
    end)
  end

  # With an index, the nearest keyframe replaces the prefix: paint that
  # keyframe, then write only the recorded bytes between it and the target. The
  # bytes are the recording's own, so cursor, pending SGR state, and scroll
  # region past the keyframe are byte-exact rather than reconstructed, and the
  # emulator never runs during a seek.
  #
  # The keyframe itself is painted as a diff from blank, which positions every
  # row absolutely: raw mode strips the CR from a bare "\n", so a line-joined
  # paint would stagger down the screen. The cursor is then put where the
  # recording had it at the keyframe, which matters when the target lands on
  # the keyframe and no bytes follow to move it.
  defp repaint(%{keyframe_index: index} = state, target_us, idx) do
    keyframe = Index.keyframe_before(index, target_us)
    blank = Buffer.create_blank_buffer(index.width, index.height)
    {row, col} = Emulator.get_cursor_position(keyframe.emulator)

    paint =
      blank
      |> Renderer.render_diff(keyframe.buffer)
      |> Renderer.apply_diff()

    forward =
      state.events
      |> Enum.slice(keyframe.event_index, max(idx - keyframe.event_index, 0))
      |> Enum.flat_map(fn
        {_us, :output, data} -> [data]
        _input -> []
      end)

    IO.write([
      "\e[2J\e[H",
      paint,
      "\e[0m\e[#{row + 1};#{col + 1}H"
      | forward
    ])
  end

  # -- Key reading --
  #
  # A linked reader process calls IO.getn (blocking) and sends bytes to us.
  # We consume them via receive with a timeout, giving responsive key handling
  # without an invalid IO.getn/3 timeout argument.

  defp start_input_reader do
    parent = self()
    spawn_link(fn -> input_reader_loop(parent) end)
  end

  defp input_reader_loop(parent) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:input_byte, :eof})

      <<byte>> ->
        send(parent, {:input_byte, byte})
        input_reader_loop(parent)

      str when is_binary(str) and byte_size(str) > 0 ->
        send(parent, {:input_byte, :binary.first(str)})
        input_reader_loop(parent)

      _ ->
        input_reader_loop(parent)
    end
  end

  defp wait_with_input(0), do: :timeout

  defp wait_with_input(delay_ms) do
    chunk = min(delay_ms, 50)

    case read_key(chunk) do
      :none when delay_ms <= chunk -> :timeout
      :none -> wait_with_input(delay_ms - chunk)
      key -> key
    end
  end

  defp read_key(timeout_ms) do
    receive do
      {:input_byte, :eof} -> :quit
      {:input_byte, <<char>>} -> parse_key(char)
      {:input_byte, char} when is_integer(char) -> parse_key(char)
    after
      timeout_ms -> :none
    end
  end

  @key_map %{
    ?q => :quit,
    ?\e => :quit,
    ?\s => :pause,
    ?+ => :speed_up,
    ?= => :speed_up,
    ?- => :speed_down,
    ?> => :seek_forward,
    ?. => :seek_forward,
    ?< => :seek_backward,
    ?, => :seek_backward
  }

  defp parse_key(char) when is_map_key(@key_map, char), do: @key_map[char]
  defp parse_key(char) when char in ?0..?9, do: {:jump, (char - ?0) * 10}
  defp parse_key(_char), do: :unknown

  # -- Speed steps --

  defp next_speed(current) do
    @speed_steps
    |> Enum.find(current, fn s -> s > current end)
  end

  defp prev_speed(current) do
    @speed_steps
    |> Enum.reverse()
    |> Enum.find(current, fn s -> s < current end)
  end

  # -- Status bar --
  #
  # The clock, track, transport glyph, and speed all come from
  # `Raxol.UI.Components.Input.Scrubber`, the widget the time-travel debugger
  # and the web replay also render. Only the key hints below are the
  # player's own. The transport glyph replaces the old " [PAUSED]" text and
  # the track replaces the old "(33%)": both said the same thing twice.

  defp show_status_bar(state) do
    IO.write(
      "\e7\e[#{state.session.height};1H\e[7m#{status_bar(state)}\e[0m\e8"
    )
  end

  @doc false
  @spec status_bar(map()) :: String.t()
  def status_bar(state) do
    width = state.session.width
    props = scrubber_props(state)

    # The chrome around the track is not a constant: the clock widens with
    # the recording's length and the speed label disappears at 1x. Render
    # once at the minimum track width to measure it, then spend whatever
    # columns are left on the track itself.
    chrome =
      String.length(Scrubber.line(props)) - @min_track +
        String.length(@status_hints) + 4

    track_width =
      Raxol.Core.Utils.Math.clamp(width - chrome, @min_track, @max_track)

    bar =
      " " <>
        Scrubber.line(%{props | width: track_width}) <>
        " | " <> @status_hints

    bar |> String.slice(0, width) |> String.pad_trailing(width)
  end

  defp scrubber_props(state) do
    %{
      min: 0,
      max: max(state.event_count - 1, 0),
      position: state.index,
      playing?: not state.paused,
      speed: state.speed,
      elapsed_ms: div(current_elapsed_us(state), 1_000),
      duration_ms: div(state.total_us, 1_000),
      marks: state.input_marks,
      width: @min_track
    }
  end

  # `:input` events are the moments a human typed. In a recording those are
  # the natural jump targets -- the boundaries between "someone is showing
  # you something" and "output is scrolling past" -- so they are what the
  # track ticks. Computed once per playback, not per status-bar repaint.
  @doc false
  @spec input_marks([Session.event()]) :: [non_neg_integer()]
  def input_marks(events) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{_us, :input, _data}, index} -> [index]
      _other -> []
    end)
  end

  # -- Event helpers --

  defp current_event(%{events: events, index: idx}), do: Enum.at(events, idx)

  defp current_elapsed_us(%{index: idx, event_count: count, events: events})
       when idx >= count do
    case List.last(events) do
      {us, _, _} -> us
      nil -> 0
    end
  end

  defp current_elapsed_us(%{events: events, index: idx}) do
    {us, _, _} = Enum.at(events, idx)
    us
  end

  defp prev_elapsed_us(%{index: 0}), do: 0

  defp prev_elapsed_us(%{events: events, index: idx}) do
    {us, _, _} = Enum.at(events, idx - 1)
    us
  end

  defp total_duration_us([]), do: 0

  defp total_duration_us(events) do
    {us, _, _} = List.last(events)
    us
  end

  # -- Terminal mode --

  defp set_raw_mode do
    old =
      System.cmd("stty", ["-g"], stderr_to_stdout: true)
      |> elem(0)
      |> String.trim()

    _ = System.cmd("stty", ["raw", "-echo"], stderr_to_stdout: true)
    # Hide cursor
    IO.write("\e[?25l")
    old
  end

  defp restore_terminal(old_settings) do
    IO.write("\e[?25h")
    _ = System.cmd("stty", [old_settings], stderr_to_stdout: true)
    :ok
  end

  # -- Screen management --

  defp enter_alt_screen(%Session{width: w, height: h}) do
    IO.write("\e[?1049h")
    IO.write("\e[2J\e[H")
    IO.write("\e[8;#{h};#{w}t")
  end

  defp leave_alt_screen do
    IO.write("\e[?1049l")
  end
end
