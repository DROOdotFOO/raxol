defmodule Raxol.Recording.Index do
  @moduledoc """
  Keyframe index over a recorded session, so seeking is not a prefix replay.

  Without an index, reconstructing the screen at time `t` means feeding every
  output event from the start of the recording into an emulator: O(n) per seek,
  which makes a drag-scrub over a long recording unusable. This module walks the
  session once, snapshots the terminal at fixed time intervals, and then answers
  "what did the screen look like at `t`?" by starting from the nearest snapshot
  at or before `t` and replaying forward only.

  The replay path is the one `Raxol.Test.CrossTerminal.AnsiReplayer` established:
  `Raxol.Terminal.Emulator.new/2` -> `process_input/2` -> `get_screen_buffer/1`.

  ## What a keyframe carries

  A keyframe holds both a `:buffer` (a plain `Raxol.Core.Buffer` map, which is
  what `Raxol.LiveView.TerminalBridge` and `Raxol.Core.Renderer` render) and the
  `:emulator` it came from. The emulator is not redundant: resuming a replay
  needs the cursor position, pending SGR attributes, scroll region, and charset
  state, none of which survive in a screen buffer. Rendering wants the buffer;
  seeking wants the emulator.

      index = Index.build(session)
      Index.buffer_at(index, session, 42_000_000)
      Index.keyframe_before(index, 42_000_000).us

  ## Usage

      iex> session = %Raxol.Recording.Session{width: 80, height: 24, events: []}
      iex> index = Raxol.Recording.Index.build(session)
      iex> {length(index.keyframes), index.marks, index.duration_us}
      {1, [], 0}
  """

  alias Raxol.Recording.Session
  alias Raxol.Terminal.Emulator

  # Keyframe spacing is a memory-for-seek-work trade, and memory is the
  # expensive side: a keyframe pins an emulator plus its rendered buffer, 628 KB
  # standalone at 80x24 (519 KB of that is the emulator, which carries both the
  # main and alternate screen buffers). Keyframes share cell text and style
  # terms with each other, so the marginal cost measured over a whole index is
  # ~280 KB. For a 5-minute 80x24 recording at 10 fps (3000 output events,
  # 59 KB of ANSI):
  #
  #     interval   keyframes   index size   forward replay per seek
  #        1 s        300        ~84 MB          10 output events
  #        5 s         60        ~17 MB          50
  #       15 s         20        5.6 MB         150 (measured: 320 ms)
  #       30 s         10        ~2.8 MB        300
  #
  # The 5.6 MB and 320 ms rows are measured; the others scale from them. Memory
  # decides this: an index outlives every seek made against it and a replay
  # server may hold several, while the forward replay is bounded work paid once
  # per scrub step and shrinks linearly if a scrub-heavy surface passes a
  # smaller `:interval_us`. Below ~5 s the index outweighs the recording it
  # indexes by three orders of magnitude, which is indefensible for a file that
  # is 59 KB on disk. 15 s keeps a 5-minute recording under 6 MB.
  #
  # `Raxol.Recording.Player` is insensitive to the interval: its indexed seek
  # writes the keyframe repaint plus the recorded bytes since it (3.6 KB
  # measured, against 54 KB for a prefix replay) and never runs the emulator.
  @default_interval_us 15_000_000

  @default_width 80
  @default_height 24

  @type keyframe :: %{
          us: non_neg_integer(),
          event_index: non_neg_integer(),
          buffer: Raxol.Core.Buffer.t(),
          emulator: Emulator.t()
        }

  @type t :: %{
          keyframes: [keyframe()],
          marks: [non_neg_integer()],
          duration_us: non_neg_integer(),
          event_count: non_neg_integer(),
          interval_us: pos_integer(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc """
  Builds a keyframe index for a session.

  ## Options

    * `:interval_us` - minimum spacing between keyframes in microseconds
      (default: #{@default_interval_us}). See the module docs for the trade-off.
    * `:width` / `:height` - terminal size (default: the session header's).
  """
  @spec build(Session.t(), keyword()) :: t()
  def build(%Session{} = session, opts \\ []) do
    width = Keyword.get(opts, :width) || session.width || @default_width
    height = Keyword.get(opts, :height) || session.height || @default_height
    interval_us = Keyword.get(opts, :interval_us, @default_interval_us)

    emulator = Emulator.new(width, height)
    first = keyframe(0, 0, emulator)

    keyframes =
      session.events
      |> Enum.with_index()
      |> Enum.reduce(
        {[first], emulator, interval_us},
        &collect_keyframe(&1, &2, interval_us)
      )
      |> elem(0)
      |> Enum.reverse()

    %{
      keyframes: keyframes,
      marks: marks(session.events),
      duration_us: duration_us(session.events),
      event_count: length(session.events),
      interval_us: interval_us,
      width: width,
      height: height
    }
  end

  @doc """
  Nearest keyframe at or before `us`.

  Always succeeds: `us: 0` is always a keyframe, so a time before the first
  event still resolves (to the blank screen the recording started from).
  """
  @spec keyframe_before(t(), non_neg_integer()) :: keyframe()
  def keyframe_before(%{keyframes: [first | _] = keyframes}, us)
      when is_integer(us) and us >= 0 do
    Enum.reduce_while(keyframes, first, fn candidate, acc ->
      if candidate.us <= us, do: {:cont, candidate}, else: {:halt, acc}
    end)
  end

  @doc """
  Screen state at an arbitrary time: nearest keyframe, then forward replay only.

  Matches `Raxol.Recording.Player`'s seek semantics — every output event with
  `elapsed_us < us` is applied, events at exactly `us` are not — so a seek
  through the index lands on the same screen as a seek without one. Times past
  the end of the recording return the final screen.
  """
  @spec buffer_at(t(), Session.t(), non_neg_integer()) :: Raxol.Core.Buffer.t()
  def buffer_at(%{} = index, %Session{} = session, us)
      when is_integer(us) and us >= 0 do
    keyframe = keyframe_before(index, us)

    case pending_output(session.events, keyframe.event_index, us) do
      "" -> keyframe.buffer
      data -> snapshot(process(keyframe.emulator, data))
    end
  end

  @doc """
  Captures an emulator's visible screen as a `Raxol.Core.Buffer` map.

  Exposed because the index is not the only consumer: a live replay surface
  holds its own emulator and needs the same conversion to render, and tests
  compare an indexed seek against a full prefix replay through it.
  """
  @spec snapshot(Emulator.t()) :: Raxol.Core.Buffer.t()
  def snapshot(emulator) do
    screen = Emulator.get_screen_buffer(emulator)
    rows = screen.cells || []

    lines =
      Enum.map(rows, fn row ->
        %{cells: Enum.map(row, &convert_cell/1)}
      end)

    %{
      width: screen.width,
      height: screen.height,
      lines: lines,
      cells: []
    }
  end

  @doc """
  Approximate heap size of an index in bytes.

  Uses `:erts_debug.size_shared/1`, so terms the keyframes share (cell text,
  style maps, the buffer nested inside its emulator) are counted once. Reported
  by `mix raxol.replay --info --index` so the cost is visible before anyone
  builds an index for a huge recording.
  """
  @spec memory_bytes(t()) :: non_neg_integer()
  def memory_bytes(%{} = index) do
    :erts_debug.size_shared(index) * :erlang.system_info(:wordsize)
  end

  # `:input` events are the moments a human typed: the natural jump targets, and
  # what `Raxol.UI.Components.Input.Scrubber` draws as track marks. Kept in the
  # index so the terminal player and the web replay mark the same instants.
  @spec marks([Session.event()]) :: [non_neg_integer()]
  defp marks(events) do
    Enum.flat_map(events, fn
      {us, :input, _data} -> [us]
      _other -> []
    end)
  end

  # Only output events are snapshot points: input events leave the screen
  # untouched, so a keyframe there would cost a full buffer and save nothing.
  # Advancing the next boundary from the event's own timestamp (not from the
  # boundary) keeps at most one keyframe per timestamp, which is what makes
  # `event_index` unambiguous when several events share a microsecond.
  defp collect_keyframe(
         {{us, :output, data}, event_index},
         {keyframes, emulator, next_us},
         interval_us
       )
       when us >= next_us do
    keyframes = [keyframe(us, event_index, emulator) | keyframes]
    {keyframes, process(emulator, data), us + interval_us}
  end

  defp collect_keyframe(
         {{_us, :output, data}, _event_index},
         {keyframes, emulator, next_us},
         _interval_us
       ) do
    {keyframes, process(emulator, data), next_us}
  end

  defp collect_keyframe({_input_event, _event_index}, acc, _interval_us),
    do: acc

  defp keyframe(us, event_index, emulator) do
    %{
      us: us,
      event_index: event_index,
      buffer: snapshot(emulator),
      emulator: emulator
    }
  end

  defp process(emulator, data) do
    {emulator, _output} = Emulator.process_input(emulator, data)
    emulator
  end

  # Output bytes between a keyframe and `us`, concatenated: one
  # `process_input/2` call is cheaper than one per event and the parser state
  # carries across a chunk boundary anyway.
  defp pending_output(events, from_index, us) do
    events
    |> Enum.drop(from_index)
    |> Enum.reduce_while([], fn
      {event_us, _type, _data}, acc when event_us >= us -> {:halt, acc}
      {_us, :output, data}, acc -> {:cont, [data | acc]}
      _input, acc -> {:cont, acc}
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp convert_cell(cell) do
    %{char: cell.char || " ", style: convert_style(cell.style)}
  end

  # The emulator styles cells with a `TextFormatting` struct; the buffer/renderer
  # side reads styles with the Access syntax (`style[:bold]`), which structs do
  # not support. Unstyled cells normalize to exactly the blank style
  # `Raxol.Core.Buffer.create_blank_buffer/2` uses, so a diff against a blank
  # buffer collapses untouched rows instead of rewriting every cell.
  @blank_style %{fg_color: nil, bg_color: nil, bold: false}

  defp convert_style(nil), do: @blank_style

  defp convert_style(style) do
    converted = %{
      fg_color: Map.get(style, :foreground),
      bg_color: Map.get(style, :background),
      bold: Map.get(style, :bold, false),
      italic: Map.get(style, :italic, false),
      underline: Map.get(style, :underline, false),
      reverse: Map.get(style, :reverse, false),
      strikethrough: Map.get(style, :strikethrough, false),
      hyperlink: Map.get(style, :hyperlink)
    }

    if blank?(converted), do: @blank_style, else: converted
  end

  defp blank?(style) do
    is_nil(style.fg_color) and is_nil(style.bg_color) and
      is_nil(style.hyperlink) and
      not (style.bold or style.italic or style.underline or style.reverse or
             style.strikethrough)
  end

  defp duration_us([]), do: 0

  defp duration_us(events) do
    {us, _type, _data} = List.last(events)
    us
  end
end
