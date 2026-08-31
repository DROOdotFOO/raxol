defmodule Raxol.Agent.Actions.Lsp do
  @moduledoc """
  Language-server Actions: `lsp` (read-only queries) and `lsp_rename`
  (applies edits, gated).

  These are two tools rather than one with a mode flag because `sensitive`
  is declared per Action module at compile time. A single tool could not be
  read-only for `definition` and gated for `rename`, and the gate is the
  point.

  ## Positions

  Every position crossing this boundary is 1-based, matching the line
  numbers `read_file` prints in its anchors. LSP itself is 0-based; the
  conversion happens here, once, so no caller has to remember which
  convention it is holding.

  ## Containment

  A path is resolved through `Raxol.Agent.Actions.Fs.resolve/2` like every
  other file tool, so the same cwd jail applies. Results, though, come from
  the language server, which indexes whatever it likes: a definition can
  land in a dependency or the standard library, outside the workspace root.
  Those are reported as absolute paths in a normal session and dropped
  entirely in a jailed one, where a path outside the jail is a disclosure
  rather than a convenience.

  ## Wiring

  Both read `context[:lsp_pool]`, a `Raxol.Agent.Lsp.Pool` owned by the
  session. Without one they answer `:lsp_not_available` rather than starting
  an OS subprocess owned by a turn that is about to end.
  """

  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Lsp.Pool
  alias Raxol.Agent.LSPContext

  @query_ops ~w(diagnostics symbols definition references hover)

  defmodule Query do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "lsp",
      description:
        "Ask the language server about code, instead of inferring it from " <>
          "text. Ops: `diagnostics` (errors and warnings for a file, the " <>
          "fastest way to check whether an edit compiles), `symbols` (the " <>
          "file's outline), `definition` (where the symbol at a position is " <>
          "defined), `references` (everywhere it is used — use this before " <>
          "changing a signature), `hover` (its type and docs). Positions are " <>
          "1-based `line` and `column`, matching read_file's anchors.",
      schema: [
        input: [
          op: [
            type: :string,
            required: true,
            enum: ["diagnostics", "symbols", "definition", "references", "hover"],
            description: "Which query to run"
          ],
          path: [type: :string, required: true, description: "File to ask about"],
          line: [
            type: :integer,
            description: "1-based line; required for definition, references, hover"
          ],
          column: [
            type: :integer,
            description: "1-based column (default 1)"
          ]
        ],
        output: [
          op: [type: :string],
          path: [type: :string],
          diagnostics: [type: :list],
          symbols: [type: :list],
          locations: [type: :list],
          hover: [type: :string]
        ]
      ]

    @impl true
    def run(params, context) do
      Raxol.Agent.Actions.Lsp.query(params, context)
    end
  end

  defmodule Rename do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "lsp_rename",
      sensitive: true,
      description:
        "Rename the symbol at a position everywhere it appears, using the " <>
          "language server's own understanding of scope, and write the " <>
          "resulting edits to disk. This is what to use instead of a " <>
          "grep-and-replace across files: it will not touch a same-named " <>
          "symbol in another scope, and it will follow re-exports. Positions " <>
          "are 1-based. Returns the files changed and how many edits each took.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File holding the symbol"],
          line: [type: :integer, required: true, description: "1-based line"],
          column: [type: :integer, required: true, description: "1-based column"],
          new_name: [type: :string, required: true, description: "The new symbol name"]
        ],
        output: [
          path: [type: :string],
          new_name: [type: :string],
          changed: [type: :list],
          edits: [type: :integer]
        ]
      ]

    @impl true
    def run(params, context) do
      Raxol.Agent.Actions.Lsp.rename(params, context)
    end
  end

  @doc "All LSP actions, for a run's `actions:`."
  @spec all() :: [module()]
  def all, do: [Query, Rename]

  @doc "The read-only subset, safe without a `:tool_authorizer` opt-in."
  @spec read_only() :: [module()]
  def read_only, do: [Query]

  # -- queries ----------------------------------------------------------------

  @doc false
  @spec query(map(), map()) :: {:ok, map()} | {:error, term()}
  def query(%{op: op, path: path} = params, context) when op in @query_ops do
    with {:ok, abs, client, _server} <- open(path, context) do
      uri = Pool.path_to_uri(abs)

      run_query(op, client, uri, params, context)
      |> annotate(op, path)
    end
  end

  def query(%{op: op}, _context), do: {:error, {:unknown_op, op}}
  def query(_params, _context), do: {:error, {:unknown_op, nil}}

  defp run_query("diagnostics", client, uri, _params, _context) do
    case LSPContext.await_diagnostics(client, uri) do
      {:ok, diagnostics} -> {:ok, %{diagnostics: Enum.map(diagnostics, &render_diagnostic/1)}}
      {:error, :timeout} -> {:error, :diagnostics_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_query("symbols", client, uri, _params, _context) do
    with {:ok, symbols} <- LSPContext.symbols(client, uri) do
      {:ok, %{symbols: Enum.map(symbols, &render_symbol/1)}}
    end
  end

  defp run_query("definition", client, uri, params, context) do
    with {:ok, line, column} <- position(params),
         {:ok, locations} <- LSPContext.definition(client, uri, line, column) do
      {:ok, %{locations: render_locations(locations, context)}}
    end
  end

  defp run_query("references", client, uri, params, context) do
    with {:ok, line, column} <- position(params),
         {:ok, locations} <- LSPContext.references(client, uri, line, column) do
      {:ok, %{locations: render_locations(locations, context)}}
    end
  end

  defp run_query("hover", client, uri, params, _context) do
    with {:ok, line, column} <- position(params),
         {:ok, text} <- LSPContext.hover(client, uri, line, column) do
      {:ok, %{hover: text || ""}}
    end
  end

  defp annotate({:ok, result}, op, path), do: {:ok, Map.merge(result, %{op: op, path: path})}
  defp annotate({:error, reason}, _op, _path), do: {:error, reason}

  # -- rename -----------------------------------------------------------------

  @doc false
  @spec rename(map(), map()) :: {:ok, map()} | {:error, term()}
  def rename(%{path: path, new_name: new_name} = params, context) do
    with {:ok, valid_name} <- validate_name(new_name),
         {:ok, line, column} <- position(params),
         {:ok, abs, client, _server} <- open(path, context),
         {:ok, file_edits} <-
           LSPContext.rename(client, Pool.path_to_uri(abs), line, column, valid_name),
         {:ok, resolved} <- resolve_edit_targets(file_edits, context),
         :ok <- apply_edits(resolved) do
      {:ok,
       %{
         path: path,
         new_name: valid_name,
         changed:
           Enum.map(resolved, fn {rel, _abs, edits} -> %{path: rel, edits: length(edits)} end),
         edits: resolved |> Enum.map(fn {_rel, _abs, edits} -> length(edits) end) |> Enum.sum()
       }}
    end
  end

  # A server that answers with no edits has decided the symbol cannot be
  # renamed from that position. Reporting success with zero files changed
  # would read as "done".
  defp resolve_edit_targets([], _context), do: {:error, :rename_not_possible}

  # Every file the server wants to touch is re-checked against the same
  # containment as a direct write. A language server indexes outside the
  # workspace, so without this a rename could write to a dependency's source
  # or anywhere else it happens to have indexed.
  defp resolve_edit_targets(file_edits, context) do
    Enum.reduce_while(file_edits, {:ok, []}, fn %{uri: uri, edits: edits}, {:ok, acc} ->
      path = Pool.uri_to_path(uri)

      case Fs.resolve(path, context) do
        {:ok, abs} -> {:cont, {:ok, [{relative_to_root(abs, context), abs, edits} | acc]}}
        {:error, _reason} -> {:halt, {:error, {:rename_outside_workspace, path}}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_edits(resolved) do
    Enum.reduce_while(resolved, :ok, fn {_rel, abs, edits}, :ok ->
      with {:ok, content} <- File.read(abs),
           {:ok, updated} <- apply_text_edits(content, edits),
           :ok <- File.write(abs, updated) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Edits are applied last-first so an earlier edit's offset shift cannot
  # invalidate a later one's range. LSP guarantees the ranges within a file
  # do not overlap, so sorting by start position is enough.
  defp apply_text_edits(content, edits) do
    {lines, trailing_newline?} = split_lines(content)

    edits
    |> Enum.sort_by(fn %{range: r} -> {r.start.line, r.start.character} end, :desc)
    |> Enum.reduce_while({:ok, lines}, fn edit, {:ok, acc} ->
      case splice(acc, edit) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        :error -> {:halt, {:error, {:edit_out_of_range, edit.range}}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, join_lines(updated, trailing_newline?)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp splice(lines, %{range: range, new_text: new_text}) do
    %{start: %{line: sl, character: sc}, end: %{line: el, character: ec}} = range

    with true <- sl >= 0 and el >= sl,
         start_line when is_binary(start_line) <- Enum.at(lines, sl),
         end_line when is_binary(end_line) <- Enum.at(lines, el),
         {:ok, head, _} <- utf16_split(start_line, sc),
         {:ok, _, tail} <- utf16_split(end_line, ec) do
      replacement = String.split(head <> new_text <> tail, "\n")
      {:ok, Enum.slice(lines, 0, sl) ++ replacement ++ Enum.drop(lines, el + 1)}
    else
      _ -> :error
    end
  end

  # LSP `character` counts UTF-16 code units, not codepoints or bytes. On a
  # line holding anything outside the BMP-free ASCII range, slicing by
  # codepoint cuts in the wrong place and the written file is corrupt. Cut in
  # UTF-16 and convert back; an offset landing inside a surrogate pair fails
  # the round trip and is refused rather than written.
  defp utf16_split(line, offset) when offset >= 0 do
    utf16 = :unicode.characters_to_binary(line, :utf8, {:utf16, :little})
    at = offset * 2

    with true <- is_binary(utf16) and at <= byte_size(utf16),
         head when is_binary(head) <- to_utf8(binary_part(utf16, 0, at)),
         tail when is_binary(tail) <- to_utf8(binary_part(utf16, at, byte_size(utf16) - at)) do
      {:ok, head, tail}
    else
      _ -> :error
    end
  end

  defp utf16_split(_line, _offset), do: :error

  defp to_utf8(utf16), do: :unicode.characters_to_binary(utf16, {:utf16, :little}, :utf8)

  # Local line splitting: the trailing newline is carried as a flag rather
  # than an empty last line, so applying an edit cannot add or drop one.
  defp split_lines(""), do: {[], false}

  defp split_lines(content) do
    if String.ends_with?(content, "\n") do
      {content |> binary_part(0, byte_size(content) - 1) |> String.split("\n"), true}
    else
      {String.split(content, "\n"), false}
    end
  end

  defp join_lines([], _trailing?), do: ""
  defp join_lines(lines, true), do: Enum.join(lines, "\n") <> "\n"
  defp join_lines(lines, false), do: Enum.join(lines, "\n")

  # Rejected here rather than sent: a server asked to rename to a name with a
  # newline or a null byte in it does unpredictable things to the files it
  # writes, and this tool writes them.
  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed != "" and not String.contains?(name, ["\n", "\r", "\0"]) do
      {:ok, trimmed}
    else
      {:error, :invalid_name}
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  # -- shared -----------------------------------------------------------------

  # Resolve, read, and tell the server the file's current bytes. Without the
  # `did_open`, a server publishes no diagnostics for the file and answers
  # position queries against a document it has never seen.
  defp open(path, context) do
    with {:ok, pool} <- fetch_pool(context),
         {:ok, abs} <- Fs.resolve(path, context),
         {:ok, content} <- File.read(abs),
         {:ok, client, server} <- Pool.client_for(pool, abs),
         :ok <- LSPContext.did_open(client, Pool.path_to_uri(abs), server.language_id, content) do
      {:ok, abs, client, server}
    end
  end

  defp fetch_pool(context) do
    case is_map(context) && Map.get(context, :lsp_pool) do
      pool when is_pid(pool) ->
        if Process.alive?(pool), do: {:ok, pool}, else: {:error, :lsp_not_available}

      _ ->
        {:error, :lsp_not_available}
    end
  end

  # 1-based in, 0-based out.
  defp position(params) do
    case {Map.get(params, :line), Map.get(params, :column, 1)} do
      {line, column} when is_integer(line) and line > 0 and is_integer(column) and column > 0 ->
        {:ok, line - 1, column - 1}

      {nil, _column} ->
        {:error, :line_required}

      _ ->
        {:error, :invalid_position}
    end
  end

  defp render_diagnostic(diagnostic) do
    %{
      severity: to_string(diagnostic.severity),
      line: diagnostic.range.start.line + 1,
      column: diagnostic.range.start.character + 1,
      message: diagnostic.message,
      source: diagnostic.source
    }
  end

  defp render_symbol(symbol) do
    %{
      name: symbol.name,
      kind: to_string(symbol.kind),
      line: symbol.range.start.line + 1,
      children: Enum.map(symbol.children, &render_symbol/1)
    }
  end

  defp render_locations(locations, context) do
    locations
    |> Enum.flat_map(&render_location(&1, context))
    |> Enum.uniq()
  end

  defp render_location(%{uri: uri, range: range}, context) do
    path = Pool.uri_to_path(uri)
    entry = %{line: range.start.line + 1, column: range.start.character + 1}

    case Fs.resolve(path, context) do
      {:ok, abs} ->
        [Map.put(entry, :path, relative_to_root(abs, context))]

      {:error, _reason} ->
        # Outside the workspace: a dependency or the standard library. Useful
        # to a normal session, a disclosure in a jailed one.
        if jailed?(context), do: [], else: [Map.put(entry, :path, path)]
    end
  end

  defp jailed?(context), do: is_map(context) and Map.get(context, :jail) not in [nil, false]

  defp relative_to_root(abs, context) do
    root = (is_map(context) && Map.get(context, :cwd)) || Fs.working_dir()

    case Path.relative_to(abs, root) do
      ^abs -> abs
      relative -> relative
    end
  end
end
