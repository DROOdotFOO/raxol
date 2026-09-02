defmodule Raxol.Playground.Snippet do
  @moduledoc """
  Extracts a demo module's marked region as its catalog snippet.

  A demo brackets its most illustrative lines with two comment lines:

      # snippet:start
      ...the code the catalog shows...
      # snippet:end

  and `Raxol.Playground.Catalog` derives `code_snippet` from that region at
  compile time. The point is provenance: a hand-written snippet beside a demo
  can drift from it silently, but a region extracted from the demo's own
  source is code the suite already boots and renders. The markers are
  comments, so they change no rendered frame and no recorded preview.

  Extraction is text slicing, never compilation, so it cannot disturb the
  frame recorder the way compiling shown source once did. It reads the file
  the formatter owns, so a derived snippet is formatter-clean by
  construction.
  """

  # A snippet is a card-sized excerpt. A region past this many lines is not
  # an excerpt any more, and the card would scroll it anyway, so the build
  # refuses it rather than shipping a wall of code as a "snippet".
  @max_lines 24

  @start_marker "# snippet:start"
  @end_marker "# snippet:end"

  @doc """
  The source path a demo module's snippet extracts from, by convention:
  `Raxol.Playground.Demos.ButtonDemo` -> `demos/button_demo.ex` beside this
  file. Register it as `@external_resource` so editing the demo recompiles
  the catalog.
  """
  @spec path_for(module()) :: Path.t()
  def path_for(module) do
    file =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    Path.join([__DIR__, "demos", file <> ".ex"])
  end

  @doc """
  The marked region of `path`, or `:no_markers`.

  Returns the lines strictly between exactly one marker pair, with their
  common indent stripped and a trailing newline, which is the shape the
  hand-written heredoc snippets had. Raises on a lone or duplicated marker
  and on a region past #{@max_lines} lines: both are authoring mistakes the
  build should name, not states to render.
  """
  @spec extract(Path.t()) :: {:ok, String.t()} | :no_markers
  def extract(path) do
    lines = path |> File.read!() |> String.split("\n")
    starts = marker_indexes(lines, @start_marker)
    ends = marker_indexes(lines, @end_marker)

    case {starts, ends} do
      {[], []} ->
        :no_markers

      {[start_at], [end_at]} when start_at < end_at ->
        {:ok, lines |> Enum.slice((start_at + 1)..(end_at - 1)) |> region(path)}

      _ ->
        raise "#{path} needs exactly one '#{@start_marker}' before one " <>
                "'#{@end_marker}'; found #{length(starts)} and #{length(ends)}"
    end
  end

  defp marker_indexes(lines, marker) do
    for {line, i} <- Enum.with_index(lines), String.trim(line) == marker, do: i
  end

  defp region(lines, path) do
    if length(lines) > @max_lines do
      raise "#{path} marks #{length(lines)} lines; a snippet is an excerpt, " <>
              "cap is #{@max_lines}"
    end

    indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&(byte_size(&1) - byte_size(String.trim_leading(&1))))
      |> Enum.min(fn -> 0 end)

    lines
    |> Enum.map(&String.slice(&1, indent..-1//1))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end
end
