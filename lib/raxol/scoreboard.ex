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
      time it does not move with runner load, which is why pull requests can
      be compared against master on shared CI runners. It is not perfectly
      repeatable: runs on one machine agree within a few hundredths of a
      percent, but two CI runs of the same commit have differed by up to
      0.2%, so the reduction metrics carry a 0.5% noise tolerance in
      `priv/scoreboard/metrics.json`. Reductions also move with the
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
  alias Raxol.StableInspect
  alias Raxol.Terminal.{Emulator, ScreenBuffer}
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Layout.Preparer

  @defs_rel "scoreboard/metrics.json"
  @screens_rel "scoreboard/screens.refs"
  @size %{width: 120, height: 40}
  @runs 3
  # Navigation, a sort and a border change: rows move, the header changes and
  # the whole grid redraws, so the script covers small and large diffs.
  @table_keys ~w(j j j j j s j j k b)
  @scenarios [{"table", TableDemo, @table_keys}, {"flex", FlexLayoutDemo, []}]

  @type metrics :: %{String.t() => number()}

  @doc """
  Run every scenario and return `%{metric_id => value}`.

  Before anything is measured, two checks keep the byte metrics honest, and
  either failing raises:

    * every scenario's frames are replayed through `Raxol.Terminal.Emulator`
      and must reproduce the screen they were rendered from
      (`replay_mismatch/1`), so bytes cannot fall by sending a broken frame;
    * every frame's screen must match its fingerprint in
      `priv/scoreboard/screens.refs` (`check_screens/0`), so bytes cannot fall
      by drawing less. An intended visual change re-blesses the fingerprints
      (`mix raxol.scoreboard --bless`) in the same pull request, where review
      sees it.
  """
  @spec collect() :: metrics()
  def collect do
    for {_name, app, keys} <- @scenarios do
      case replay_mismatch(frames(app, keys)) do
        nil ->
          :ok

        mismatch ->
          raise "scoreboard: #{inspect(app)}'s frames do not reproduce its screen " <>
                  "when replayed through the terminal emulator: #{inspect(mismatch)}"
      end
    end

    case check_screens() do
      :ok -> :ok
      {:error, problems} -> raise screens_error(problems)
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

  # -- screen fingerprints --

  @doc """
  A fingerprint of every scenario frame's screen, as `{"table:3", sha256}`:
  the scenario name and frame index (0 is the first frame), and a hash of
  every cell's character and full style, serialized stably across Elixir
  releases and architectures (the same rules as `Raxol.RATE`).
  """
  @spec screen_fingerprints() :: [{String.t(), String.t()}]
  def screen_fingerprints do
    for {name, app, keys} <- @scenarios,
        {{_payload, screen}, index} <- Enum.with_index(frames(app, keys)) do
      {"#{name}:#{index}", fingerprint(screen)}
    end
  end

  @doc """
  Compare `screen_fingerprints/0` with `priv/scoreboard/screens.refs`.
  Returns `:ok`, or `{:error, problems}` listing every frame whose screen
  changed, has no reference, or has a reference but no longer exists.
  """
  @spec check_screens() :: :ok | {:error, [String.t()]}
  def check_screens do
    refs = load_screen_refs()
    current = screen_fingerprints()
    drawn = Enum.map(current, &elem(&1, 0))

    gone =
      for key <- Enum.sort(Map.keys(refs) -- drawn),
          do: "#{key} is referenced but no longer drawn"

    case Enum.flat_map(current, &screen_problem(&1, refs)) ++ gone do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp screen_problem({key, hash}, refs) do
    case Map.fetch(refs, key) do
      {:ok, ^hash} ->
        []

      {:ok, ref} ->
        ["#{key} changed (#{short_hash(ref)} -> #{short_hash(hash)})"]

      :error ->
        ["#{key} has no reference"]
    end
  end

  defp short_hash(hash), do: String.slice(hash, 0, 12)

  @doc """
  Rewrite `priv/scoreboard/screens.refs` from the current screens. Run from
  the project root after an intended visual change, and commit the file.
  """
  @spec bless_screens() :: :ok
  def bless_screens do
    body =
      Enum.map_join(screen_fingerprints(), "\n", fn {key, hash} ->
        "#{key}  #{hash}"
      end)

    path = Path.join("priv", @screens_rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body <> "\n")
  end

  defp screens_error(problems) do
    "scoreboard: scenario screens differ from priv/#{@screens_rel}:\n  " <>
      Enum.join(problems, "\n  ") <>
      "\nA scenario that draws something different is a different benchmark, " <>
      "so its numbers are not comparable. If the change is intended, run " <>
      "`MIX_ENV=test mix raxol.scoreboard --bless` and commit the file."
  end

  defp load_screen_refs do
    path = Path.join(to_string(:code.priv_dir(:raxol)), @screens_rel)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split(~r/\r?\n/, trim: true)
        |> Map.new(fn line ->
          [key, hash] = String.split(line, ~r/\s+/, parts: 2)
          {key, String.trim(hash)}
        end)

      {:error, :enoent} ->
        %{}
    end
  end

  defp fingerprint(screen) do
    rows =
      for y <- 0..(screen.height - 1)//1 do
        Enum.map_join(0..(screen.width - 1)//1, " ", fn x ->
          cell = ScreenBuffer.get_cell_at(screen, x, y)
          "#{StableInspect.quoted(cell.char || "")}#{style_token(cell.style)}"
        end)
      end

    "#{screen.width}x#{screen.height}\n#{Enum.join(rows, "\n")}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Every style field, sorted by name, so a new field or value changes the
  # fingerprint while field order and inspect/1's escaping never do.
  defp style_token(nil), do: "{}"

  defp style_token(style) do
    fields =
      style
      |> Map.from_struct()
      |> Enum.sort()
      |> Enum.map_join(",", fn {key, value} ->
        "#{key}=#{value_token(value)}"
      end)

    "{#{fields}}"
  end

  defp value_token(value) when is_binary(value), do: StableInspect.quoted(value)
  defp value_token(value) when is_atom(value), do: Atom.to_string(value)
  defp value_token(value) when is_integer(value), do: Integer.to_string(value)

  defp value_token(value) when is_tuple(value),
    do: "(" <> Enum.map_join(Tuple.to_list(value), ",", &value_token/1) <> ")"

  defp value_token(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &value_token/1) <> "]"

  defp value_token(value) when is_map(value),
    do:
      "%{" <>
        Enum.map_join(Enum.sort(value), ",", fn {k, v} ->
          "#{value_token(k)}:#{value_token(v)}"
        end) <> "}"

  defp value_token(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

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
