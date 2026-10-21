defmodule Raxol.Scoreboard do
  @moduledoc """
  Deterministic performance counters for CI, one JSON record per run.

  Each scenario drives a playground demo through the same pipeline the
  rendering engine runs for a frame (`view/1`, layout preparation,
  `Raxol.UI.Layout.Engine.apply_layout/3`, `Raxol.UI.Renderer.render_to_cells/2`,
  the screen buffer, and `Backends.build_terminal_frame/4`) in-process, with no
  TTY and no engine GenServer, and counts two things:

    * **bytes**: the size of the ANSI frame a terminal would receive. Exact.
    * **reductions**: the BEAM's unit of work, counted for the measuring
      process only (`Process.info(self(), :reductions)`). Unlike wall-clock
      time it does not move with runner load: repeated runs agree to within
      about 0.005%, which is why pull requests can be compared against master
      on shared CI runners.

  Every scenario runs once to load code, then three times in fresh processes;
  the reported reductions are the median. Metric ids, labels, units and the
  direction of "better" live in `priv/scoreboard/metrics.json`, which the CI
  comment and release-note renderer (`.github/scripts/scoreboard.mjs`) read
  too. Every metric this module emits must be defined there.

  Run via `MIX_ENV=test mix raxol.scoreboard`.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Playground.Demos.{FlexLayoutDemo, TableDemo}
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Layout.Preparer

  @defs_rel "scoreboard/metrics.json"
  @size %{width: 120, height: 40}
  @runs 3
  # Navigation, a sort and a border change: rows move, the header changes and
  # the whole grid redraws, so the script covers small and large diffs.
  @table_keys ~w(j j j j j s j j k b)

  @type metrics :: %{String.t() => number()}

  @doc "Run every scenario and return `%{metric_id => value}`."
  @spec collect() :: metrics()
  def collect do
    theme = Raxol.UI.Theming.Theme.new()

    table = scenario(TableDemo, @table_keys, theme)
    flex = scenario(FlexLayoutDemo, [], theme)
    keys = length(@table_keys)

    %{
      "table.keyframe.bytes" => table.keyframe_bytes,
      "table.keyframe.reductions" => table.keyframe_reductions,
      "table.keystroke.bytes" => round(table.script_bytes / keys),
      "table.keystroke.reductions" => round(table.script_reductions / keys),
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
        "otp" => System.otp_release(),
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

  # -- scenarios --

  defp scenario(app, keys, theme) do
    # The first run pays for code loading and lazily built caches; measure
    # after it.
    _ = in_fresh_process(fn -> run_scenario(app, keys, theme) end)

    runs =
      for _ <- 1..@runs,
          do: in_fresh_process(fn -> run_scenario(app, keys, theme) end)

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

  defp run_scenario(app, keys, theme) do
    model = init_model(app)

    r0 = reductions()

    {prev, keyframe_bytes} =
      frame(app, model, %{buffer: nil, prepared: nil}, theme)

    keyframe_reductions = reductions() - r0

    r1 = reductions()

    {_model, _prev, script_bytes} =
      Enum.reduce(keys, {model, prev, 0}, fn key, {model, prev, bytes} ->
        event = %Event{type: :key, data: %{key: :char, char: key}}
        model = unwrap(app.update(event, model))
        {next, frame_bytes} = frame(app, model, prev, theme)
        {model, next, bytes + frame_bytes}
      end)

    %{
      keyframe_bytes: keyframe_bytes,
      keyframe_reductions: keyframe_reductions,
      script_bytes: script_bytes,
      script_reductions: reductions() - r1
    }
  end

  defp init_model(app), do: unwrap(app.init(%{}))

  # TEA callbacks return either the model or `{model, commands}`.
  defp unwrap({model, _commands}), do: model
  defp unwrap(model), do: model

  # One frame through the engine's pipeline: view, layout, cells, buffer,
  # then the terminal frame diffed against the previous buffer.
  defp frame(app, model, prev, theme) do
    view = app.view(model)
    prepared = Preparer.prepare_incremental(view, prev.prepared)
    positioned = LayoutEngine.apply_layout(view, @size, prepared)
    cells = Raxol.UI.Renderer.render_to_cells(positioned, theme)
    buffer = Backends.apply_cells_to_buffer(cells, @size)
    renderer = Raxol.Terminal.Renderer.new(buffer, %{}, %{}, true)

    bytes =
      Backends.build_terminal_frame(prev.buffer, buffer, renderer, %{
        force_repaint: false
      })

    {%{buffer: buffer, prepared: prepared}, byte_size(bytes)}
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
