defmodule Raxol.Agent.Actions.Workspace do
  @moduledoc """
  Mutating + search Actions on the real working directory, for LLM tool use.

  The read-only siblings live in `Raxol.Agent.Actions.Fs` (`list_dir`,
  `read_file`, `file_stat`); this module adds the CONSEQUENTIAL surface
  (`write_file`, `edit_file`) plus two read-only search tools (`glob`,
  `grep`). Every path is expanded and confined to the working directory
  by the SAME `Raxol.Agent.Actions.Fs.resolve/1` gate the read-only
  actions use — `../` escapes and absolute paths outside cwd are rejected
  with `:outside_cwd`, so a prompt-injected path can never write outside
  the sandbox.

  ## Consequentiality is a HARNESS decision, not an Action flag

  `write_file`/`edit_file` are NOT marked `sensitive: true`. The
  `sensitive` flag denies a tool OUTRIGHT on the default policy (it is for
  fund-movers). A file write must instead be ASK-gated: the harness
  approval path (`Raxol.Agent.Harness.SessionInbox`) holds the frontier
  on a keyboard answer before the write runs. Classification of which tool
  names are consequential lives in `Raxol.Agent.Harness.ToolClassifier`, a
  single source of truth both the gate and the tests read — so the Action
  stays a pure operation and the *policy* stays in one place.

  ## Diff receipts

  `edit_file` and `write_file` return the FULL pre- and post-image of the
  file under `:old`/`:new` (plus `:path` and a `:language` guess) — exactly
  the `%{path, old, new, language}` shape `Raxol.UI.Components.Harness.Block`'s
  `extract_diff_content/1` reads off the tool-result event payload to render
  a foldable ± diff block. The tool result is a fact with a receipt: the
  bytes that changed are on the record, not a claim that they did.
  """

  alias Raxol.Agent.Actions.Fs

  @max_bytes 1_048_576

  defmodule WriteFile do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "write_file",
      description:
        "Create or overwrite a text file (relative to the current working " <>
          "directory) with the given content. Returns a diff of the change.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File to write"],
          content: [
            type: :string,
            required: true,
            description: "Full new file contents"
          ]
        ],
        output: [
          path: [type: :string],
          old: [type: :string],
          new: [type: :string],
          language: [type: :string],
          bytes_written: [type: :integer],
          created: [type: :boolean]
        ]
      ]

    @impl true
    def run(%{path: path, content: content}, _context) do
      Raxol.Agent.Actions.Workspace.do_write(path, content)
    end
  end

  defmodule EditFile do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "edit_file",
      description:
        "Replace an exact substring in a text file (relative to cwd). " <>
          "`old_string` must occur EXACTLY ONCE; the file must already " <>
          "exist. Returns a diff of the change.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File to edit"],
          old_string: [
            type: :string,
            required: true,
            description: "Exact text to replace (must be unique in the file)"
          ],
          new_string: [
            type: :string,
            required: true,
            description: "Replacement text"
          ]
        ],
        output: [
          path: [type: :string],
          old: [type: :string],
          new: [type: :string],
          language: [type: :string],
          replacements: [type: :integer]
        ]
      ]

    @impl true
    def run(%{path: path, old_string: old_string, new_string: new_string}, _ctx) do
      Raxol.Agent.Actions.Workspace.do_edit(path, old_string, new_string)
    end
  end

  defmodule Glob do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "glob",
      description:
        "List files under the working directory matching a wildcard " <>
          "pattern (e.g. \"**/*.ex\"). Read-only.",
      schema: [
        input: [
          pattern: [
            type: :string,
            required: true,
            description: "Wildcard pattern relative to cwd"
          ]
        ],
        output: [
          pattern: [type: :string],
          matches: [type: {:list, :string}],
          truncated: [type: :boolean]
        ]
      ]

    @max_matches 500

    @impl true
    def run(%{pattern: pattern}, _context) do
      cwd = Fs.working_dir()
      # Confine: a pattern that would reach outside cwd is rejected before
      # any filesystem walk. Path.wildcard expands from cwd.
      abs_pattern = Path.expand(pattern, cwd)

      if abs_pattern == cwd or String.starts_with?(abs_pattern, cwd <> "/") do
        all =
          abs_pattern
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, cwd))
          |> Enum.sort()

        truncated = length(all) > @max_matches

        {:ok,
         %{
           pattern: pattern,
           matches: Enum.take(all, @max_matches),
           truncated: truncated
         }}
      else
        {:error, :outside_cwd}
      end
    end
  end

  defmodule Grep do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "grep",
      description:
        "Search for a regex in a single file (relative to cwd) and return " <>
          "matching lines with 1-based line numbers. Read-only.",
      schema: [
        input: [
          pattern: [
            type: :string,
            required: true,
            description: "Regex to search for"
          ],
          path: [type: :string, required: true, description: "File to search"]
        ],
        output: [
          pattern: [type: :string],
          path: [type: :string],
          matches: [type: {:list, :string}],
          count: [type: :integer]
        ]
      ]

    @max_matches 200

    @impl true
    def run(%{pattern: pattern, path: path}, _context) do
      with {:ok, regex} <- compile_regex(pattern),
           {:ok, abs} <- Fs.resolve(path),
           {:ok, content} <- File.read(abs) do
        matches =
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, n} -> "#{n}:#{line}" end)

        {:ok,
         %{
           pattern: pattern,
           path: path,
           matches: Enum.take(matches, @max_matches),
           count: length(matches)
         }}
      end
    end

    defp compile_regex(pattern) do
      case Regex.compile(pattern) do
        {:ok, regex} -> {:ok, regex}
        {:error, _} -> {:error, :invalid_pattern}
      end
    end
  end

  @doc "All workspace actions (mutating + search)."
  @spec all() :: [module()]
  def all, do: [WriteFile, EditFile, Glob, Grep]

  @doc false
  @spec do_write(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def do_write(path, content) when is_binary(content) do
    with :ok <- guard_size(content),
         {:ok, abs} <- Fs.resolve(path) do
      {created, old} =
        case File.read(abs) do
          {:ok, existing} -> {false, existing}
          {:error, _} -> {true, ""}
        end

      case File.mkdir_p(Path.dirname(abs)) do
        :ok ->
          case File.write(abs, content) do
            :ok ->
              {:ok,
               %{
                 path: path,
                 old: old,
                 new: content,
                 language: language_of(path),
                 bytes_written: byte_size(content),
                 created: created
               }}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec do_edit(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def do_edit(path, old_string, new_string) do
    with {:ok, abs} <- Fs.resolve(path),
         {:ok, content} <- File.read(abs),
         :ok <- guard_size(content),
         {:ok, replaced} <- replace_unique(content, old_string, new_string),
         :ok <- File.write(abs, replaced) do
      {:ok,
       %{
         path: path,
         old: content,
         new: replaced,
         language: language_of(path),
         replacements: 1
       }}
    end
  end

  @doc """
  The SHA-256 (hex) of a file's content -- the staleness anchor. Captured
  at approval time and re-checked at execution time so an edit/write can
  never silently apply against a file that changed underneath the operator
  between the question and the answer (the label-vs-binding guard).
  """
  @spec content_hash(String.t()) :: String.t()
  def content_hash(content) when is_binary(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @doc """
  Compute the `{path, old, new, language, base_hash}` image of a proposed
  `write_file` WITHOUT writing -- so the approval can show the operator the
  exact diff `y` will produce. `old` is the current file (or `""` for a new
  file, whose `base_hash` is `:absent`).
  """
  @spec preview_write(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def preview_write(path, content) when is_binary(content) do
    with :ok <- guard_size(content),
         {:ok, abs} <- Fs.resolve(path) do
      {old, base_hash} = current_state(abs)

      {:ok,
       %{
         path: path,
         old: old,
         new: content,
         language: language_of(path),
         base_hash: base_hash
       }}
    end
  end

  @doc """
  Compute the `{path, old, new, language, base_hash}` image of a proposed
  `edit_file` WITHOUT writing. Fails exactly as `do_edit/3` would (missing/
  non-unique target), so an unshowable edit is refused before the question.
  """
  @spec preview_edit(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def preview_edit(path, old_string, new_string) do
    with {:ok, abs} <- Fs.resolve(path),
         {:ok, content} <- File.read(abs),
         :ok <- guard_size(content),
         {:ok, replaced} <- replace_unique(content, old_string, new_string) do
      {:ok,
       %{
         path: path,
         old: content,
         new: replaced,
         language: language_of(path),
         base_hash: content_hash(content)
       }}
    end
  end

  @doc """
  Verify the file at `path` still hashes to `base_hash` (the image captured
  at approval time). `{:error, :stale}` when it drifted -- the caller must
  then refuse to apply and re-ask, never blindly overwrite.
  """
  @spec verify_unchanged(String.t(), String.t() | :absent) ::
          :ok | {:error, :stale} | {:error, term()}
  def verify_unchanged(path, base_hash) do
    with {:ok, abs} <- Fs.resolve(path) do
      {_content, current_hash} = current_state(abs)
      if current_hash == base_hash, do: :ok, else: {:error, :stale}
    end
  end

  # Current on-disk state as `{content, hash}`; a missing file is
  # `{"", :absent}` so "created since approval" is itself drift.
  defp current_state(abs) do
    case File.read(abs) do
      {:ok, content} -> {content, content_hash(content)}
      {:error, _} -> {"", :absent}
    end
  end

  # An edit MUST be unambiguous: the old_string has to occur exactly once,
  # or the model's intent is undefined and a blind replace could corrupt an
  # unrelated occurrence. Zero → :edit_target_not_found; more than one →
  # :edit_target_not_unique. Both are honest, machine-checkable refusals.
  defp replace_unique(content, old_string, new_string) do
    case count_occurrences(content, old_string) do
      0 -> {:error, :edit_target_not_found}
      1 -> {:ok, String.replace(content, old_string, new_string)}
      _ -> {:error, :edit_target_not_unique}
    end
  end

  defp count_occurrences(_content, ""), do: 0

  defp count_occurrences(content, needle),
    do: length(String.split(content, needle)) - 1

  defp guard_size(content) do
    if byte_size(content) > @max_bytes, do: {:error, :file_too_large}, else: :ok
  end

  # A best-effort language tag from the extension, for the diff block's
  # syntax hinting. Never load-bearing — `nil` when unknown.
  defp language_of(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".json" -> "json"
      ".md" -> "markdown"
      ".css" -> "css"
      ".html" -> "html"
      ".py" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ".sh" -> "bash"
      ".toml" -> "toml"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      _ -> nil
    end
  end
end
