defmodule Raxol.Plugins.Examples.GitIntegrationPlugin do
  @moduledoc """
  Git Integration Plugin for Raxol Terminal

  Provides comprehensive git repository management and visualization.
  Demonstrates:
  - Git command execution and parsing
  - Repository status monitoring
  - Branch management and switching
  - Commit history visualization
  - Diff viewing
  - Stage/unstage operations
  - Real-time repository watching
  - Git graph visualization
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.ANSI.TextFormatting

  # Plugin Manifest
  def manifest do
    %{
      name: "git-integration",
      version: "1.0.0",
      description: "Advanced git operations and repository visualization",
      author: "Raxol Team",
      dependencies: %{
        "raxol-core" => "~> 1.5"
      },
      capabilities: [
        :shell_command,
        :file_watcher,
        :ui_panel,
        :keyboard_input,
        :status_line
      ],
      config_schema: %{
        auto_refresh: %{type: :boolean, default: true},
        refresh_interval: %{type: :integer, default: 2000},
        show_untracked: %{type: :boolean, default: true},
        show_ignored: %{type: :boolean, default: false},
        panel_width: %{type: :integer, default: 40},
        position: %{type: :string, default: "right", enum: ["left", "right"]},
        hotkey: %{type: :string, default: "ctrl+g"},
        graph_depth: %{type: :integer, default: 20},
        diff_context: %{type: :integer, default: 3}
      }
    }
  end

  # Plugin State
  defstruct [
    :config,
    :repo_path,
    :current_branch,
    :branches,
    :status,
    :commit_history,
    :selected_file,
    :selected_commit,
    :view_mode,
    :refresh_timer,
    :watcher_pid,
    :staged_changes,
    :unstaged_changes,
    :untracked_files
  ]

  # Public API
  # start_link is provided by BaseManager

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  def stage_file(file) do
    GenServer.call(__MODULE__, {:stage_file, file})
  end

  def unstage_file(file) do
    GenServer.call(__MODULE__, {:unstage_file, file})
  end

  def commit(message) do
    GenServer.call(__MODULE__, {:commit, message})
  end

  def checkout_branch(branch) do
    GenServer.call(__MODULE__, {:checkout_branch, branch})
  end

  def create_branch(name) do
    GenServer.call(__MODULE__, {:create_branch, name})
  end

  # BaseManager Callbacks
  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(config) do
    state = %__MODULE__{
      config: config,
      repo_path: find_git_repo(),
      view_mode: :status,
      selected_file: 0,
      selected_commit: 0
    }

    case state.repo_path do
      nil ->
        Log.info("Git Integration: No git repository found")
        {:ok, state}

      repo_path ->
        Log.info("Git Integration: Found repository at #{repo_path}")

        # Start file watcher and timer based on auto-refresh setting
        auto_refresh = Keyword.get(config, :auto_refresh, false)
        refresh_interval = Keyword.get(config, :refresh_interval, 5000)

        {watcher_pid, timer} =
          case auto_refresh do
            true ->
              watcher = start_file_watcher(repo_path)

              refresh_timer =
                :timer.send_interval(refresh_interval, :refresh)

              {watcher, refresh_timer}

            false ->
              {nil, nil}
          end

        # Initial data load
        updated_state =
          %{state | watcher_pid: watcher_pid, refresh_timer: timer}
          |> load_repository_data()

        {:ok, updated_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_status, _from, state) do
    status_data = %{
      repo_path: state.repo_path,
      current_branch: state.current_branch,
      staged_changes: length(state.staged_changes || []),
      unstaged_changes: length(state.unstaged_changes || []),
      untracked_files: length(state.untracked_files || [])
    }

    {:reply, status_data, state}
  end

  def handle_manager_call({:stage_file, file}, _from, state) do
    case run_git_command(["add", file], state.repo_path) do
      {_output, 0} ->
        updated_state = load_repository_data(state)
        {:reply, :ok, updated_state}

      {error, _code} ->
        Log.error("Failed to stage file #{file}: #{error}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_manager_call({:unstage_file, file}, _from, state) do
    case run_git_command(["reset", "HEAD", file], state.repo_path) do
      {_output, 0} ->
        updated_state = load_repository_data(state)
        {:reply, :ok, updated_state}

      {error, _code} ->
        Log.error("Failed to unstage file #{file}: #{error}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_manager_call({:commit, message}, _from, state) do
    case run_git_command(["commit", "-m", message], state.repo_path) do
      {output, 0} ->
        updated_state = load_repository_data(state)
        {:reply, {:ok, output}, updated_state}

      {error, _code} ->
        Log.error("Failed to commit: #{error}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_manager_call({:checkout_branch, branch}, _from, state) do
    case run_git_command(["checkout", branch], state.repo_path) do
      {_output, 0} ->
        updated_state = load_repository_data(state)
        {:reply, :ok, updated_state}

      {error, _code} ->
        Log.error("Failed to checkout branch #{branch}: #{error}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_manager_call({:create_branch, name}, _from, state) do
    case run_git_command(["checkout", "-b", name], state.repo_path) do
      {_output, 0} ->
        updated_state = load_repository_data(state)
        {:reply, :ok, updated_state}

      {error, _code} ->
        Log.error("Failed to create branch #{name}: #{error}")
        {:reply, {:error, error}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(:refresh, state) do
    updated_state = load_repository_data(state)
    {:noreply, updated_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:refresh, state) do
    updated_state = load_repository_data(state)
    {:noreply, updated_state}
  end

  def handle_manager_info({:file_event, _watcher_pid, {_path, _events}}, state) do
    # File changed, refresh repository data
    updated_state = load_repository_data(state)
    {:noreply, updated_state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cleanup timers and watchers using pattern matching
    _ =
      case state.refresh_timer do
        nil -> :ok
        timer -> :timer.cancel(timer)
      end

    _ =
      case state.watcher_pid do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

    :ok
  end

  # Private Functions

  defp find_git_repo(path \\ ".") do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], cd: path) do
      {repo_path, 0} -> String.trim(repo_path)
      _ -> nil
    end
  end

  defp load_repository_data(state) do
    case state.repo_path do
      nil ->
        state

      repo_path ->
        state
        |> load_current_branch(repo_path)
        |> load_branches(repo_path)
        |> load_status(repo_path)
        |> load_commit_history(repo_path)
    end
  end

  defp load_current_branch(state, repo_path) do
    case run_git_command(["branch", "--show-current"], repo_path) do
      {branch, 0} -> %{state | current_branch: String.trim(branch)}
      _ -> %{state | current_branch: "unknown"}
    end
  end

  defp load_branches(state, repo_path) do
    case run_git_command(["branch", "-a"], repo_path) do
      {output, 0} ->
        branches =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_branch_line/1)
          |> Enum.reject(&is_nil/1)

        %{state | branches: branches}

      _ ->
        %{state | branches: []}
    end
  end

  defp load_status(state, repo_path) do
    case run_git_command(["status", "--porcelain"], repo_path) do
      {output, 0} ->
        {staged, unstaged, untracked} = parse_status_output(output)

        %{
          state
          | staged_changes: staged,
            unstaged_changes: unstaged,
            untracked_files: untracked
        }

      _ ->
        %{state | staged_changes: [], unstaged_changes: [], untracked_files: []}
    end
  end

  defp load_commit_history(state, repo_path) do
    depth = Keyword.get(state.config, :graph_depth, 20)

    case run_git_command(["log", "--oneline", "-#{depth}"], repo_path) do
      {output, 0} ->
        commits =
          output
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_commit_line/1)

        %{state | commit_history: commits}

      _ ->
        %{state | commit_history: []}
    end
  end

  defp parse_branch_line("* " <> branch),
    do: %{name: branch, current: true, remote: false}

  defp parse_branch_line("  remotes/" <> branch) do
    %{name: branch, current: false, remote: true}
  end

  defp parse_branch_line("  " <> branch) do
    # Local branch (not remote) - use pattern matching instead of if
    case branch do
      "remotes/" <> _rest -> nil
      local_branch -> %{name: local_branch, current: false, remote: false}
    end
  end

  defp parse_branch_line(_), do: nil

  defp parse_status_output(output) do
    lines =
      String.split(output, "\n")
      |> Enum.reject(&(&1 == ""))

    staged = extract_staged(lines)
    unstaged = extract_unstaged(lines)
    untracked = extract_untracked(lines)

    {staged, unstaged, untracked}
  end

  defp extract_staged(lines) do
    Enum.filter(lines, &staged_line?/1)
    |> Enum.map(&parse_status_line/1)
  end

  defp staged_line?(line) do
    case String.at(line, 0) do
      " " -> false
      "?" -> false
      _ -> true
    end
  end

  defp extract_unstaged(lines) do
    Enum.filter(lines, &unstaged_line?/1)
    |> Enum.map(&parse_status_line/1)
  end

  defp unstaged_line?(line) do
    case {String.at(line, 0), String.at(line, 1)} do
      {_, " "} -> false
      {_, "?"} -> false
      _ -> true
    end
  end

  defp extract_untracked(lines) do
    Enum.filter(lines, &String.starts_with?(&1, "??"))
    |> Enum.map(&parse_status_line/1)
  end

  defp parse_status_line(line) do
    [status | path_parts] = String.split(line, " ", parts: 2)
    path = Enum.join(path_parts, " ")
    %{status: status, path: path}
  end

  defp parse_commit_line(line) do
    case String.split(line, " ", parts: 2) do
      [hash, message] -> %{hash: hash, message: message}
      _ -> %{hash: "unknown", message: line}
    end
  end

  defp run_git_command(args, repo_path) do
    # Verify directory exists and is accessible
    case File.exists?(repo_path) do
      true ->
        case System.cmd("git", args, cd: repo_path) do
          {output, 0} ->
            {output, 0}

          {_output, exit_code} ->
            # Get detailed error information
            {error_output, _} =
              System.cmd("git", args, cd: repo_path, stderr_to_stdout: true)

            {error_output, exit_code}
        end

      false ->
        {"Repository path does not exist: #{repo_path}", 1}
    end
  end

  defp start_file_watcher(_repo_path) do
    # This would integrate with a file watching system
    # Relies on the timer-based refresh
    nil
  end

  # UI Rendering Functions

  def render_panel(state, width, height) do
    case state.view_mode do
      :status -> render_status_view(state, width, height)
      :branches -> render_branches_view(state, width, height)
      :history -> render_history_view(state, width, height)
      :diff -> render_diff_view(state, width, height)
      # Default to status view
      nil -> render_status_view(state, width, height)
    end
  end

  defp render_status_view(state, width, height) do
    sections = [
      [render_header("Git Status", state.current_branch, width)],
      render_repo_section(state, width),
      render_changes_section(
        "Staged Changes",
        state.staged_changes,
        :staged,
        width
      ),
      render_changes_section(
        "Unstaged Changes",
        state.unstaged_changes,
        :unstaged,
        width
      ),
      render_changes_section(
        "Untracked Files",
        state.untracked_files,
        :untracked,
        width
      )
    ]

    sections
    |> List.flatten()
    |> Enum.take(height)
    |> pad_to_height(height, width)
  end

  defp render_repo_section(%{repo_path: nil}, _width), do: []
  defp render_repo_section(state, width), do: [render_repo_info(state, width)]

  defp render_changes_section(title, [_ | _] = changes, type, width) do
    [render_section_header(title, width)] ++
      Enum.map(changes, &render_file_line(&1, type, width))
  end

  defp render_changes_section(_title, _changes, _type, _width), do: []

  defp render_branches_view(state, width, height) do
    header_line = render_header("Branches", state.current_branch, width)

    branch_lines =
      case state.branches do
        branches when is_list(branches) ->
          Enum.map(branches, &render_branch_line(&1, width))

        _ ->
          []
      end

    ([header_line] ++ branch_lines)
    |> Enum.take(height)
    |> pad_to_height(height, width)
  end

  defp render_history_view(state, width, height) do
    header_line = render_header("Commit History", state.current_branch, width)

    commit_lines =
      case state.commit_history do
        commits when is_list(commits) ->
          Enum.map(commits, &render_commit_line(&1, width))

        _ ->
          []
      end

    ([header_line] ++ commit_lines)
    |> Enum.take(height)
    |> pad_to_height(height, width)
  end

  defp render_diff_view(state, width, height) do
    header = render_header("Diff View", state.current_branch, width)

    # Get the diff from git
    case run_git_command(["diff", "--color=never"], state.repo_path) do
      {diff_output, 0} ->
        diff_lines =
          diff_output
          |> String.split("\n", trim: true)
          |> Enum.map(&format_diff_line(&1, width))

        # Combine header with diff lines
        [header | diff_lines]
        |> Enum.take(height)
        |> pad_to_height(height, width)

      {error, _code} ->
        # Show error if diff fails
        error_lines = [
          header,
          "Error getting diff: #{String.trim(error)}"
        ]

        error_lines
        |> Enum.take(height)
        |> pad_to_height(height, width)
    end
  end

  defp format_diff_line(line, width) do
    styled_line = colorize_diff_line(line)

    String.slice(styled_line, 0, width - 1)
    |> String.pad_trailing(width)
  end

  defp colorize_diff_line("+++" <> _ = line), do: "\e[2m#{line}\e[0m"
  defp colorize_diff_line("+" <> _ = line), do: "\e[32m#{line}\e[0m"
  defp colorize_diff_line("---" <> _ = line), do: "\e[2m#{line}\e[0m"
  defp colorize_diff_line("-" <> _ = line), do: "\e[31m#{line}\e[0m"
  defp colorize_diff_line("@@" <> _ = line), do: "\e[36m#{line}\e[0m"
  defp colorize_diff_line("diff --git" <> _ = line), do: "\e[1m#{line}\e[0m"
  defp colorize_diff_line("index" <> _ = line), do: "\e[2m#{line}\e[0m"
  defp colorize_diff_line(line), do: line

  defp render_header(title, branch, width) do
    branch_info = if branch, do: " (#{branch})", else: ""
    header_text = "#{title}#{branch_info}"

    # Apply styling
    %{
      text: String.pad_trailing(header_text, width),
      style: TextFormatting.new() |> TextFormatting.apply_attribute(:bold)
    }
  end

  defp render_repo_info(state, width) do
    path = Path.basename(state.repo_path)
    text = "Repository: #{path}"

    %{
      text: String.pad_trailing(text, width),
      style: TextFormatting.new()
    }
  end

  defp render_section_header(title, width) do
    %{
      text: String.pad_trailing(title, width),
      style: TextFormatting.new() |> TextFormatting.apply_attribute(:underline)
    }
  end

  defp render_file_line(file_info, type, width) do
    icon =
      case type do
        :staged -> "+"
        :unstaged -> "M"
        :untracked -> "?"
      end

    color =
      case type do
        :staged -> :green
        :unstaged -> :yellow
        :untracked -> :red
      end

    text = "#{icon} #{file_info.path}"

    %{
      text: String.pad_trailing(text, width),
      style: TextFormatting.new() |> TextFormatting.set_foreground(color)
    }
  end

  defp render_branch_line(branch_info, width) do
    prefix = if branch_info.current, do: "* ", else: "  "
    suffix = if branch_info.remote, do: " (remote)", else: ""
    text = "#{prefix}#{branch_info.name}#{suffix}"

    style =
      if branch_info.current do
        TextFormatting.new()
        |> TextFormatting.apply_attribute(:bold)
        |> TextFormatting.set_foreground(:green)
      else
        TextFormatting.new()
      end

    %{
      text: String.pad_trailing(text, width),
      style: style
    }
  end

  defp render_commit_line(commit_info, width) do
    text = "#{String.slice(commit_info.hash, 0, 7)} #{commit_info.message}"

    %{
      text: String.pad_trailing(String.slice(text, 0, width), width),
      style: TextFormatting.new()
    }
  end

  defp pad_to_height(lines, height, width) do
    empty_line = %{
      text: String.pad_trailing("", width),
      style: TextFormatting.new()
    }

    current_count = length(lines)

    case current_count do
      count when count < height ->
        lines ++ List.duplicate(empty_line, height - count)

      _count ->
        lines
    end
  end

  # Keyboard Event Handlers

  def handle_keypress(key, state) do
    case {key, state.view_mode} do
      {"1", _} ->
        %{state | view_mode: :status}

      {"2", _} ->
        %{state | view_mode: :branches}

      {"3", _} ->
        %{state | view_mode: :history}

      {"4", _} ->
        %{state | view_mode: :diff}

      {"r", _} ->
        GenServer.cast(__MODULE__, :refresh)
        state

      _ ->
        state
    end
  end

  # Status Line Integration
  def status_line_info(%{repo_path: nil}), do: ""

  def status_line_info(state) do
    branch_info = format_branch_info(state.current_branch)
    changes_info = format_changes_info(state)
    "#{branch_info}#{changes_info}"
  end

  defp format_branch_info(nil), do: ""
  defp format_branch_info(branch), do: " #{branch}"

  defp format_changes_info(state) do
    staged_count = length(state.staged_changes || [])
    unstaged_count = length(state.unstaged_changes || [])
    untracked_count = length(state.untracked_files || [])

    case {staged_count, unstaged_count, untracked_count} do
      {0, 0, 0} -> " [OK]"
      {s, u, t} -> " +#{s} ~#{u} ?#{t}"
    end
  end
end
