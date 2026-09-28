defmodule Raxol.Plugins.Examples.StatusLinePlugin do
  @moduledoc """
  Status Line Plugin for Raxol Terminal

  Provides a customizable status line showing system information, time, and modes.
  Demonstrates:
  - Periodic updates with GenServer
  - System information gathering
  - UI positioning and rendering
  - Configuration management
  - Resource monitoring integration
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  # Plugin Manifest
  def manifest do
    %{
      name: "status-line",
      version: "1.0.0",
      description: "Customizable status line with system information",
      author: "Raxol Team",
      dependencies: %{
        "raxol-core" => "~> 1.5"
      },
      capabilities: [
        :ui_status_line,
        :system_info,
        :periodic_updates
      ],
      config_schema: %{
        position: %{type: :string, default: "bottom", enum: ["top", "bottom"]},
        update_interval: %{type: :integer, default: 1000},
        show_time: %{type: :boolean, default: true},
        show_mode: %{type: :boolean, default: true},
        show_git: %{type: :boolean, default: true},
        show_resources: %{type: :boolean, default: true},
        theme: %{type: :string, default: "default"}
      }
    }
  end

  # Plugin State
  defstruct [
    :config,
    :emulator_pid,
    :timer_ref,
    :current_mode,
    :git_branch,
    :git_status,
    :cpu_usage,
    :memory_usage,
    :terminal_size,
    :cursor_position,
    :last_update
  ]

  # Initialization
  @impl true
  def init_manager(config) do
    Log.info("Initializing with config: #{inspect(config)}")

    state = %__MODULE__{
      config: config,
      emulator_pid: nil,
      timer_ref: nil,
      current_mode: :normal,
      git_branch: get_git_branch(),
      git_status: get_git_status(),
      cpu_usage: 0.0,
      memory_usage: 0.0,
      terminal_size: {80, 24},
      cursor_position: {0, 0},
      last_update: DateTime.utc_now()
    }

    # Start update timer
    timer_ref = start_update_timer(config_get(config, :update_interval, 1000))

    {:ok, %{state | timer_ref: timer_ref}}
  end

  # Hot-reload support
  def preserve_state(state) do
    %{
      git_branch: state.git_branch,
      git_status: state.git_status,
      current_mode: state.current_mode,
      emulator_pid: state.emulator_pid
    }
  end

  def restore_state(preserved_state, new_config) do
    state = %__MODULE__{
      config: new_config,
      emulator_pid: preserved_state.emulator_pid,
      current_mode: preserved_state.current_mode || :normal,
      git_branch: preserved_state.git_branch || get_git_branch(),
      git_status: preserved_state.git_status || get_git_status(),
      cpu_usage: 0.0,
      memory_usage: 0.0,
      terminal_size: {80, 24},
      cursor_position: {0, 0},
      last_update: DateTime.utc_now()
    }

    timer_ref =
      start_update_timer(config_get(new_config, :update_interval, 1000))

    %{state | timer_ref: timer_ref}
  end

  # Event Handlers
  def handle_event({:mode_change, mode}, state) do
    {:ok, %{state | current_mode: mode}}
  end

  def handle_event({:cursor_move, {row, col}}, state) do
    {:ok, %{state | cursor_position: {row, col}}}
  end

  def handle_event({:terminal_resize, {width, height}}, state) do
    new_state = %{state | terminal_size: {width, height}}
    render_status_line(new_state)
    {:ok, new_state}
  end

  def handle_event(_event, state) do
    {:ok, state}
  end

  # BaseManager Callbacks
  @impl true
  def handle_manager_info(:update_tick, state) do
    # Update system information
    new_state = update_system_info(state)

    # Render status line
    render_status_line(new_state)

    {:noreply, new_state}
  end

  def handle_manager_info(msg, state) do
    Log.debug("Received message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_manager_cast({:set_emulator, pid}, state) do
    {:noreply, %{state | emulator_pid: pid}}
  end

  def terminate(_reason, state) do
    # Cancel timer
    _ =
      case state.timer_ref do
        nil -> :ok
        ref -> Process.cancel_timer(ref)
      end

    :ok
  end

  # Private Functions
  defp start_update_timer(interval) do
    Process.send_after(self(), :update_tick, interval)
  end

  defp update_system_info(state) do
    # Update git information (less frequently)
    {git_branch, git_status} =
      case DateTime.diff(DateTime.utc_now(), state.last_update) do
        diff when diff >= 5 ->
          {get_git_branch(), get_git_status()}

        _ ->
          {state.git_branch, state.git_status}
      end

    # Update resource usage
    cpu = get_cpu_usage()
    memory = get_memory_usage()

    # Schedule next update
    timer_ref =
      start_update_timer(config_get(state.config, :update_interval, 1000))

    %{
      state
      | git_branch: git_branch,
        git_status: git_status,
        cpu_usage: cpu,
        memory_usage: memory,
        timer_ref: timer_ref,
        last_update: DateTime.utc_now()
    }
  end

  defp render_status_line(state) do
    # Build status line components
    components = build_status_components(state)

    # Format based on terminal width
    {width, _height} = state.terminal_size
    formatted_line = format_status_line(components, width, state.config)

    # Send to emulator
    send_status_line(
      state.emulator_pid,
      formatted_line,
      config_get(state.config, :position, "bottom")
    )
  end

  defp build_status_components(state) do
    {row, col} = state.cursor_position
    {width, height} = state.terminal_size

    []
    |> maybe_add_mode(state)
    |> maybe_add_git(state)
    |> maybe_add_resources(state)
    |> then(&[{:cursor, "#{row + 1}:#{col + 1}"} | &1])
    |> then(&[{:size, "#{width}x#{height}"} | &1])
    |> maybe_add_time(state)
    |> Enum.reverse()
  end

  defp maybe_add_mode(components, %{config: %{show_mode: false}}),
    do: components

  defp maybe_add_mode(components, state),
    do: [{:mode, format_mode(state.current_mode)} | components]

  defp maybe_add_git(components, %{config: %{show_git: false}}), do: components
  defp maybe_add_git(components, %{git_branch: nil}), do: components

  defp maybe_add_git(components, state),
    do: [{:git, format_git(state.git_branch, state.git_status)} | components]

  defp maybe_add_resources(components, %{config: %{show_resources: false}}),
    do: components

  defp maybe_add_resources(components, state) do
    [
      {:cpu, format_cpu(state.cpu_usage)},
      {:memory, format_memory(state.memory_usage)} | components
    ]
  end

  defp maybe_add_time(components, %{config: %{show_time: false}}),
    do: components

  defp maybe_add_time(components, _state),
    do: [{:time, format_time()} | components]

  defp format_status_line(components, width, config) do
    theme = get_theme(config[:theme] || "default")

    {left, center, right} = partition_and_format(components, theme)

    justify_sections(left, center, right, width)
  end

  defp partition_and_format(components, theme) do
    left =
      components
      |> Enum.filter(fn {type, _} -> type in [:mode, :git] end)
      |> format_section(theme, :left)

    center =
      components
      |> Enum.filter(fn {type, _} -> type in [:cursor, :size] end)
      |> format_section(theme, :center)

    right =
      components
      |> Enum.filter(fn {type, _} -> type in [:cpu, :memory, :time] end)
      |> format_section(theme, :right)

    {left, center, right}
  end

  defp justify_sections(left, center, right, width) do
    left_len = String.length(strip_ansi(left))
    center_len = String.length(strip_ansi(center))
    right_len = String.length(strip_ansi(right))

    available = width - left_len - right_len
    center_padding = div(available - center_len, 2)

    left <>
      String.duplicate(" ", max(0, center_padding)) <>
      center <>
      String.duplicate(" ", max(0, available - center_padding - center_len)) <>
      right
  end

  defp format_section(components, theme, _position) do
    Enum.map_join(components, theme.separator, fn {type, text} ->
      apply_style(text, theme[type] || %{})
    end)
  end

  # Component Formatters
  defp format_mode(:normal), do: "NORMAL"
  defp format_mode(:insert), do: "INSERT"
  defp format_mode(:visual), do: "VISUAL"
  defp format_mode(:command), do: "COMMAND"
  defp format_mode(mode), do: mode |> to_string() |> String.upcase()

  defp format_git(branch, {added, modified, deleted}) do
    status = []
    status = if added > 0, do: ["+#{added}" | status], else: status
    status = if modified > 0, do: ["~#{modified}" | status], else: status
    status = if deleted > 0, do: ["-#{deleted}" | status], else: status

    case status do
      [] -> " #{branch}"
      _ -> " #{branch} [#{Enum.join(status, " ")}]"
    end
  end

  defp format_git(branch, _), do: " #{branch}"

  defp format_cpu(usage) do
    "CPU: #{:erlang.float_to_binary(usage, decimals: 1)}%"
  end

  defp format_memory(usage) do
    "MEM: #{:erlang.float_to_binary(usage, decimals: 1)}%"
  end

  defp format_time do
    DateTime.utc_now()
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..4)
  end

  # System Information Gathering
  defp get_git_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  end

  defp get_git_status do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)
        added = Enum.count(lines, &String.starts_with?(&1, "A "))
        modified = Enum.count(lines, &String.starts_with?(&1, "M "))
        deleted = Enum.count(lines, &String.starts_with?(&1, "D "))
        {added, modified, deleted}

      _ ->
        {0, 0, 0}
    end
  end

  defp get_cpu_usage do
    # Simplified CPU usage (would use :cpu_sup in production)
    :rand.uniform() * 30.0
  end

  defp get_memory_usage do
    # Get actual memory usage
    memory_data = :erlang.memory()
    total = Keyword.get(memory_data, :total, 0)
    system = Keyword.get(memory_data, :system, 0)

    case system do
      0 -> 0.0
      _ -> (total / system * 100.0) |> min(100.0)
    end
  end

  # Theming
  defp get_theme("default") do
    %{
      mode: %{fg: :cyan, bold: true},
      git: %{fg: :green},
      cursor: %{fg: :yellow},
      size: %{fg: :blue},
      cpu: %{fg: :magenta},
      memory: %{fg: :magenta},
      time: %{fg: :white},
      separator: " │ ",
      bg: :black
    }
  end

  defp get_theme("minimal") do
    %{
      mode: %{fg: :white},
      git: %{fg: :white},
      cursor: %{fg: :white},
      size: %{fg: :white},
      cpu: %{fg: :white},
      memory: %{fg: :white},
      time: %{fg: :white},
      separator: " ",
      bg: :default
    }
  end

  defp get_theme(_), do: get_theme("default")

  defp config_get(config, key, default) when is_map(config),
    do: Map.get(config, key, default)

  defp config_get(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  # Helpers
  defp apply_style(text, style) do
    # Apply ANSI styling based on style map
    codes = []
    codes = if style[:bold], do: ["1" | codes], else: codes
    codes = if style[:fg], do: [fg_code(style[:fg]) | codes], else: codes
    codes = if style[:bg], do: [bg_code(style[:bg]) | codes], else: codes

    case codes do
      [] -> text
      _ -> "\e[#{Enum.join(codes, ";")}m#{text}\e[0m"
    end
  end

  defp fg_code(:black), do: "30"
  defp fg_code(:red), do: "31"
  defp fg_code(:green), do: "32"
  defp fg_code(:yellow), do: "33"
  defp fg_code(:blue), do: "34"
  defp fg_code(:magenta), do: "35"
  defp fg_code(:cyan), do: "36"
  defp fg_code(:white), do: "37"
  defp fg_code(_), do: "39"

  defp bg_code(:black), do: "40"
  defp bg_code(:red), do: "41"
  defp bg_code(:green), do: "42"
  defp bg_code(:yellow), do: "43"
  defp bg_code(:blue), do: "44"
  defp bg_code(:magenta), do: "45"
  defp bg_code(:cyan), do: "46"
  defp bg_code(:white), do: "47"
  defp bg_code(_), do: "49"

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*m/, text, "")
  end

  defp send_status_line(nil, _content, _position), do: :ok

  defp send_status_line(pid, content, position) do
    send(pid, {:render_status_line, content, position})
  end
end
