defmodule Raxol.Terminal.Config.Capabilities do
  @moduledoc """
  Terminal capability detection and management.

  Provides functionality to detect and determine terminal capabilities
  such as color support, unicode support, etc.
  """

  alias Raxol.System.EnvironmentAdapterImpl
  alias Raxol.Terminal.Config.Defaults
  alias Raxol.Terminal.Config.Schema

  @doc """
  Detects terminal capabilities based on the environment using a specific adapter.

  This examines environment variables, terminal responses, and other indicators
  to determine capabilities of the current terminal.

  ## Parameters
  * `adapter_module` - The module implementing `EnvironmentAdapterBehaviour`.

  ## Returns

  A map of detected capabilities.
  """
  def detect_capabilities(adapter_module) do
    %{
      display: detect_display_capabilities(adapter_module),
      input: detect_input_capabilities(adapter_module),
      ansi: detect_ansi_capabilities(adapter_module)
    }
  end

  @doc """
  Merges detected capabilities with configuration using a specific adapter.

  Takes a terminal configuration and enhances it with detected capabilities
  where those capabilities aren't already explicitly configured.

  ## Parameters
  * `config` - The existing configuration
  * `adapter_module` - The module implementing `EnvironmentAdapterBehaviour`.

  ## Returns

  The configuration enhanced with detected capabilities.
  """
  def apply_capabilities(config, adapter_module) do
    capabilities = detect_capabilities(adapter_module)

    # Merge capabilities into config, only overriding if not explicitly set
    deep_merge_capabilities(config, capabilities)
  end

  @doc """
  Creates an optimized configuration based on detected capabilities using the default adapter.

  This generates a configuration that's optimized for the current terminal
  environment, balancing features and performance.

  ## Returns

  An optimized configuration for the current terminal.
  """
  def optimized_config do
    optimized_config(EnvironmentAdapterImpl)
  end

  @doc """
  Creates an optimized configuration based on detected capabilities using a specific adapter.

  ## Parameters
  * `adapter_module` - The module implementing `EnvironmentAdapterBehaviour`.

  ## Returns

  An optimized configuration for the current terminal.
  """
  def optimized_config(adapter_module) do
    # Start with defaults
    defaults = Defaults.generate_default_config()

    # Enhance with detected capabilities
    capabilities = detect_capabilities(adapter_module)
    config = deep_merge_capabilities(defaults, capabilities)

    # Flatten nested keys to top-level
    flat_config = flatten_config(config)

    # Apply optimizations based on capabilities
    optimized_config = optimize_config_for_capabilities(flat_config)

    # Filter to only include schema-valid keys
    filter_config_by_schema(optimized_config)
  end

  # Flattens nested :display, :input, :ansi, :rendering keys to top-level
  defp flatten_config(config) do
    config
    |> Map.merge(Map.get(config, :display, %{}))
    |> Map.merge(Map.get(config, :input, %{}))
    |> Map.merge(Map.get(config, :ansi, %{}))
    |> Map.merge(Map.get(config, :rendering, %{}))
    |> Map.drop([:display, :input, :ansi, :rendering])
  end

  # Filters config to only include keys present in the schema
  defp filter_config_by_schema(config) do
    schema_keys = Schema.schema() |> Map.keys()
    Map.take(config, schema_keys)
  end

  # Private functions

  defp detect_display_capabilities(adapter_module) do
    %{
      width: detect_width(adapter_module),
      height: detect_height(adapter_module),
      colors: detect_color_support(adapter_module),
      truecolor: detect_truecolor_support(adapter_module),
      unicode: detect_unicode_support(adapter_module)
    }
  end

  defp detect_input_capabilities(adapter_module) do
    %{
      mouse: detect_mouse_support(adapter_module),
      # All terminals support basic keyboard
      keyboard: true,
      clipboard: detect_clipboard_support(adapter_module)
    }
  end

  defp detect_ansi_capabilities(adapter_module) do
    %{
      enabled: detect_ansi_support(adapter_module),
      color_mode: detect_color_mode(adapter_module)
    }
  end

  defp detect_width(adapter_module) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           detect_width_value(adapter_module)
         end) do
      {:ok, width} -> width
      # Default fallback on any error
      {:error, _reason} -> 80
    end
  end

  defp detect_height(adapter_module) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           detect_height_value(adapter_module)
         end) do
      {:ok, height} -> height
      # Default fallback on any error
      {:error, _reason} -> 24
    end
  end

  defp detect_color_support(adapter_module) do
    # Check environment variables first
    case adapter_module.get_env("COLORTERM") do
      # 24-bit color
      "truecolor" ->
        16_777_216

      # 24-bit color
      "24bit" ->
        16_777_216

      _ ->
        # Get the TERM environment variable
        term = adapter_module.get_env("TERM")
        detect_colors_from_term(term, adapter_module)
    end
  end

  defp detect_colors_from_term("xterm-256color", _adapter_module), do: 256

  defp detect_colors_from_term(term, adapter_module) when is_binary(term) do
    case {String.contains?(term, "256"), String.contains?(term, "color")} do
      {true, _} -> 256
      {_, true} -> 16
      _ -> fallback_tput_colors(adapter_module)
    end
  end

  defp detect_colors_from_term(_, adapter_module),
    do: fallback_tput_colors(adapter_module)

  defp fallback_tput_colors(adapter_module) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           detect_colors_from_tput(adapter_module)
         end) do
      {:ok, colors} -> colors
      # Default fallback on any error
      {:error, _reason} -> 8
    end
  end

  defp detect_truecolor_support(adapter_module) do
    case adapter_module.get_env("COLORTERM") do
      "truecolor" -> true
      "24bit" -> true
      _ -> false
    end
  end

  defp detect_unicode_support(adapter_module) do
    # Get the LANG environment variable
    lang = adapter_module.get_env("LANG")
    check_utf8_support(lang)
  end

  defp check_utf8_support(lang) when is_binary(lang) do
    String.contains?(lang, "UTF-8") || String.contains?(lang, "utf8")
  end

  defp check_utf8_support(_lang), do: false

  defp detect_mouse_support(adapter_module) do
    # Simple heuristic - most modern terminal emulators support mouse
    # Get the TERM environment variable
    term = adapter_module.get_env("TERM")
    check_mouse_capable_terminal(term)
  end

  defp check_mouse_capable_terminal(term) when is_binary(term) do
    String.contains?(term, "xterm") ||
      String.contains?(term, "screen") ||
      String.contains?(term, "tmux")
  end

  defp check_mouse_capable_terminal(_term), do: false

  defp detect_clipboard_support(adapter_module) do
    # Check if in GUI environment
    case adapter_module.get_env("DISPLAY") do
      nil -> false
      _ -> true
    end
  end

  defp detect_ansi_support(adapter_module) do
    case adapter_module.get_env("TERM") do
      "dumb" -> false
      nil -> false
      _ -> true
    end
  end

  defp detect_color_mode(adapter_module) do
    colors = detect_color_support(adapter_module)
    classify_color_mode(colors)
  end

  defp classify_color_mode(colors) when colors >= 16_777_216, do: :truecolor
  defp classify_color_mode(colors) when colors >= 256, do: :extended
  defp classify_color_mode(colors) when colors >= 16, do: :basic
  defp classify_color_mode(colors) when colors >= 8, do: :basic
  defp classify_color_mode(_colors), do: :none

  # Recursively merge capabilities into configuration
  defp deep_merge_capabilities(config, capabilities)
       when is_map(config) and is_map(capabilities) do
    Map.merge(config, capabilities, fn
      # If both values are maps, merge them recursively
      _, config_value, capability_value
      when is_map(config_value) and is_map(capability_value) ->
        deep_merge_capabilities(config_value, capability_value)

      # For any other case, keep the config value (don't override explicit configuration)
      _, config_value, _capability_value ->
        config_value
    end)
  end

  defp deep_merge_capabilities(config, _), do: config

  # Apply optimizations based on detected capabilities
  defp optimize_config_for_capabilities(config) do
    # Adjust rendering settings based on capabilities
    rendering = Map.get(config, :rendering, %{})

    updated_rendering =
      case Map.get(config, :display, %{}) do
        %{colors: colors} when colors <= 16 ->
          # For terminals with limited colors, reduce other graphics settings
          rendering
          |> Map.put(:fps, 30)
          |> Map.put(:optimize_empty_cells, true)
          |> Map.put(:smooth_resize, false)

        %{width: width, height: height} when width < 80 or height < 24 ->
          # For small terminals, reduce rendering overhead
          rendering
          |> Map.put(:fps, 30)
          |> Map.put(:optimize_empty_cells, true)

        _ ->
          # Keep existing settings for capable terminals
          rendering
      end

    Map.put(config, :rendering, updated_rendering)
  end

  defp detect_width_value(adapter_module) do
    case adapter_module.get_env("COLUMNS") do
      nil ->
        # Try to get from tput if available
        get_width_from_tput(adapter_module)

      cols ->
        String.to_integer(cols)
    end
  end

  defp detect_height_value(adapter_module) do
    case adapter_module.get_env("LINES") do
      nil ->
        # Try to get from tput if available
        get_height_from_tput(adapter_module)

      lines ->
        String.to_integer(lines)
    end
  end

  defp detect_colors_from_tput(adapter_module) do
    case adapter_module.cmd("tput", ["colors"], stderr_to_stdout: true) do
      {colors, 0} ->
        parse_tput_color_value(colors)

      # Default fallback
      _ ->
        8
    end
  end

  defp get_width_from_tput(adapter_module) do
    case adapter_module.cmd("tput", ["cols"], stderr_to_stdout: true) do
      {cols, 0} -> String.to_integer(String.trim(cols))
      # Default fallback
      _ -> 80
    end
  end

  defp get_height_from_tput(adapter_module) do
    case adapter_module.cmd("tput", ["lines"], stderr_to_stdout: true) do
      {lines, 0} -> String.to_integer(String.trim(lines))
      # Default fallback
      _ -> 24
    end
  end

  defp parse_tput_color_value(colors) do
    case String.trim(colors) do
      "-1" -> 0
      num -> String.to_integer(num)
    end
  end
end
