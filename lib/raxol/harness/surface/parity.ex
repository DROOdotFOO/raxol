defmodule Raxol.Harness.Surface.Parity do
  @moduledoc """
  Multi-surface parity matrix: renders each fixture session through all four
  surface projections and pins each one, so "one TEA module renders to
  terminal, browser, SSH, and MCP" is a checked claim rather than a README
  sentence.

  `Raxol.Harness.Surface.Golden` pins the raw bytes of ONE surface (the
  inline/degradation terminal ladder) across three render modes. This module
  pins ONE render across four SURFACES, and additionally asserts they agree
  with each other. A regression that teaches the LiveView encoder to drop a
  wide character, or the ANSI writer to emit SGR before the cursor move, is
  invisible to a single-surface golden and lands here as both a drift and a
  parity break.

  ## The shared pivot

  Every projection derives from ONE render of ONE fold, so a divergence is
  always the projection's fault and never the input's:

      session (.jsonl)
        -> Raxol.Harness.Projection.project/2   (pure fold, T7)
        -> [Block.t()] -> Block.render/2        (pure view tree)
        -> LayoutEngine.apply_layout/2          (positioned elements)
        -> UIRenderer.render_to_cells/2         (the cell grid)

  and from the cell grid:

  | surface | projection | derived from |
  | --- | --- | --- |
  | `:cells` | canonical row-major cell dump | the grid |
  | `:liveview_dom` | `TerminalBridge.buffer_to_html/2`, normalized | the grid |
  | `:ssh_ansi` | `Core.Renderer.render_diff/2` + `apply_diff/1`, escaped | the grid |
  | `:structured_json` | `MCP.StructuredScreenshot.from_view_tree/2` | the view tree |

  `:structured_json` is deliberately taken from the view tree rather than the
  grid: that IS the MCP surface's input, and pinning it from the grid would
  test a pipeline nothing runs.

  ## What parity means, per surface

  `:cells`, `:liveview_dom`, and `:ssh_ansi` are three encodings of the same
  grid, so their visible text must be character-for-character identical --
  `parity/1` asserts exactly that, and it is the check with teeth: each
  encoder walks the grid independently.

  `:structured_json` comes from the pre-layout tree, so its text is NOT
  grid-identical (layout wraps, truncates, and pads). Its parity property is
  containment, checked at the word level: a word the MCP surface reports must
  be visible on screen. Claiming more would be false precision.

  ## Determinism

  Same closure as `Raxol.Harness.Surface.Golden`'s audit, plus:

    * fixed geometry (`#{60}x#{24}`), so layout never reads a live terminal;
    * an explicitly constructed theme, so the hash never depends on the global
      theme registry (which other tests in the suite mutate) -- the same
      reason `Raxol.RATE` passes one;
    * `render_diff/2` is taken against a BLANK buffer, making the ANSI stream
      a full repaint rather than a function of whatever was on screen before;
    * cells are sorted row-major before serialization, so emission order
      cannot leak into the hash.
  """

  alias Raxol.Core.Buffer
  alias Raxol.Core.Renderer, as: CoreRenderer
  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.Projection
  alias Raxol.LiveView.TerminalBridge
  alias Raxol.MCP.StructuredScreenshot
  alias Raxol.StableInspect
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Renderer, as: UIRenderer
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  @surfaces [:cells, :liveview_dom, :ssh_ansi, :structured_json]

  @width 60
  @height 24

  @sessions_dir Path.join(["test", "fixtures", "harness", "sessions"])
  @parity_dir Path.join(["test", "fixtures", "harness", "parity"])
  @refs_path Path.join(["priv", "harness", "parity.refs"])

  @type surface :: :cells | :liveview_dom | :ssh_ansi | :structured_json
  @type result :: %{
          name: String.t(),
          fixture: String.t(),
          surface: surface(),
          status: :current | :created | :overwritten,
          path: Path.t(),
          bytes: non_neg_integer()
        }

  @doc "The four surface projections this matrix covers."
  @spec surfaces() :: [surface()]
  def surfaces, do: @surfaces

  @doc "Fixed render geometry, shared by every surface."
  @spec geometry() :: %{width: pos_integer(), height: pos_integer()}
  def geometry, do: %{width: @width, height: @height}

  @doc "Directory holding the checked-in per-surface artifacts."
  @spec parity_dir() :: Path.t()
  def parity_dir, do: @parity_dir

  @doc "Path of the committed hash refs file."
  @spec refs_path() :: Path.t()
  def refs_path, do: @refs_path

  @doc """
  Every projectable fixture in `test/fixtures/harness/sessions`, sorted.

  Membership is decided by `Raxol.Harness.Fixture.Session.golden?/1` -- the
  same predicate `Raxol.Harness.Fixture.Bless` uses, so the two corpora cannot
  drift apart. An `kind: "adversarial"` fixture exists to be REJECTED by the
  loader, so there is no render to pin.

  Note this is a header field, not a filename convention: a `.notes.md`
  sidecar is documentation and says nothing about whether a fixture renders
  (`projection-panels` is hand-authored, documented, and golden).
  """
  @spec fixtures() :: [String.t()]
  def fixtures do
    @sessions_dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.filter(&golden_fixture?/1)
    |> Enum.map(&Path.basename(&1, ".jsonl"))
    |> Enum.sort()
  end

  defp golden_fixture?(path) do
    case Fixture.load(path) do
      {:ok, session} -> Session.golden?(session)
      {:error, _} -> false
    end
  end

  @doc "On-disk path for a fixture x surface artifact."
  @spec artifact_path(String.t(), surface()) :: Path.t()
  def artifact_path(fixture, surface) do
    Path.join(@parity_dir, "#{fixture}.#{surface}.txt")
  end

  # --- the shared render -----------------------------------------------------

  @doc """
  Renders `fixture` once and returns `%{tree: view_tree, cells: cells}` --
  the single pivot every projection is taken from.
  """
  @spec render(String.t()) :: %{tree: map(), cells: list()}
  def render(fixture) when is_binary(fixture) do
    tree = view_tree(fixture)

    cells =
      tree
      |> LayoutEngine.apply_layout(geometry())
      |> UIRenderer.render_to_cells(Raxol.UI.Theming.Theme.new())

    %{tree: tree, cells: cells}
  end

  @doc "Project a rendered fixture onto one surface. Returns the artifact text."
  @spec project(String.t() | map(), surface()) :: String.t()
  def project(fixture, surface) when is_binary(fixture) do
    project(render(fixture), surface)
  end

  def project(%{cells: cells}, :cells), do: cells_artifact(cells)

  def project(%{} = rendered, :liveview_dom),
    do: rendered |> raw_dom() |> normalize_dom()

  def project(%{} = rendered, :ssh_ansi),
    do: rendered |> raw_ansi() |> normalize_ansi()

  def project(%{tree: tree}, :structured_json) do
    tree
    |> StructuredScreenshot.from_view_tree()
    |> StructuredScreenshot.to_json()
    |> normalize_json()
  end

  @doc """
  The visible text of a fixture on each grid-derived surface, as
  `%{surface => [line]}`. The three lists must be equal -- see `parity/1`.
  """
  @spec visible_text(String.t() | map()) :: %{surface() => [String.t()]}
  def visible_text(fixture) when is_binary(fixture),
    do: visible_text(render(fixture))

  def visible_text(%{cells: cells} = rendered) do
    # The grid is the reference: it is what every encoder was handed. The two
    # encoders are parsed back out of their OWN raw output, so each comparison
    # exercises a real round trip rather than re-reading the reference.
    %{
      cells: cells_text(cells),
      liveview_dom: rendered |> raw_dom() |> dom_text(),
      ssh_ansi: rendered |> raw_ansi() |> ansi_text()
    }
  end

  @doc """
  Checks cross-surface agreement for `fixture`.

  Returns `:ok`, or `{:error, diagnostics}` naming the first disagreeing line
  per surface pair plus any MCP-reported word that is not on screen.
  """
  @spec parity(String.t()) :: :ok | {:error, map()}
  def parity(fixture) when is_binary(fixture) do
    rendered = render(fixture)
    %{cells: cells, liveview_dom: dom, ssh_ansi: ansi} = visible_text(rendered)

    disagreements =
      [{:liveview_dom, dom}, {:ssh_ansi, ansi}]
      |> Enum.flat_map(fn {surface, lines} ->
        case first_difference(cells, lines) do
          nil -> []
          diff -> [Map.put(diff, :surface, surface)]
        end
      end)

    mcp_headers = rendered |> project(:structured_json) |> mcp_block_headers()
    screen_headers = Enum.filter(cells, &header_line?/1)

    # The viewport clips: a session with more blocks than fit in @height rows
    # paints a PREFIX of them. Demanding equality would fail every long
    # fixture for a reason that is not a parity defect. A prefix claim still
    # catches reordering, an omitted middle block, and any header text drift.
    header_mismatch =
      if screen_headers == Enum.take(mcp_headers, length(screen_headers)),
        do: nil,
        else: %{mcp: mcp_headers, screen: screen_headers}

    case {disagreements, header_mismatch} do
      {[], nil} -> :ok
      {d, h} -> {:error, %{disagreements: d, block_headers: h}}
    end
  end

  # --- bless / check ---------------------------------------------------------

  @doc """
  Blesses (or with `check: true`, verifies) every fixture x surface artifact
  and the hash refs file.

  Returns `{:ok, results}` or `{:error, {:drift, names}}`.
  """
  @spec run(keyword()) :: {:ok, [result()]} | {:error, {:drift, [String.t()]}}
  def run(opts \\ []) do
    check? = Keyword.get(opts, :check, false)
    dir = Keyword.get(opts, :dir, @parity_dir)
    refs = Keyword.get(opts, :refs, @refs_path)
    only = Keyword.get(opts, :names, [])

    selected =
      case only do
        [] -> fixtures()
        names -> Enum.filter(fixtures(), &(&1 in names))
      end

    unless check?, do: File.mkdir_p!(dir)

    results =
      for fixture <- selected,
          rendered = render(fixture),
          surface <- @surfaces do
        bless_or_check(fixture, surface, rendered, check?, dir)
      end

    case Enum.filter(results, &(&1.status == :drift)) do
      [] ->
        finish_refs(results, refs, check?)

      drifted ->
        {:error, {:drift, Enum.map(drifted, & &1.name)}}
    end
  end

  defp bless_or_check(fixture, surface, rendered, check?, dir) do
    text = project(rendered, surface)
    path = Path.join(dir, "#{fixture}.#{surface}.txt")
    name = "#{fixture}.#{surface}"
    base = %{name: name, fixture: fixture, surface: surface, path: path}

    case {check?, File.read(path)} do
      {true, {:ok, ^text}} ->
        Map.merge(base, %{status: :current, bytes: byte_size(text)})

      {true, _} ->
        Map.merge(base, %{status: :drift, bytes: byte_size(text)})

      {false, {:ok, ^text}} ->
        Map.merge(base, %{status: :current, bytes: byte_size(text)})

      {false, {:ok, old}} ->
        File.write!(path, text)

        Map.merge(base, %{
          status: :overwritten,
          bytes: byte_size(text),
          old_bytes: byte_size(old)
        })

      {false, {:error, _}} ->
        File.write!(path, text)
        Map.merge(base, %{status: :created, bytes: byte_size(text)})
    end
  end

  # The refs file is the integrity half: it hashes the artifact bytes, so an
  # artifact edited by hand (rather than blessed from a real render) is caught
  # even though its own diff looks plausible.
  defp finish_refs(results, refs_path, check?) do
    body =
      results
      |> Enum.map(fn %{name: name, path: path} ->
        "#{name}  #{sha256(File.read!(path))}"
      end)
      |> Enum.sort()
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    if check? do
      case File.read(refs_path) do
        {:ok, ^body} -> {:ok, results}
        _ -> {:error, {:drift, ["parity.refs"]}}
      end
    else
      File.mkdir_p!(Path.dirname(refs_path))
      File.write!(refs_path, body)
      {:ok, results}
    end
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # --- raw encoder output ----------------------------------------------------

  defp raw_dom(%{cells: cells}) do
    cells
    |> to_buffer()
    |> TerminalBridge.buffer_to_html(aria_mode: :application)
  end

  defp raw_ansi(%{cells: cells}) do
    Buffer.create_blank_buffer(@width, @height)
    |> CoreRenderer.render_diff(to_buffer(cells))
    |> CoreRenderer.apply_diff()
  end

  # --- the pivot render ------------------------------------------------------

  defp view_tree(fixture) do
    path = Path.join(@sessions_dir, "#{fixture}.jsonl")

    session =
      case Fixture.load(path) do
        {:ok, session} ->
          session

        {:error, error} ->
          raise "parity fixture #{fixture} failed to load: #{inspect(error)}"
      end

    session
    |> Projection.project()
    |> Map.fetch!(:blocks)
    |> Enum.map(&Block.render(&1, %{width: @width}))
    |> then(&Components.column(gap: 0, children: &1))
  end

  # --- per-surface artifacts -------------------------------------------------

  # Row-major, one cell per line, style tokens spelled out. Mirrors
  # `Raxol.RATE`'s serialization so a cell-level divergence reads the same way
  # in both matrices. Cell text goes through `StableInspect.quoted/1`, never
  # `inspect/1`, so the artifact bytes match on every CI Elixir.
  defp cells_artifact(cells) do
    cells
    |> Enum.sort_by(fn {x, y, _c, _fg, _bg, _a} -> {y, x} end)
    |> Enum.map_join("\n", fn {x, y, char, fg, bg, attrs} ->
      "#{y},#{x} #{StableInspect.quoted(char)} #{token(fg)} #{token(bg)} " <>
        inspect(Enum.sort(List.wrap(attrs)))
    end)
    |> newline_terminated()
  end

  defp token(:default), do: "default"
  defp token(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp token(other), do: inspect(other)

  # One span per line. The encoder emits a single `<pre>` holding every row,
  # which diffs as one enormous line; splitting on tag boundaries makes a
  # one-span change read as a one-line change without touching content.
  defp normalize_dom(html) do
    html
    |> String.replace("><", ">\n<")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> newline_terminated()
  end

  # One escape sequence or text run per line, with ESC spelled out. A raw ANSI
  # stream is unreadable in a diff and (per `.gitattributes` on the byte
  # goldens) unsafe to store as text; this keeps every byte while staying
  # reviewable.
  defp normalize_ansi(ansi) do
    ~r/\e\[[0-9;?]*[A-Za-z]/
    |> Regex.split(ansi, include_captures: true, trim: true)
    |> Enum.map_join("\n", fn
      <<0x1B, rest::binary>> -> "ESC" <> rest
      text -> StableInspect.quoted(text)
    end)
    |> newline_terminated()
  end

  # `to_json/1` emits one line; re-encode pretty so a field change is a line
  # change. Key order is already deterministic (the encoder sorts).
  defp normalize_json(json) do
    json
    |> Jason.decode!()
    |> Jason.encode!(pretty: true)
    |> newline_terminated()
  end

  defp newline_terminated(text), do: String.trim_trailing(text, "\n") <> "\n"

  # --- text extraction (parity) ----------------------------------------------

  defp to_buffer(cells) do
    blank = Buffer.create_blank_buffer(@width, @height)

    Enum.reduce(cells, blank, fn {x, y, char, fg, bg, attrs}, buffer ->
      style = %{
        fg_color: nilify(fg),
        bg_color: nilify(bg),
        bold: :bold in List.wrap(attrs)
      }

      buffer
      |> Buffer.set_cell(x, y, char, style)
      |> continuation_cells(x, y, char, style)
    end)
  end

  # A double-width char claims two columns but the renderer emits ONE cell for
  # it, so the column behind it is still the blank the buffer started with. A
  # blank there is a literal space to any encoder that walks all `width` cells
  # (the LiveView `<pre>` does), which would put a real space between `\u4f60`
  # and `\u597d` in the browser while the terminal shows them adjacent. Fill it
  # with the empty continuation the terminal buffer uses instead.
  defp continuation_cells(buffer, x, y, char, style) do
    case TextMeasure.display_width(char) do
      width when width > 1 ->
        Enum.reduce((x + 1)..(x + width - 1), buffer, fn shadow, acc ->
          Buffer.set_cell(acc, shadow, y, "", style)
        end)

      _ ->
        buffer
    end
  end

  defp nilify(:default), do: nil
  defp nilify(other), do: other

  defp cells_text(cells) do
    cells
    |> Map.new(fn {x, y, char, _fg, _bg, _a} -> {{y, x}, char} end)
    |> grid_to_lines()
  end

  defp grid_to_lines(grid) do
    for y <- 0..(@height - 1),
        do: String.trim_trailing(row_text(grid, y, 0, []))
  end

  # A double-width char (CJK, emoji) occupies TWO grid columns: the cell it was
  # written to, and a shadow column the renderer never writes. Emitting a space
  # for that shadow would read back `\u4f60 \u597d` where the terminal displays
  # `\u4f60\u597d` -- so skip it, and reconstruct the text a human sees.
  defp row_text(_grid, _y, x, acc) when x >= @width,
    do: acc |> Enum.reverse() |> Enum.join()

  defp row_text(grid, y, x, acc) do
    char = Map.get(grid, {y, x}, " ")
    row_text(grid, y, x + max(TextMeasure.display_width(char), 1), [char | acc])
  end

  # `buffer_to_html/2` emits exactly one row per line inside a single `<pre>`.
  # Strip the container and the spans; what is left is the row's text.
  defp dom_text(html) do
    html
    |> String.replace(~r{^<pre[^>]*>}, "")
    |> String.replace(~r{</pre>\s*\z}, "")
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/<[^>]*>/, "")
      |> unescape_html()
      |> String.trim_trailing()
    end)
    |> pad_lines()
  end

  defp unescape_html(text) do
    # `&amp;` last: unescaping it first would let `&amp;lt;` become `<`.
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # Replay the ANSI stream against an empty grid: `H` positions the cursor,
  # every other sequence is styling that does not move it, and text runs paint
  # forward from wherever the cursor is.
  defp ansi_text(ansi) do
    ~r/\e\[[0-9;?]*[A-Za-z]/
    |> Regex.split(ansi, include_captures: true, trim: true)
    |> Enum.reduce({%{}, {0, 0}}, fn chunk, {grid, cursor} ->
      case chunk do
        <<0x1B, "[", rest::binary>> -> {grid, cursor_move(rest, cursor)}
        text -> paint(grid, cursor, text)
      end
    end)
    |> elem(0)
    |> grid_to_lines()
  end

  # A terminal advances the cursor by the glyph's DISPLAY width, not by one
  # column per grapheme: after a CJK char the next glyph lands two columns on.
  # Advancing by one would stack the row's remaining text into the wide char's
  # shadow columns and read back `\u4f60\u4e16` for `\u4f60\u597d\u4e16\u754c`.
  defp paint(grid, cursor, text) do
    text
    |> String.graphemes()
    |> Enum.reduce({grid, cursor}, fn char, {g, {x, y}} ->
      {Map.put(g, {y, x}, char),
       {x + max(TextMeasure.display_width(char), 1), y}}
    end)
  end

  # Only `H` (absolute position) moves the cursor in this stream; SGR and
  # friends leave it where it was.
  defp cursor_move(rest, cursor) do
    case Regex.run(~r/^(\d+);(\d+)H$/, rest) do
      [_, row, col] -> {String.to_integer(col) - 1, String.to_integer(row) - 1}
      nil -> cursor
    end
  end

  defp pad_lines(lines) do
    lines
    |> Enum.take(@height)
    |> Kernel.++(List.duplicate("", max(@height - length(lines), 0)))
  end

  defp first_difference(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.with_index()
    |> Enum.find_value(fn {{e, a}, index} ->
      if e != a, do: %{line: index, expected: e, actual: a}
    end)
  end

  # A block's header is the first text child of its column -- the same node
  # `Block.render/2` builds and the layout engine paints as the header line, so
  # this is an exact comparison, not a fuzzy one. It survives truncation
  # because both sides read the SAME already-truncated text.
  defp mcp_block_headers(json) do
    case Jason.decode!(json) do
      [%{"children" => blocks}] -> Enum.flat_map(blocks, &first_text/1)
      _ -> []
    end
  end

  defp first_text(%{"content" => text}) when is_binary(text) and text != "",
    do: [text]

  defp first_text(%{"children" => [child | _]}), do: first_text(child)
  defp first_text(_), do: []

  # `Block.render/2` opens every header with a fold icon.
  defp header_line?(line), do: String.starts_with?(line, ["\u25be ", "\u25b8 "])
end
