defmodule RaxolPlayground.SurfaceSource do
  @moduledoc """
  Renders a recorded surface artifact into the hero's output pane.

  The line functions only re-break the stream, so every emitted line is a
  substring of the artifact. `clamp/2` is the one step that drops anything,
  and it appends a marker naming what it dropped.

  Lines are broken rather than wrapped because the height budget is counted
  in lines: a wrapped line costs two and pushes the marker off the pane.

  Colouring runs over already-escaped text, so a `<` in an artifact reaches
  the page as `&lt;`.
  """

  # Lines the pane holds at its largest type size; below that the CSS scales
  # type down (`--src-lines`) rather than cutting more.
  @budget 15

  # Columns that fit the pane at that same size. Type only shrinks from
  # there, so a line broken here fits at every size.
  @columns 62

  @doc "Lines the pane may hold, marker included."
  @spec budget() :: pos_integer()
  def budget, do: @budget

  @doc "Columns a line may occupy before `wrap/1` breaks it."
  @spec columns() :: pos_integer()
  def columns, do: @columns

  @doc """
  Hard-breaks any line wider than `columns/0` into consecutive chunks.

  Each chunk is still a run of the artifact's own characters.
  """
  @spec wrap([String.t()]) :: [String.t()]
  def wrap(lines), do: Enum.flat_map(lines, &split_line/1)

  defp split_line(line) do
    if String.length(line) <= @columns do
      [line]
    else
      line
      |> String.graphemes()
      |> Enum.chunk_every(@columns)
      |> Enum.map(&Enum.join/1)
    end
  end

  @doc """
  Breaks emitted markup so one element occupies each line.

  Splits before every `<`, then folds each closing tag back onto the line it
  closes, so a line carries an element and its text rather than a lone
  `&lt;/span&gt;`.
  """
  @spec dom_lines(String.t()) :: [String.t()]
  def dom_lines(html) do
    html
    |> String.replace("<", "\n<")
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> fold_onto_previous(&String.starts_with?(&1, "</"))
  end

  # A line with nothing before it stays put: the stream may open mid-construct.
  defp fold_onto_previous(lines, continuation?) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case {continuation?.(line), acc} do
        {true, [prev | rest]} -> [prev <> line | rest]
        _ -> [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Breaks an ANSI stream into one styled run per line, ESC spelled out.

  Spelling `\\e` as `ESC` is the only edit; the byte is invisible in a
  browser. Real newlines stay line breaks, so the row structure survives, and
  the reset closing a run is folded onto it rather than spending a line.
  """
  @spec ansi_lines(String.t()) :: [String.t()]
  def ansi_lines(ansi) do
    ansi
    |> String.split("\n")
    |> Enum.flat_map(&row_runs/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp row_runs(row) do
    case String.split(row, "\e") do
      [only] ->
        [only]

      [head | rest] ->
        [head | Enum.map(rest, &("ESC" <> &1))]
        |> Enum.reject(&(&1 == ""))
        |> fold_onto_previous(&String.starts_with?(&1, "ESC[0m"))
    end
  end

  @doc "Lines of a pretty-printed JSON artifact, as recorded."
  @spec json_lines(String.t()) :: [String.t()]
  def json_lines(json), do: String.split(json, "\n")

  @doc """
  Cuts `lines` to `budget/0`, appending a marker counting what was elided.
  """
  @spec clamp([String.t()], String.t()) :: [String.t()]
  def clamp(lines, artifact) do
    total = length(lines)

    if total <= @budget do
      lines
    else
      kept = Enum.take(lines, @budget - 1)
      elided = total - length(kept)
      kept ++ ["... #{elided} more lines, #{byte_size(artifact)} bytes total"]
    end
  end

  @doc """
  Escapes `lines` for display and colours them for `kind`.

  Colouring runs over the escaped text, so it wraps entities and can never
  re-open markup the artifact contained.
  """
  @spec to_html([String.t()], :dom | :ansi | :json) :: String.t()
  def to_html(lines, kind) do
    lines
    |> Enum.map_join("\n", fn line ->
      line
      |> escape()
      |> colorize(kind)
    end)
    |> dim_marker()
  end

  defp escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  # Values first, so one containing a word is not re-marked as a tag.
  defp colorize(line, :dom) do
    line
    |> String.replace(~r/&quot;([^&]*)&quot;/, ~S(&quot;<span class="hg">\1</span>&quot;))
    |> String.replace(~r{&lt;(/?[a-z]+)}, ~S(&lt;<span class="hk">\1</span>))
  end

  defp colorize(line, :ansi) do
    String.replace(line, ~r/^ESC\[[0-9;?]*[A-Za-z]/, ~S(<span class="hk">\0</span>))
  end

  defp colorize(line, :json) do
    line
    |> String.replace(~r/&quot;([^&]*)&quot;:/, ~S(&quot;<span class="hk">\1</span>&quot;:))
    |> String.replace(~r/: &quot;([^&]*)&quot;/, ~S(: &quot;<span class="hg">\1</span>&quot;))
  end

  defp dim_marker(html) do
    String.replace(
      html,
      ~r/(\.\.\. \d+ more lines[^\n]*)\z/,
      ~S(<span class="hc">\1</span>)
    )
  end
end
