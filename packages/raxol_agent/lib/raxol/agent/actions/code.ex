defmodule Raxol.Agent.Actions.Code do
  @moduledoc """
  Mutating, cwd-scoped coding Actions for LLM tool use: `write_file`,
  `edit_file`, `bash`, `grep`, `glob`.

  These are the write/execute complement to the read-only
  `Raxol.Agent.Actions.Fs` (`list_dir`/`read_file`/`file_stat`) and the
  in-memory `Raxol.Agent.Actions.Vfs`. Together they make a ReAct run a
  real coding agent that touches the actual filesystem the BEAM runs on.

  ## Path discipline

  Every path is expanded relative to the working directory and must stay
  under it — `../` escapes and absolute paths outside cwd are rejected
  with `:outside_cwd`. Path safety is shared with `Fs` (`Fs.resolve/1`,
  `Fs.working_dir/0`); this module never re-implements it.

  ## Gating

  `write_file`, `edit_file`, and `bash` are marked `sensitive: true`, so
  the default tool-call policy (`Raxol.Agent.ToolPolicy.deny_sensitive/0`)
  DENIES them unless the run opts in — a prompt-injected model cannot
  write to disk or run a shell just by emitting the tool call. A surface
  enables them by installing a `:tool_authorizer` in the run context (an
  interactive approval prompter, an allowlist, or `allow_all/0` for a
  trusted operator). `grep` and `glob` are read-only and always allowed.

  `bash` additionally honors a `Raxol.Agent.Sandbox.Shell` placed in the
  context under `:shell_sandbox`: the command is checked against its
  allow/deny policy before any process spawns. Absent, the command runs
  (the `sensitive` gate already guards the LLM path).

  ## Diff-shaped results

  `write_file` and `edit_file` return `%{path, old, new, language}` so the
  harness contract (`Raxol.Agent.Contract`) renders the change as a
  foldable diff block rather than an opaque tool row. When either the
  before or after image exceeds `#{div(32_768, 1024)}KB` the diff is
  dropped in favor of a compact summary (byte counts) — a large-file
  write must not blow up the transcript or the model's context.
  """

  alias Raxol.Agent.Actions.Fs

  # Before/after images larger than this drop the diff for a summary, so a
  # large-file write never bloats the transcript or the LLM tool-result echo.
  @max_diff_image_bytes 32_768
  # Cap for captured shell / read output.
  @max_output_bytes 65_536
  # Bound for the pure-Elixir grep fallback's file walk.
  @grep_max_files_scanned 5_000
  @grep_pruned_dirs ~w(.git _build deps node_modules .elixir_ls priv/plts)

  defmodule Write do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "write_file",
      sensitive: true,
      description:
        "Create a file (relative to the current working directory) with " <>
          "the given content. Refuses to clobber an existing file unless " <>
          "`overwrite` is true: use `edit_file` for targeted changes. " <>
          "Parent directories are created as needed.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File to write"],
          content: [
            type: :string,
            required: true,
            description: "Full file content to write"
          ],
          overwrite: [
            type: :boolean,
            default: false,
            description: "Allow replacing an existing file (default false)"
          ]
        ],
        output: [
          path: [type: :string],
          old: [type: :string],
          new: [type: :string],
          language: [type: :string],
          created: [type: :boolean]
        ]
      ]

    @impl true
    def run(%{path: path, content: content} = params, context) do
      overwrite = Map.get(params, :overwrite, false)

      with {:ok, abs} <- Fs.resolve(path, context) do
        Raxol.Agent.Actions.Code.write_file(abs, path, content, overwrite)
      end
    end
  end

  defmodule Edit do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "edit_file",
      sensitive: true,
      description:
        "Replace `old_string` with `new_string` in a file (relative to " <>
          "the current working directory). `old_string` must match exactly " <>
          "once unless `replace_all` is true. Returns the before/after diff.",
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
          ],
          replace_all: [
            type: :boolean,
            default: false,
            description: "Replace every occurrence instead of requiring one"
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
    def run(
          %{path: path, old_string: old_string, new_string: new_string} = params,
          context
        ) do
      replace_all = Map.get(params, :replace_all, false)

      with :ok <- reject_noop(old_string, new_string),
           {:ok, abs} <- Fs.resolve(path, context),
           {:ok, content} <- File.read(abs),
           {:ok, count} <- match_count(content, old_string, replace_all) do
        Raxol.Agent.Actions.Code.write_edit(
          abs,
          path,
          content,
          {old_string, new_string, replace_all},
          count
        )
      end
    end

    defp reject_noop(same, same), do: {:error, :no_change}
    defp reject_noop(_old, _new), do: :ok

    defp match_count(content, old_string, replace_all) do
      case {count_occurrences(content, old_string), replace_all} do
        {0, _} -> {:error, :no_match}
        {n, false} when n > 1 -> {:error, :not_unique}
        {n, _} -> {:ok, n}
      end
    end

    defp count_occurrences(content, needle) do
      content |> String.split(needle) |> length() |> Kernel.-(1)
    end
  end

  defmodule Bash do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "bash",
      sensitive: true,
      description:
        "Run a shell command via `/bin/sh -c` in the current working " <>
          "directory. Returns combined stdout+stderr and the exit status. " <>
          "Output is captured (not interactive) and truncated past " <>
          "#{div(65_536, 1024)}KB.",
      schema: [
        input: [
          command: [
            type: :string,
            required: true,
            description: "Shell command line to execute"
          ],
          timeout_ms: [
            type: :integer,
            description: "Max runtime in ms (default 30000)"
          ],
          cd: [
            type: :string,
            description: "Working directory for the command, relative to cwd"
          ]
        ],
        output: [
          command: [type: :string],
          stdout: [type: :string],
          exit_status: [type: :integer],
          truncated: [type: :boolean]
        ]
      ]

    @impl true
    def run(%{command: command} = params, context) do
      timeout = Map.get(params, :timeout_ms) || 30_000

      with :ok <- Raxol.Agent.Actions.Code.shell_jail_allow(context),
           :ok <- Raxol.Agent.Actions.Code.sandbox_allow(context, command),
           {:ok, cd} <- resolve_cd(Map.get(params, :cd), context) do
        {output, status} =
          Raxol.Agent.Actions.Code.run_shell(command, cd, timeout)

        {truncated, output} = Raxol.Agent.Actions.Code.truncate_output(output)

        {:ok,
         %{
           command: command,
           stdout: output,
           exit_status: status,
           truncated: truncated
         }}
      end
    end

    # No `cd` given → run in the working dir. A `cd` must stay under cwd.
    defp resolve_cd(nil, context), do: {:ok, Fs.working_dir(context)}
    defp resolve_cd(rel, context), do: Fs.resolve(rel, context)
  end

  defmodule Grep do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "grep",
      description:
        "Search file contents for a regular expression under a directory " <>
          "(relative to cwd). Uses ripgrep when available, else a pure " <>
          "search. Returns matches as {path, line, text}.",
      schema: [
        input: [
          pattern: [
            type: :string,
            required: true,
            description: "Regular expression to search for"
          ],
          path: [
            type: :string,
            description: "Directory to search under (default \".\")"
          ],
          ignore_case: [
            type: :boolean,
            default: false,
            description: "Case-insensitive match"
          ],
          max_results: [
            type: :integer,
            description: "Cap on returned matches (default 200)"
          ]
        ],
        output: [
          count: [type: :integer],
          truncated: [type: :boolean],
          matches: [type: :list]
        ]
      ]

    @impl true
    def run(%{pattern: pattern} = params, context) do
      path = Map.get(params, :path) || "."
      ignore_case = Map.get(params, :ignore_case, false)
      max_results = Map.get(params, :max_results) || 200

      with {:ok, abs} <- Fs.resolve(path, context) do
        Raxol.Agent.Actions.Code.grep(
          pattern,
          abs,
          ignore_case,
          max_results,
          context
        )
      end
    end
  end

  defmodule Glob do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "glob",
      description:
        "List files matching a wildcard pattern (e.g. \"**/*.ex\"), " <>
          "relative to the current working directory. Returns cwd-relative " <>
          "paths, sorted.",
      schema: [
        input: [
          pattern: [
            type: :string,
            required: true,
            description: "Wildcard, e.g. \"lib/**/*.ex\""
          ],
          path: [
            type: :string,
            description: "Base directory to glob under (default \".\")"
          ]
        ],
        output: [
          count: [type: :integer],
          truncated: [type: :boolean],
          paths: [type: {:list, :string}]
        ]
      ]

    @max_paths 500

    @impl true
    def run(%{pattern: pattern} = params, context) do
      base = Map.get(params, :path) || "."

      with {:ok, abs_base} <- Fs.resolve(base, context) do
        cwd = Fs.working_dir(context)

        all =
          abs_base
          |> Path.join(pattern)
          |> Path.wildcard()
          |> Enum.filter(&under?(&1, cwd))
          |> Enum.map(&Path.relative_to(&1, cwd))
          |> Enum.sort()

        {truncated, paths} = cap(all, @max_paths)
        {:ok, %{paths: paths, count: length(paths), truncated: truncated}}
      end
    end

    defp under?(abs, cwd),
      do: abs == cwd or String.starts_with?(abs, cwd <> "/")

    defp cap(list, max) when length(list) > max,
      do: {true, Enum.take(list, max)}

    defp cap(list, _max), do: {false, list}
  end

  @doc "All coding actions (write/edit/bash + grep/glob), for a ReAct run's `actions:`."
  @spec all() :: [module()]
  def all, do: [Write, Edit, Bash, Grep, Glob]

  @doc false
  @spec write_file(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def write_file(abs, path, content, overwrite) do
    exists = File.regular?(abs)

    if exists and not overwrite do
      {:error, :file_exists}
    else
      persist_file(abs, path, content, exists)
    end
  end

  defp persist_file(abs, path, content, exists) do
    old = if exists, do: File.read!(abs), else: ""
    :ok = File.mkdir_p(Path.dirname(abs))

    case File.write(abs, content) do
      :ok -> {:ok, diff_result(path, old, content, %{created: not exists})}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec write_edit(
          String.t(),
          String.t(),
          String.t(),
          {String.t(), String.t(), boolean()},
          integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def write_edit(
        abs,
        path,
        content,
        {old_string, new_string, replace_all},
        count
      ) do
    updated =
      String.replace(content, old_string, new_string, global: replace_all)

    case File.write(abs, updated) do
      :ok -> {:ok, diff_result(path, content, updated, %{replacements: count})}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The read-only, non-sensitive subset (`grep`, `glob`). Safe to expose
  without a `:tool_authorizer` opt-in, unlike the mutating actions.
  """
  @spec read_only() :: [module()]
  def read_only, do: [Grep, Glob]

  @doc """
  Build a diff-shaped `write_file`/`edit_file` result.

  Returns `%{path, old, new, language}` (plus `extra`) when both images
  are within the diff cap, so the contract renders a diff block. For a
  large before/after image the diff is dropped for a compact byte-count
  summary — a big write must not bloat the transcript or the LLM echo.
  """
  @spec diff_result(String.t(), String.t(), String.t(), map()) :: map()
  def diff_result(path, old, new, extra) do
    base = Map.merge(extra, %{path: path, language: language_for(path)})

    if byte_size(old) <= @max_diff_image_bytes and
         byte_size(new) <= @max_diff_image_bytes do
      Map.merge(base, %{old: old, new: new})
    else
      Map.merge(base, %{
        old_bytes: byte_size(old),
        new_bytes: byte_size(new),
        truncated: true
      })
    end
  end

  @doc """
  Refuse the shell surface for a jailed (multi-tenant) session that carries
  no OS-level sandbox.

  The cwd jail confines the *fs* tools (they resolve every path through
  `Fs.resolve/2`), but a `/bin/sh -c` command string is not a path — it can
  `cd ..`, name an absolute path, or read the daemon's own files, none of
  which `{:cd, cwd}` prevents. On a shared host that is a cross-tenant read
  and write primitive, so until per-tenant OS confinement (separate uid /
  chroot / bwrap, wired as a `:shell_sandbox`) exists, the only safe posture
  is to withhold the shell entirely from a jailed session.
  """
  @spec shell_jail_allow(map()) :: :ok | {:error, :shell_disabled_in_jail}
  def shell_jail_allow(context) do
    jailed? = is_map(context) and Map.get(context, :jail) not in [nil, false]
    sandboxed? = match?(%Raxol.Agent.Sandbox.Shell{}, Map.get(context, :shell_sandbox))

    if jailed? and not sandboxed?,
      do: {:error, :shell_disabled_in_jail},
      else: :ok
  end

  @doc """
  Check a shell command against a `Raxol.Agent.Sandbox.Shell` in the
  context under `:shell_sandbox`. Absent → allowed.
  """
  @spec sandbox_allow(map(), String.t()) :: :ok | {:error, term()}
  def sandbox_allow(context, command) do
    case Map.get(context, :shell_sandbox) do
      %Raxol.Agent.Sandbox.Shell{} = sandbox ->
        if Raxol.Agent.Sandbox.Shell.allowed?(sandbox, command),
          do: :ok,
          else: {:error, {:shell_denied, command}}

      _ ->
        :ok
    end
  end

  @doc false
  @spec truncate_output(binary()) :: {boolean(), binary()}
  def truncate_output(output) when byte_size(output) > @max_output_bytes,
    do: {true, binary_part(output, 0, @max_output_bytes)}

  def truncate_output(output), do: {false, output}

  @doc """
  Run `command` via `/bin/sh -c` in `cd`, returning `{combined_output,
  exit_status}`. `env` adds environment variables (`{name, value}`
  strings). On timeout the spawned OS process group is SIGKILLed (so no
  child is orphaned), the port is closed, and `exit_status` is `:timeout`.
  """
  @spec run_shell(String.t(), String.t(), pos_integer(), [
          {String.t(), String.t()}
        ]) ::
          {binary(), integer() | :timeout}
  def run_shell(command, cd, timeout, env \\ []) do
    charlist_env =
      Enum.map(env, fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    base = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, ["-c", command]},
      {:cd, cd}
    ]

    port_opts =
      if charlist_env == [], do: base, else: [{:env, charlist_env} | base]

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    collect_port(port, port_os_pid(port), [], timeout)
  end

  defp collect_port(port, os_pid, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, os_pid, [data | acc], timeout)

      {^port, {:exit_status, status}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      timeout ->
        # A wall-clock timeout means the caller stopped waiting -- but "stopped
        # waiting" must not leave the OS process running unattended. Fire the
        # same process-group SIGKILL `Raxol.Agent.Interrupt` uses so a rogue
        # `sleep 600` (and every child it spawned) is actually dead, not
        # orphaned; `Port.close/1` alone leaves the OS process alive.
        Raxol.Agent.Interrupt.kill_os_pid(os_pid)
        Port.close(port)
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), :timeout}
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  @doc false
  @spec grep(String.t(), String.t(), boolean(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def grep(pattern, abs_dir, ignore_case, max_results, context \\ %{}) do
    case System.find_executable("rg") do
      nil ->
        grep_native(pattern, abs_dir, ignore_case, max_results, context)

      rg ->
        grep_ripgrep(rg, pattern, abs_dir, ignore_case, max_results, context)
    end
  end

  # ripgrep: fast path. Args are passed as a list (no shell), so the pattern
  # is never shell-interpreted.
  defp grep_ripgrep(rg, pattern, abs_dir, ignore_case, max_results, context) do
    cwd = Fs.working_dir(context)

    args =
      ["--line-number", "--no-heading", "--color=never"] ++
        if(ignore_case, do: ["--ignore-case"], else: []) ++
        ["--", pattern, abs_dir]

    case System.cmd(rg, args, stderr_to_stdout: false) do
      {out, status} when status in [0, 1] ->
        matches =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_rg_line(&1, cwd))

        {truncated, capped} = cap_matches(matches, max_results)
        {:ok, %{matches: capped, count: length(capped), truncated: truncated}}

      {_out, _status} ->
        # rg failed (e.g. bad regex) — fall back to the native scanner, which
        # reports a regex compile error as {:error, _} rather than a crash.
        grep_native(pattern, abs_dir, ignore_case, max_results, context)
    end
  end

  # "path:line:text" → %{path (cwd-relative), line, text}. A path with no
  # colon or a non-integer line is skipped rather than crashing the fold.
  defp parse_rg_line(line, cwd) do
    case String.split(line, ":", parts: 3) do
      [path, num, text] ->
        case Integer.parse(num) do
          {n, ""} -> [%{path: Path.relative_to(path, cwd), line: n, text: text}]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp grep_native(pattern, abs_dir, ignore_case, max_results, context) do
    opts = if ignore_case, do: [:caseless], else: []

    case Regex.compile(pattern, opts) do
      {:ok, regex} ->
        cwd = Fs.working_dir(context)

        matches =
          abs_dir
          |> list_files(@grep_max_files_scanned)
          |> Enum.flat_map(&scan_file(&1, regex, cwd))

        {truncated, capped} = cap_matches(matches, max_results)
        {:ok, %{matches: capped, count: length(capped), truncated: truncated}}

      {:error, _} ->
        {:error, :bad_pattern}
    end
  end

  defp scan_file(abs_path, regex, cwd) do
    case File.read(abs_path) do
      {:ok, content} ->
        scan_content(content, regex, Path.relative_to(abs_path, cwd))

      {:error, _} ->
        []
    end
  end

  defp scan_content(content, regex, rel) do
    if String.valid?(content) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, n} -> %{path: rel, line: n, text: line} end)
    else
      []
    end
  end

  # Bounded recursive file walk, pruning heavy/build dirs and hidden dirs.
  defp list_files(root, limit) do
    root |> do_walk([], limit) |> elem(0) |> Enum.reverse()
  end

  defp do_walk(_path, acc, 0), do: {acc, 0}

  defp do_walk(path, acc, budget) do
    cond do
      File.regular?(path) -> {[path | acc], budget - 1}
      File.dir?(path) and not pruned?(path) -> walk_dir(path, acc, budget)
      true -> {acc, budget}
    end
  end

  defp walk_dir(path, acc, budget) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, {acc, budget}, fn entry, {a, b} ->
          do_walk(Path.join(path, entry), a, b)
        end)

      {:error, _} ->
        {acc, budget}
    end
  end

  defp pruned?(path) do
    base = Path.basename(path)
    String.starts_with?(base, ".") or base in @grep_pruned_dirs
  end

  defp cap_matches(list, max) when length(list) > max,
    do: {true, Enum.take(list, max)}

  defp cap_matches(list, _max), do: {false, list}

  @doc """
  Map a file path to a fenced-code language hint from its extension, for
  the diff block's syntax label. Unknown extensions map to `"text"`.
  """
  @spec language_for(String.t()) :: String.t()
  def language_for(path) do
    ext = path |> Path.extname() |> String.downcase()
    base = Path.basename(path)

    cond do
      Map.has_key?(language_by_ext(), ext) -> Map.fetch!(language_by_ext(), ext)
      base in ~w(Dockerfile) -> "dockerfile"
      base in ~w(Makefile) -> "makefile"
      true -> "text"
    end
  end

  defp language_by_ext do
    %{
      ".ex" => "elixir",
      ".exs" => "elixir",
      ".eex" => "eex",
      ".heex" => "heex",
      ".erl" => "erlang",
      ".js" => "javascript",
      ".ts" => "typescript",
      ".tsx" => "tsx",
      ".jsx" => "jsx",
      ".json" => "json",
      ".py" => "python",
      ".rb" => "ruby",
      ".go" => "go",
      ".rs" => "rust",
      ".c" => "c",
      ".h" => "c",
      ".cpp" => "cpp",
      ".hpp" => "cpp",
      ".lua" => "lua",
      ".sh" => "bash",
      ".bash" => "bash",
      ".zsh" => "bash",
      ".sql" => "sql",
      ".toml" => "toml",
      ".yaml" => "yaml",
      ".yml" => "yaml",
      ".md" => "markdown",
      ".html" => "html",
      ".css" => "css",
      ".nr" => "rust",
      ".sol" => "solidity"
    }
  end
end
