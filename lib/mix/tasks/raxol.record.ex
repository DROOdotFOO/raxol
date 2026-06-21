defmodule Mix.Tasks.Raxol.Record do
  @moduledoc """
  Records a Raxol application session to an asciicast (.cast) file.

  ## Usage

      mix raxol.record --module Raxol.Demo.Dashboard -o demo.cast
      mix raxol.record --module Raxol.Demo.Counter -o counter.cast
      mix raxol.record --module Raxol.Demo.Counter   # writes to counter.cast

  ## Options

    * `--module` / `-m` - Module to record (required). Must implement
      `Raxol.Core.Runtime.Application`.
    * `-o` / `--output` - Output file path (default: derived from module name).
    * `--title` - Recording title (default: module name).
    * `--width` / `--height` - Force the cast dimensions instead of detecting the
      terminal size, e.g. `--width 80 --height 24` for a fixed 80x24 cast.
    * `--idle-time-limit` - Cap idle gaps between events (seconds).

  The recording captures all terminal output with timestamps. When the app
  exits (e.g., pressing 'q'), the session is saved as an asciinema v2 `.cast`
  file compatible with `asciinema play` and https://asciinema.org.
  """

  use Mix.Task

  alias Raxol.Recording.{Asciicast, Recorder}

  @shortdoc "Record a Raxol app session to .cast file"

  @switches [
    module: :string,
    output: :string,
    title: :string,
    idle_time_limit: :float,
    width: :integer,
    height: :integer
  ]

  @aliases [
    m: :module,
    o: :output
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, _, _} ->
        case Keyword.fetch(opts, :module) do
          {:ok, module_str} -> record(module_str, opts)
          :error -> print_usage()
        end
    end
  end

  defp record(module_str, opts) do
    Mix.Task.run("app.start")

    module = resolve_module!(module_str)
    output = Keyword.get(opts, :output, default_output(module_str))

    print_recording_header(module_str, output)
    session = run_recording(module, module_str, output, opts)
    print_recording_summary(session, output)
  end

  defp resolve_module!(module_str) do
    module = Module.concat([module_str])

    unless Code.ensure_loaded?(module) do
      Mix.raise("Module #{module_str} not found")
    end

    module
  end

  defp print_recording_header(module_str, output) do
    Mix.shell().info([:green, "Recording #{module_str}...", :reset])
    Mix.shell().info("Output: #{output}")
    Mix.shell().info("Press 'q' or Ctrl+C to stop recording.\n")
  end

  defp run_recording(module, module_str, output, opts) do
    title = Keyword.get(opts, :title, module_str)

    recorder_opts =
      [
        title: title,
        command: "mix raxol.record -m #{module_str}",
        auto_save: output
      ]
      |> maybe_add_opt(opts, :idle_time_limit)
      |> maybe_add_opt(opts, :width)
      |> maybe_add_opt(opts, :height)

    {:ok, _recorder} = Recorder.start_link(recorder_opts)
    {:ok, pid} = Raxol.start_link(module, [])
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    Recorder.stop()
  end

  defp print_recording_summary(session, output) do
    Asciicast.write!(session, output)
    Mix.shell().info("")

    Mix.shell().info([
      :green,
      "Saved #{Raxol.Recording.Session.event_count(session)} frames ",
      "(#{Float.round(Raxol.Recording.Session.duration(session), 1)}s) ",
      "to #{output}",
      :reset
    ])

    Mix.shell().info("Replay with: mix raxol.replay #{output}")
  end

  defp default_output(module_str) do
    module_str
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>(".cast")
  end

  defp maybe_add_opt(acc, opts, key) do
    case Keyword.get(opts, key) do
      nil -> acc
      val -> Keyword.put(acc, key, val)
    end
  end

  defp print_usage do
    Mix.shell().error("Usage: mix raxol.record --module MODULE [-o FILE]")
    Mix.shell().error("")

    Mix.shell().error(
      "Example: mix raxol.record -m Raxol.Demo.Dashboard -o demo.cast"
    )
  end
end
