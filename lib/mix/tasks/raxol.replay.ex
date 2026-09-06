defmodule Mix.Tasks.Raxol.Replay do
  @moduledoc """
  Replays a recorded Raxol session from an asciicast (.cast) file.

  ## Usage

      mix raxol.replay demo.cast
      mix raxol.replay demo.cast --speed 2.0
      mix raxol.replay demo.cast --speed 0.5
      mix raxol.replay demo.cast --no-interactive
      mix raxol.replay demo.cast --index
      mix raxol.replay demo.cast --info --index

  ## Options

    * `--speed` / `-s` - Playback speed multiplier (default: 1.0).
      2.0 plays at double speed, 0.5 at half speed.
    * `--max-delay` - Maximum pause between frames in seconds (default: 5.0).
      Prevents long idle gaps from stalling replay.
    * `--no-interactive` - Disable keyboard controls (simple playback).
    * `--info` - Print recording info without playing.
    * `--index` - Build a `Raxol.Recording.Index` (keyframes every 15s) so
      seeking repaints from the nearest keyframe instead of replaying the
      recording's prefix. Costs time and memory up front, which is why it is
      opt-in: with `--info` it reports that cost instead of playing.

  ## Controls (interactive mode)

    * `space` - Pause / resume
    * `+` / `-` - Increase / decrease speed
    * `>` / `<` - Skip forward / backward 5 seconds
    * `0`..`9` - Jump to 0%-90% of recording
    * `q` / `ESC` - Quit

  Files are asciinema v2 format, compatible with `asciinema play`.
  """

  use Mix.Task

  alias Raxol.Recording.{Asciicast, Index, Player, Session}

  @shortdoc "Replay a recorded .cast session"

  @switches [
    speed: :float,
    max_delay: :float,
    info: :boolean,
    interactive: :boolean,
    index: :boolean
  ]

  @aliases [s: :speed]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [path], _} ->
        unless File.exists?(path) do
          Mix.raise("File not found: #{path}")
        end

        if Keyword.get(opts, :info, false) do
          print_info(path, opts)
        else
          replay(path, opts)
        end

      _ ->
        print_usage()
    end
  end

  defp replay(path, opts) do
    speed = Keyword.get(opts, :speed, 1.0)
    max_delay = Keyword.get(opts, :max_delay, 5.0)
    interactive = Keyword.get(opts, :interactive, true)

    speed_label = if speed != 1.0, do: " (#{speed}x)", else: ""
    Mix.shell().info([:cyan, "Replaying #{path}#{speed_label}...", :reset])

    if interactive do
      Mix.shell().info("Controls: space=pause +/-=speed </>:seek q=quit\n")
    else
      Mix.shell().info("Press Ctrl+C to stop.\n")
    end

    Process.sleep(500)

    case play(
           path,
           Keyword.get(opts, :index, false),
           speed: speed,
           max_delay: max_delay,
           interactive: interactive
         ) do
      :ok -> :ok
      {:error, reason} -> Mix.shell().error("Replay failed: #{inspect(reason)}")
    end

    Mix.shell().info([:green, "\nReplay complete.", :reset])
  end

  defp play(path, false, play_opts), do: Player.play(path, play_opts)

  defp play(path, true, play_opts) do
    case Asciicast.read(path) do
      {:ok, session} ->
        Mix.shell().info("Building keyframe index...")
        Player.play(session, [index: Index.build(session)] ++ play_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_info(path, opts) do
    case Asciicast.read(path) do
      {:ok, session} ->
        do_print_info(path, session)
        if Keyword.get(opts, :index, false), do: print_index_info(session)

      {:error, reason} ->
        Mix.raise("Failed to read #{path}: #{inspect(reason)}")
    end
  end

  # An index pins a full screen buffer per keyframe, so the cost is worth
  # seeing before building one for a long recording.
  defp print_index_info(session) do
    {build_us, index} = :timer.tc(fn -> Index.build(session) end)

    Mix.shell().info([:bright, "Index:", :reset])

    keyframes = length(index.keyframes)
    interval_s = div(index.interval_us, 1_000_000)
    Mix.shell().info("  Keyframes: #{keyframes} (every #{interval_s}s)")

    Mix.shell().info(
      "  Memory:    #{Float.round(Index.memory_bytes(index) / 1_048_576, 2)} MB"
    )

    Mix.shell().info("  Marks:     #{length(index.marks)} input events")
    Mix.shell().info("  Built in:  #{div(build_us, 1000)}ms")
  end

  defp do_print_info(path, session) do
    Mix.shell().info([:bright, "Recording: ", :reset, path])
    Mix.shell().info("  Size:      #{session.width}x#{session.height}")

    Mix.shell().info(
      "  Duration:  #{Float.round(Session.duration(session), 1)}s"
    )

    Mix.shell().info("  Events:    #{Session.event_count(session)}")

    if session.title do
      Mix.shell().info("  Title:     #{session.title}")
    end

    if session.command do
      Mix.shell().info("  Command:   #{session.command}")
    end

    Mix.shell().info("  Recorded:  #{DateTime.to_string(session.started_at)}")

    env_term = get_in(session.env, ["TERM"]) || "unknown"
    env_shell = get_in(session.env, ["SHELL"]) || "unknown"
    Mix.shell().info("  Terminal:  #{env_term}")
    Mix.shell().info("  Shell:     #{env_shell}")
  end

  defp print_usage do
    Mix.shell().error("Usage: mix raxol.replay FILE [options]")
    Mix.shell().error("")
    Mix.shell().error("Options:")
    Mix.shell().error("  --speed FLOAT      Playback speed (default: 1.0)")

    Mix.shell().error(
      "  --max-delay SECS   Max pause between frames (default: 5.0)"
    )

    Mix.shell().error("  --no-interactive   Disable keyboard controls")

    Mix.shell().error(
      "  --info             Print recording info without playing"
    )

    Mix.shell().error(
      "  --index            Build a keyframe index for fast seeking"
    )

    Mix.shell().error("")
    Mix.shell().error("Example: mix raxol.replay demo.cast --speed 2.0")
  end
end
