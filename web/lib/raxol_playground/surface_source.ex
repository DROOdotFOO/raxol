defmodule RaxolPlayground.SurfaceSource do
  @moduledoc """
  Renders a recorded surface artifact into the hero's output pane.

  Two shapes, because the surfaces carry two kinds of thing.

  The browser and MCP artifacts are structured text, read line by line. The
  line functions only re-break the stream, so every emitted line is a substring
  of the artifact; `clamp/2` is the one step that drops anything, and it
  appends a marker naming what it dropped. Lines are broken rather than wrapped
  because the height budget is counted in lines: a wrapped line costs two and
  pushes the marker off the pane.

  The SSH artifact is a picture. `ansi_rows/1` decodes its colour instead of
  spelling it out, and nothing is clamped -- the pane reports its grid through
  `ansi_grid/1` and the CSS fits the type to it, the way the terminal pane
  beside it already worked. A frame cut to a line budget it never fit is not
  the frame the channel delivered.

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

  # The SGR colours a recording may ask for, mapped to the class that paints
  # them. `TerminalBridge` renders the terminal pane's frame from the same
  # buffer this stream was projected from, so these classes must resolve to the
  # colours it emits -- otherwise one program shows up in two palettes on two
  # tabs of the same demo.
  @sgr_colors %{
    "30" => "ansi-black",
    "31" => "ansi-red",
    "32" => "ansi-green",
    "33" => "ansi-yellow",
    "34" => "ansi-blue",
    "35" => "ansi-magenta",
    "36" => "ansi-cyan",
    "37" => "ansi-white"
  }

  @ansi_sequence ~r/\e\[[0-9;?]*[A-Za-z]/

  @typedoc "A painted run: the class colouring it, or nil for the default."
  @type run :: {String.t() | nil, String.t()}

  @doc """
  Decodes an ANSI stream into rows of painted runs.

  The pane used to spell `\\e` as `ESC` and print the codes beside the text.
  That is honestly what the channel carries, but escape codes on screen is the
  universal signature of a terminal failing to render, so the one pane whose
  job is to prove raxol runs over SSH was the one that looked broken. Painting
  them shows the frame the remote terminal actually receives, which is the
  claim the pane exists to make.

  Colour carries across rows, as it does on a real terminal: a run left open at
  the end of one row still colours the start of the next.

  Raises on a sequence it cannot paint. Callers decode committed recordings at
  compile time, so an unsupported code fails the build rather than reaching the
  page as a silently unstyled run.
  """
  @spec ansi_rows(String.t()) :: [[run()]]
  def ansi_rows(ansi) do
    ansi
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_reduce(nil, &row_runs/2)
    |> elem(0)
  end

  defp row_runs(row, class) do
    @ansi_sequence
    |> Regex.split(row, include_captures: true, trim: true)
    |> Enum.reduce({[], class}, fn
      <<"\e[", _rest::binary>> = seq, {runs, cls} -> {runs, sgr_class!(seq, cls)}
      text, {runs, cls} -> {[{cls, text} | runs], cls}
    end)
    |> then(fn {runs, cls} -> {Enum.reverse(runs), cls} end)
  end

  defp sgr_class!(sequence, class) do
    params =
      case String.split_at(sequence, -1) do
        {<<"\e[", params::binary>>, "m"} ->
          params

        _ ->
          raise ArgumentError,
                "#{inspect(sequence)} is not an SGR sequence; the hero panes paint colour only"
      end

    # No parameters is a reset: `ESC[m` and `ESC[0m` mean the same thing.
    case String.split(params, ";", trim: true) do
      [] -> nil
      codes -> Enum.reduce(codes, class, &apply_sgr!/2)
    end
  end

  defp apply_sgr!("0", _class), do: nil

  defp apply_sgr!(code, _class) do
    Map.get_lazy(@sgr_colors, code, fn ->
      raise ArgumentError,
            "no colour is mapped for SGR #{code}; add it to SurfaceSource " <>
              "alongside the CSS that paints it"
    end)
  end

  @doc """
  Escaped markup for decoded `rows`, one line per row.

  Nothing is dropped: the pane sizes its type to the grid rather than cutting
  to a line budget, so unlike the browser and MCP panes there is no marker and
  no elision.
  """
  @spec ansi_html([[run()]]) :: String.t()
  def ansi_html(rows) do
    Enum.map_join(rows, "\n", fn runs ->
      Enum.map_join(runs, "", fn
        {nil, text} -> escape(text)
        {class, text} -> ~s(<span class="#{class}">#{escape(text)}</span>)
      end)
    end)
  end

  @doc """
  The row count and widest row of decoded `rows`, in painted characters.

  Measured on the text only. Escape sequences occupy no columns on a terminal,
  and counting them as width is what made the old pane wrap a 70-column frame
  into fragments.
  """
  @spec ansi_grid([[run()]]) :: %{rows: pos_integer(), cols: pos_integer()}
  def ansi_grid(rows) do
    widths =
      Enum.map(rows, fn runs -> Enum.reduce(runs, 0, &(String.length(elem(&1, 1)) + &2)) end)

    %{rows: max(length(rows), 1), cols: max(Enum.max(widths, fn -> 1 end), 1)}
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
  @spec to_html([String.t()], :dom | :json) :: String.t()
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
