# Generates the recorded session raxol.io replays at /replay:
#
#   web/priv/recordings/tour.cast  -- asciicast v2, the bytes a real
#                                     Raxol.Headless run of the app below
#                                     emitted, frame by frame
#
# Run from web/, like the frame generator, so the same project's deps are
# loadable:
#
#   cd web && mix run ../scripts/gen_replay_recording.exs
#   cd web && MIX_ENV=dev mix run ../scripts/gen_replay_recording.exs --check
#
# `--check` is the drift gate, not a dry run: it re-records to a scratch path
# and byte-compares, so a difference means a source change nobody re-recorded.
# The output path resolves from __DIR__, so the working directory only decides
# which deps are loadable.
#
# ## Why the recorder is not in this loop
#
# `Raxol.Recording.Recorder` is what a live `mix raxol.record` session feeds:
# `Raxol.Core.Runtime.Rendering.Backends.render_to_terminal/2` hands it every
# frame it writes. That path needs a terminal, and it cannot be driven
# headlessly for two independent reasons:
#
#   * `Raxol.Headless` boots in the `:agent` environment precisely so nothing
#     writes to a tty, so `render_to_terminal/2` never runs and the recorder
#     would collect an empty session.
#
#   * the recorder timestamps each event off `System.monotonic_time/1`, so its
#     timestamps record how fast this script happened to run. A committed
#     artifact stamped that way can never be checked for drift, which is the
#     same trap `gen_landing_frames.exs` documents for `Process.sleep/1`
#     sampling.
#
# So the frames are captured from a driven headless session and the events are
# stamped on the application's OWN tick: event `n` at `n * tick_ms`. The bytes
# are not synthesized: each frame goes through `build_terminal_frame/4`, the
# function `render_to_terminal/2` hands the recorder, with the same
# `style_batching: true` renderer a real session uses. What differs from a live
# recording is only which clock the timestamps come from.

alias Raxol.Core.Runtime.Rendering.Backends
alias Raxol.Recording.{Asciicast, Session}
alias Raxol.Terminal.Renderer

# The app being recorded. A real TEA application: it folds an interval message,
# reacts to keys, and is rendered by the real runtime rather than by this
# script. Pure in `t` and `cursor`, which is what makes the recording
# reproducible.
defmodule ReplayTour do
  use Raxol.Core.Runtime.Application

  # {suite, test count}. Runs left to right, @ticks_per_suite ticks each.
  @suites [
    {"core", 148},
    {"terminal", 96},
    {"liveview", 41},
    {"agent", 73},
    {"payments", 22}
  ]

  @ticks_per_suite 6
  @bar_width 22
  @tick_ms 120
  @rule String.duplicate("-", 62)

  def tick_ms, do: @tick_ms
  def total_ticks, do: length(@suites) * @ticks_per_suite

  def init(_), do: %{t: 0, cursor: 0}

  def update(:tick, model), do: {%{model | t: model.t + 1}, []}

  def update(
        %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}},
        model
      )
      when char in ["j", "k"] do
    delta = if char == "j", do: 1, else: -1
    {%{model | cursor: clamp(model.cursor + delta)}, []}
  end

  def update(_message, model), do: {model, []}

  def subscribe(_model), do: [subscribe_interval(@tick_ms, :tick)]

  def view(model) do
    column(do: lines(model))
  end

  # Colour is only spent where it carries the state: green for a finished
  # suite, yellow for the one running. The rules and a pending suite take the
  # terminal's default foreground rather than :blue, which is unreadable
  # against a dark theme's background on the web surface.
  defp lines(model) do
    [
      text("raxol test run", fg: :cyan, style: [:bold]),
      text(@rule)
    ] ++
      Enum.with_index(@suites, &suite_line(&1, &2, model)) ++
      [
        text(@rule),
        text(summary(model), fg: :magenta),
        text("j/k select suite", fg: :cyan)
      ]
  end

  defp suite_line({name, count}, i, model) do
    ratio = ratio(model.t, i)
    mark = if i == model.cursor, do: ">", else: " "

    line =
      "#{mark} #{String.pad_trailing(name, 10)} #{bar(ratio)} " <>
        "#{String.pad_leading(to_string(passed(count, ratio)), 3)}/#{count} " <>
        status(ratio)

    case colour(ratio) do
      nil -> text(line)
      fg -> text(line, fg: fg)
    end
  end

  defp bar(ratio) do
    filled = round(ratio * @bar_width)
    "[" <> String.duplicate("=", filled) <> String.duplicate(" ", @bar_width - filled) <> "]"
  end

  defp summary(model) do
    total = Enum.sum(Enum.map(@suites, &elem(&1, 1)))

    done =
      @suites
      |> Enum.with_index()
      |> Enum.map(fn {{_name, count}, i} -> passed(count, ratio(model.t, i)) end)
      |> Enum.sum()

    elapsed = :erlang.float_to_binary(model.t * @tick_ms / 1000, decimals: 1)

    "#{done}/#{total} tests, 0 failures, #{elapsed}s"
  end

  defp ratio(t, i) do
    progressed = (t - i * @ticks_per_suite) / @ticks_per_suite
    progressed |> max(0.0) |> min(1.0)
  end

  defp passed(count, ratio), do: round(count * ratio)

  defp status(1.0), do: "ok"
  defp status(+0.0), do: "pending"
  defp status(_ratio), do: "running"

  defp colour(1.0), do: :green
  defp colour(+0.0), do: nil
  defp colour(_ratio), do: :yellow

  defp clamp(cursor), do: cursor |> max(0) |> min(length(@suites) - 1)
end

defmodule GenReplayRecording do
  @path Path.expand("../web/priv/recordings/tour.cast", __DIR__)

  # The terminal is sized to what the app draws: a title, a rule, one line per
  # suite, a rule, a summary and a key hint is 10 rows, and 12 leaves two
  # spare. A taller terminal would ship a band of blank rows in every frame
  # and render as dead space under the output on the web surface.
  @width 72
  @height 12

  # One entry per slot of recorded time, so a slot is always @tick_ms long
  # whether it advances the run or types a key. The keys are the reason the
  # index has marks at all: `Raxol.Recording.Index` collects the elapsed time
  # of every `:input` event, and /replay draws those as the jumpable moments
  # a human touched the session.
  #
  # The tick counts add up to `ReplayTour.total_ticks/0`, so the run finishes
  # on the last slot rather than sitting idle at the end.
  @script [
    {:ticks, 8},
    {:key, "j"},
    {:ticks, 6},
    {:key, "j"},
    {:ticks, 6},
    {:key, "k"},
    {:ticks, 10}
  ]

  def run(path \\ @path) do
    File.mkdir_p!(Path.dirname(path))

    session = record()
    Asciicast.write!(session, path)

    bytes = File.stat!(path).size

    IO.puts(
      "replay  #{path} (#{length(session.events)} events, " <>
        "#{Float.round(bytes / 1024, 1)} KB, " <>
        "#{Float.round(Session.duration(session), 2)}s)"
    )
  end

  def check do
    scratch = Path.join(System.tmp_dir!(), "raxol_replay_check/tour.cast")
    File.rm_rf!(Path.dirname(scratch))
    run(scratch)

    stale? = not (File.exists?(@path) and File.read!(@path) == File.read!(scratch))
    File.rm_rf!(Path.dirname(scratch))

    if stale? do
      IO.puts(
        "STALE, re-record with " <>
          "`mix run ../scripts/gen_replay_recording.exs`:\n  #{@path}"
      )

      System.halt(1)
    end

    IO.puts("replay recording up to date")
  end

  defp record do
    ensure_headless()

    {:ok, id} =
      Raxol.Headless.start(ReplayTour,
        id: :replay_tour,
        width: @width,
        height: @height,
        subscriptions: false
      )

    try do
      slots = Enum.flat_map(@script, &expand/1)

      # Slot zero is the initial render, before any message: with no previous
      # buffer `build_terminal_frame/4` emits a full repaint, which is the
      # keyframe every replay of this file starts from.
      {events, _buffer} =
        slots
        |> Enum.with_index(1)
        |> Enum.reduce({frame_events(0, nil, buffer(id)), buffer(id)}, &slot(&1, &2, id))

      %Session{
        Session.new(
          width: @width,
          height: @height,
          title: "raxol test run",
          command: "mix run scripts/gen_replay_recording.exs",
          env: %{"TERM" => "xterm-256color", "SHELL" => "/bin/sh"}
        )
        | events: events,
          # Fixed rather than `DateTime.utc_now/0`: the header carries the
          # recording's wall-clock start, and a moving one would make every
          # rerun of this script report drift.
          started_at: DateTime.from_unix!(0),
          ended_at: DateTime.from_unix!(0)
      }
    after
      Raxol.Headless.stop(id)
    end
  end

  defp expand({:ticks, n}), do: List.duplicate(:tick, n)
  defp expand({:key, char}), do: [{:key, char}]

  defp slot({slot, index}, {events, previous}, id) do
    us = index * ReplayTour.tick_ms() * 1000

    typed =
      case slot do
        :tick ->
          :ok = Raxol.Headless.send_message(id, :tick)
          []

        {:key, char} ->
          # Delivered as the Event a key press folds into `update/2`, through
          # `send_message/2` because that call fences on the dispatcher: it
          # returns only once the model has folded the message, so the frame
          # read next is the frame that key produced. `send_key/3` casts, so
          # the render it lands in would depend on scheduling.
          event = %Raxol.Core.Events.Event{
            type: :key,
            data: %{key: :char, char: char}
          }

          :ok = Raxol.Headless.send_message(id, event)

          # The bytes the tty would have carried, which is what asciicast's
          # `i` events hold and what a replaying terminal would echo.
          [{us, :input, char}]
      end

    current = buffer(id)
    {events ++ typed ++ frame_events(us, previous, current), current}
  end

  # The frame as the terminal backend emits it: absolute-CUP rows, a leading
  # \e[2J only on a full repaint, and one SGR run per span of same-styled
  # cells. A slot whose render did not change the grid emits nothing, so an
  # idle slot costs no bytes.
  defp frame_events(us, previous, current) do
    renderer = Renderer.new(current, %{}, %{}, true)

    case Backends.build_terminal_frame(previous, current, renderer, %{
           force_repaint: false
         }) do
      "" -> []
      frame -> [{us, :output, frame}]
    end
  end

  defp buffer(id) do
    {:ok, buffer} = Raxol.Headless.get_buffer(id)
    buffer
  end

  defp ensure_headless do
    case Raxol.Headless.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end

case System.argv() do
  ["--check"] -> GenReplayRecording.check()
  _ -> GenReplayRecording.run()
end
