defmodule Raxol.Scoreboard do
  @moduledoc """
  Deterministic performance counters for CI, one JSON record per run.

  Each scenario drives a playground demo through the frame stages the
  rendering engine runs, in-process with no TTY and no engine GenServer: the
  theme the engine would resolve (`Pipeline.theme/1`), `view/1`, layout
  preparation, `Raxol.UI.Layout.Engine.apply_layout/3`,
  `Raxol.UI.Renderer.render_to_cells/2`, the border-beam pass
  (`Pipeline.apply_border_beam/2`), and the terminal frame
  (`Backends.terminal_frame/2`) diffed against the previous one. The stage
  functions are the engine's own, not copies, and `frames/2` is held to the
  engine's exact output by test/raxol/scoreboard_test.exs, which drives a real
  `Raxol.Core.Runtime.Rendering.Engine` through the same keys. Plugin
  transforms are not applied: they come from the dispatcher's plugin manager
  at runtime, and the demos run with none loaded, as an app does by default.

  It counts two things, and one ratio of them:

    * **frame bytes**: the size of the ANSI frame payload the engine writes.
      Exact. A terminal that supports synchronized output also receives the
      16-byte `\\e[?2026h`/`\\e[?2026l` wrapper per frame, which is not counted.
      Every frame is first replayed through `Raxol.Terminal.Emulator` and must
      reproduce the screen it was rendered from, character and style
      (`replay_mismatch/1`), so the byte count can only fall by sending less
      for the same screen.
    * **reductions**: the BEAM's unit of work, counted for the measuring
      process only (`Process.info(self(), :reductions)`). Unlike wall-clock
      time it does not move with runner load: repeated runs agree to within a
      few hundredths of a percent, which is why pull requests can be compared
      against master on shared CI runners. Reductions do move with the
      Elixir/OTP version, which is why the record carries the full toolchain.
    * **work ratio**: a keystroke's reductions over the first frame's. A
      renderer that only redoes what a keystroke changed sits far below 1;
      the table demo is at 0.98, so a keystroke there costs nearly a full
      redraw.

  Every scenario runs once to load code, then three times in fresh processes;
  the reported reductions are the median. Metric ids, labels, units and the
  direction of "better" live in `priv/scoreboard/metrics.json`, which the CI
  comment and release-note renderer (`.github/scripts/scoreboard.mjs`) read
  too. Every metric this module emits must be defined there.

  Run via `MIX_ENV=test mix raxol.scoreboard`.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Rendering.{Backends, Pipeline}
  alias Raxol.Playground.Demos.{FlexLayoutDemo, TableDemo}
  alias Raxol.Terminal.{Emulator, ScreenBuffer}
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Layout.Preparer

  @defs_rel "scoreboard/metrics.json"
  @size %{width: 120, height: 40}
  @runs 3
  # Navigation, a sort and a border change: rows move, the header changes and
  # the whole grid redraws, so the script covers small and large diffs.
  @table_keys ~w(j j j j j s j j k b)

  @type metrics :: %{String.t() => number()}

  @doc """
  Run every scenario and return `%{metric_id => value}`.

  Before anything is measured, every scenario's frames are replayed through
  `Raxol.Terminal.Emulator` and must reproduce the screen they were rendered
  from (see `replay_mismatch/1`); otherwise this raises. That is what keeps
  the byte metrics honest: a change can only lower them by sending fewer bytes
  for the same screen, not by sending a broken one.
  """
  @spec collect() :: metrics()
  def collect do
    for {app, keys} <- [{TableDemo, @table_keys}, {FlexLayoutDemo, []}] do
      case replay_mismatch(frames(app, keys)) do
        nil ->
          :ok

        mismatch ->
          raise "scoreboard: #{inspect(app)}'s frames do not reproduce its screen " <>
                  "when replayed through the terminal emulator: #{inspect(mismatch)}"
      end
    end

    table = scenario(TableDemo, @table_keys)
    flex = scenario(FlexLayoutDemo, [])
    keys = length(@table_keys)
    keystroke_reductions = table.script_reductions / keys

    %{
      "table.keyframe.bytes" => table.keyframe_bytes,
      "table.keyframe.reductions" => table.keyframe_reductions,
      # Not rounded: with zero tolerance, a one-byte change anywhere in the
      # script has to show.
      "table.keystroke.bytes" => table.script_bytes / keys,
      "table.keystroke.reductions" => round(keystroke_reductions),
      # How much of a full redraw one keystroke costs. An incremental renderer
      # should sit far below 1.
      "table.keystroke.work_ratio" =>
        Float.round(keystroke_reductions / table.keyframe_reductions, 3),
      "flex.keyframe.bytes" => flex.keyframe_bytes,
      "flex.keyframe.reductions" => flex.keyframe_reductions
    }
  end

  @doc """
  Build a record: the collected metrics merged with `extra` (for example the
  buffer gate's memory rows), stamped with the commit and toolchain.

  Raises if any metric id is not defined in `priv/scoreboard/metrics.json`.
  """
  @spec record(metrics(), String.t()) :: map()
  def record(metrics, commit) do
    known = MapSet.new(definitions(), & &1["id"])

    case Enum.reject(Map.keys(metrics), &MapSet.member?(known, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "metrics not defined in priv/#{@defs_rel}: #{Enum.join(Enum.sort(unknown), ", ")}"
    end

    %{
      "schema" => 1,
      "commit" => commit,
      "toolchain" => %{
        "elixir" => System.version(),
        "otp" => otp_version(),
        "system_arch" => to_string(:erlang.system_info(:system_architecture))
      },
      "metrics" => metrics
    }
  end

  @doc "The metric definitions from `priv/scoreboard/metrics.json`."
  @spec definitions() :: [map()]
  def definitions do
    :raxol
    |> :code.priv_dir()
    |> to_string()
    |> Path.join(@defs_rel)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("metrics")
  end

  # The full OTP version ("29.0.3"), not `System.otp_release/0`'s major ("29"):
  # a patch release can move reduction counts, and the comparison only warns
  # about a toolchain change it can see.
  defp otp_version do
    path =
      Path.join([
        to_string(:code.root_dir()),
        "releases",
        System.otp_release(),
        "OTP_VERSION"
      ])

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> System.otp_release()
    end
  end

  # -- scenarios --

  defp scenario(app, keys) do
    # The first run pays for code loading and lazily built caches; measure
    # after it.
    _ = in_fresh_process(fn -> run_scenario(app, keys) end)

    runs =
      for _ <- 1..@runs,
          do: in_fresh_process(fn -> run_scenario(app, keys) end)

    bytes =
      runs |> Enum.map(&{&1.keyframe_bytes, &1.script_bytes}) |> Enum.uniq()

    match?([_], bytes) ||
      raise "scoreboard: #{inspect(app)} emitted different bytes across runs " <>
              "(#{inspect(bytes)}); the scenario is not deterministic"

    %{
      keyframe_bytes: hd(runs).keyframe_bytes,
      script_bytes: hd(runs).script_bytes,
      keyframe_reductions: median(Enum.map(runs, & &1.keyframe_reductions)),
      script_reductions: median(Enum.map(runs, & &1.script_reductions))
    }
  end

  @doc """
  Every frame `app` draws at 120x40, as `{payload, screen}`: its first frame (a
  keyframe), then one frame per key in `keys`, each diffed against the one
  before. `payload` is the ANSI the rendering engine writes for the same model
  sequence (test/raxol/scoreboard_test.exs holds the two to the same bytes);
  `screen` is the `Raxol.Terminal.ScreenBuffer` it was rendered from. The
  scoreboard's byte metrics are the payload sizes.
  """
  @spec frames(module(), [String.t()]) :: [{binary(), ScreenBuffer.t()}]
  def frames(app, keys) do
    model = init_model(app)
    {prev, first} = frame(app, model, %{buffer: nil, prepared: nil})

    {_model, _prev, rest} =
      Enum.reduce(keys, {model, prev, []}, fn key, {model, prev, acc} ->
        model = unwrap(app.update(key_event(key), model))
        {next, payload} = frame(app, model, prev)
        {model, next, [{payload, next.buffer} | acc]}
      end)

    [{first, prev.buffer} | Enum.reverse(rest)]
  end

  @doc """
  Replays `frames` (as `frames/2` returns them) in order through one
  `Raxol.Terminal.Emulator` and checks, after each frame, that every cell's
  character and style equal the screen the frame was rendered from.

  Returns `nil` when every frame reproduces its screen, otherwise the first
  frame that does not: `%{frame: index, cells: mismatched_cell_count,
  first: {x, y, expected_char, replayed_char}}`.
  """
  @spec replay_mismatch([{binary(), ScreenBuffer.t()}]) :: map() | nil
  def replay_mismatch(
        [{_payload, %{width: width, height: height}} | _] = frames
      ) do
    frames
    |> Enum.with_index()
    |> Enum.reduce_while(Emulator.new(width, height), fn {{payload, screen},
                                                          index},
                                                         emulator ->
      {emulator, _output} = Emulator.process_input(emulator, payload)

      case screen_mismatches(screen, Emulator.get_screen_buffer(emulator)) do
        [] ->
          {:cont, emulator}

        [first | _] = cells ->
          {:halt, %{frame: index, cells: length(cells), first: first}}
      end
    end)
    |> case do
      %{frame: _} = mismatch -> mismatch
      _emulator -> nil
    end
  end

  defp screen_mismatches(expected, replayed) do
    for y <- 0..(expected.height - 1)//1,
        x <- 0..(expected.width - 1)//1,
        want = ScreenBuffer.get_cell_at(expected, x, y),
        got = ScreenBuffer.get_cell_at(replayed, x, y),
        want.char != got.char or want.style != got.style,
        do: {x, y, want.char, got.char}
  end

  defp run_scenario(app, keys) do
    model = init_model(app)

    r0 = reductions()
    {prev, keyframe} = frame(app, model, %{buffer: nil, prepared: nil})
    keyframe_reductions = reductions() - r0

    r1 = reductions()

    {_model, _prev, script_bytes} =
      Enum.reduce(keys, {model, prev, 0}, fn key, {model, prev, bytes} ->
        model = unwrap(app.update(key_event(key), model))
        {next, payload} = frame(app, model, prev)
        {model, next, bytes + byte_size(payload)}
      end)

    %{
      keyframe_bytes: byte_size(keyframe),
      keyframe_reductions: keyframe_reductions,
      script_bytes: script_bytes,
      script_reductions: reductions() - r1
    }
  end

  defp key_event(char), do: %Event{type: :key, data: %{key: :char, char: char}}
  defp init_model(app), do: unwrap(app.init(%{}))

  # TEA callbacks return either the model or `{model, commands}`.
  defp unwrap({model, _commands}), do: model
  defp unwrap(model), do: model

  # One frame through the engine's stages, in the engine's order.
  defp frame(app, model, prev) do
    theme = Pipeline.theme(nil)
    view = app.view(model)
    prepared = Preparer.prepare_incremental(view, prev.prepared)
    positioned = LayoutEngine.apply_layout(view, @size, prepared)

    cells =
      positioned
      |> Raxol.UI.Renderer.render_to_cells(theme)
      |> Pipeline.apply_border_beam(positioned)

    {buffer, bytes} =
      Backends.terminal_frame(cells, %{
        width: @size.width,
        height: @size.height,
        buffer: prev.buffer,
        force_repaint: false
      })

    {%{buffer: buffer, prepared: prepared}, bytes}
  end

  defp reductions do
    {:reductions, count} = Process.info(self(), :reductions)
    count
  end

  defp in_fresh_process(fun) do
    task = Task.async(fun)
    Task.await(task, :infinity)
  end

  defp median(values),
    do: values |> Enum.sort() |> Enum.at(div(length(values), 2))
end
