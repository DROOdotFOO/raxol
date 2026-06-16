defmodule Raxol.Terminal.Config.Application do
  @moduledoc """
  Terminal configuration application.

  This module handles applying configuration settings to the terminal,
  ensuring all changes are properly propagated throughout the system.
  """

  alias Raxol.Terminal.Config.{Capabilities, Validation}

  @doc """
  Applies a configuration to the terminal.

  This function takes a configuration and applies it to the current terminal
  instance, updating the terminal state and behavior.

  ## Parameters

  * `config` - The configuration to apply
  * `terminal_pid` - The PID of the terminal process (optional)

  ## Returns

  `{:ok, applied_config}` or `{:error, reason}`
  """
  def apply_config(config, terminal_pid \\ nil) do
    # Validate the configuration
    case Validation.validate_config(config) do
      {:ok, validated_config} ->
        # Apply the configuration using private functions for each section
        with :ok <- apply_display_config(validated_config, terminal_pid),
             :ok <- apply_input_config(validated_config, terminal_pid),
             :ok <- apply_rendering_config(validated_config, terminal_pid),
             :ok <- apply_ansi_config(validated_config, terminal_pid),
             :ok <- apply_behavior_config(validated_config, terminal_pid) do
          {:ok, validated_config}
        else
          {:error, reason} -> {:error, reason}
        end

      error ->
        error
    end
  end

  @doc """
  Applies a partial configuration update to the terminal.

  This allows updating only specific parts of the configuration without
  changing other settings.

  ## Parameters

  * `partial_config` - The partial configuration to apply
  * `terminal_pid` - The PID of the terminal process (optional)

  ## Returns

  `{:ok, updated_config}` or `{:error, reason}`
  """
  def apply_partial_config(partial_config, terminal_pid \\ nil) do
    # Get the current configuration
    current_config = get_current_config(terminal_pid)

    # Merge the partial config with the current config
    updated_config = deep_merge(current_config, partial_config)

    # Apply the updated configuration
    apply_config(updated_config, terminal_pid)
  end

  @doc """
  Gets the current terminal configuration.

  ## Parameters

  * `terminal_pid` - The PID of the terminal process (optional)

  ## Returns

  The current terminal configuration.
  """
  def get_current_config(terminal_pid \\ nil) do
    # If terminal_pid is provided, get config from that process
    # Otherwise, use the default terminal process
    pid = terminal_pid || default_terminal_pid()

    case pid do
      # No terminal active
      nil ->
        %{}

      pid when is_pid(pid) ->
        # Try to get configuration from the terminal process
        case get_config_from_terminal(pid) do
          {:ok, config_map} ->
            # Extract only the necessary parts
            config_map
            |> Map.take([:font_size, :font_family, :theme])
        end
    end
  end

  @doc """
  Resets terminal configuration to default values.

  ## Parameters

  * `terminal_pid` - The PID of the terminal process (optional)
  * `optimize` - Whether to optimize for detected capabilities (default: true)

  ## Returns

  `{:ok, default_config}` or `{:error, reason}`
  """
  def reset_config(terminal_pid \\ nil, optimize \\ true) do
    # Get default configuration
    default_config = get_default_config(optimize)

    # Apply the default configuration
    apply_config(default_config, terminal_pid)
  end

  # Private functions

  defp get_default_config(true) do
    # Use capability-aware optimized default config
    Capabilities.optimized_config()
  end

  defp get_default_config(false) do
    # Use basic default config
    Raxol.Terminal.Config.Defaults.generate_default_config()
  end

  # Apply display configuration
  defp apply_display_config(%{display: display}, terminal_pid)
       when is_map(display) or is_tuple(display) do
    pid = terminal_pid || default_terminal_pid()

    apply_display_config_to_pid(pid, display)
  end

  # No display config to apply
  defp apply_display_config(_, _), do: :ok

  defp apply_display_config_to_pid(nil, _display) do
    # No terminal active
    :ok
  end

  defp apply_display_config_to_pid(pid, display) do
    # Extract relevant display settings
    settings = %{
      width: extract_width(display),
      height: extract_height(display),
      title: Map.get(display, :title),
      colors: Map.get(display, :colors),
      truecolor: Map.get(display, :truecolor),
      unicode: Map.get(display, :unicode)
    }

    # Send configuration to terminal process
    send_config_to_terminal(pid, {:display_config, settings})
  end

  defp extract_width(display) when is_map(display), do: Map.get(display, :width)
  defp extract_width(display) when is_tuple(display), do: elem(display, 0)

  defp extract_height(display) when is_map(display),
    do: Map.get(display, :height)

  defp extract_height(display) when is_tuple(display), do: elem(display, 1)

  # Apply input configuration
  defp apply_input_config(%{input: input}, terminal_pid) when is_map(input) do
    pid = terminal_pid || default_terminal_pid()
    apply_input_config_to_pid(pid, input)
  end

  # No input config to apply
  defp apply_input_config(_, _), do: :ok

  defp apply_input_config_to_pid(nil, _input) do
    # No terminal active
    :ok
  end

  defp apply_input_config_to_pid(pid, input) do
    # Extract relevant input settings
    settings = %{
      mouse: Map.get(input, :mouse),
      keyboard: Map.get(input, :keyboard),
      escape_timeout: Map.get(input, :escape_timeout),
      clipboard: Map.get(input, :clipboard)
    }

    # Send configuration to terminal process
    send_config_to_terminal(pid, {:input_config, settings})
  end

  # Apply rendering configuration
  defp apply_rendering_config(%{rendering: rendering}, terminal_pid)
       when is_map(rendering) do
    pid = terminal_pid || default_terminal_pid()
    apply_rendering_config_to_pid(pid, rendering)
  end

  # No rendering config to apply
  defp apply_rendering_config(_, _), do: :ok

  defp apply_rendering_config_to_pid(nil, _rendering) do
    # No terminal active
    :ok
  end

  defp apply_rendering_config_to_pid(pid, rendering) do
    # Extract relevant rendering settings
    settings = %{
      fps: Map.get(rendering, :fps),
      double_buffer: Map.get(rendering, :double_buffer),
      redraw_mode: Map.get(rendering, :redraw_mode)
    }

    # Send configuration to terminal process
    send_config_to_terminal(pid, {:rendering_config, settings})
  end

  # Apply ANSI configuration
  defp apply_ansi_config(%{ansi: ansi}, terminal_pid) when is_map(ansi) do
    pid = terminal_pid || default_terminal_pid()
    apply_ansi_config_to_pid(pid, ansi)
  end

  # No ANSI config to apply
  defp apply_ansi_config(_, _), do: :ok

  defp apply_ansi_config_to_pid(nil, _ansi) do
    # No terminal active
    :ok
  end

  defp apply_ansi_config_to_pid(pid, ansi) do
    # Extract relevant ANSI settings
    settings = %{
      enabled: Map.get(ansi, :enabled),
      color_mode: Map.get(ansi, :color_mode),
      colors: Map.get(ansi, :colors, %{})
    }

    # Send configuration to terminal process
    send_config_to_terminal(pid, {:ansi_config, settings})
  end

  # Apply behavior configuration
  defp apply_behavior_config(%{behavior: behavior}, terminal_pid)
       when is_map(behavior) do
    pid = terminal_pid || default_terminal_pid()
    apply_behavior_config_to_pid(pid, behavior)
  end

  # No behavior config to apply
  defp apply_behavior_config(_, _), do: :ok

  defp apply_behavior_config_to_pid(nil, _behavior) do
    # No terminal active
    :ok
  end

  defp apply_behavior_config_to_pid(pid, behavior) do
    # Extract relevant behavior settings
    settings = %{
      scrollback_lines: Map.get(behavior, :scrollback_lines),
      auto_wrap: Map.get(behavior, :auto_wrap),
      bell_style: Map.get(behavior, :bell_style)
    }

    # Send configuration to terminal process
    send_config_to_terminal(pid, {:behavior_config, settings})
  end

  # Get the default terminal process PID
  defp default_terminal_pid do
    # This would actually look up the terminal process
    # Returns nil as a placeholder
    nil
  end

  # Send configuration to terminal process
  defp send_config_to_terminal(pid, message) do
    # Send message to terminal process
    # This is a placeholder implementation
    # In a real implementation, this would use the appropriate
    # message passing mechanism and handle responses
    _ = Process.send(pid, message, [:noconnect])
    :ok
  end

  # Get configuration from terminal process
  defp get_config_from_terminal(_pid) do
    # Placeholder implementation
    {:ok, %{}}
  end

  # Deep merge two maps
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right)
  end
end
