defmodule Raxol.Terminal.Config.Manager do
  @moduledoc """
  Manages terminal configuration including settings, preferences, and environment variables.
  This module is responsible for handling configuration operations and state.
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Terminal.{Config, Emulator}

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()

  # Client API
  # BaseManager provides start_link/1 automatically with name: __MODULE__ as default

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    {:ok, new(width, height)}
  end

  @impl true
  def handle_manager_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_manager_call({:update_config, new_config}, _from, _state) do
    {:reply, :ok, new_config}
  end

  # Private functions

  @doc """
  Creates a new config manager.
  """
  @spec new() :: Config.t()
  def new do
    %Config{
      version: 1,
      width: @default_width,
      height: @default_height,
      colors: %{},
      styles: %{},
      input: %{},
      performance: %{},
      mode: %{}
    }
  end

  @spec new(non_neg_integer(), non_neg_integer()) :: Config.t()
  defp new(width, height) do
    %Config{
      version: 1,
      width: width,
      height: height,
      colors: %{},
      styles: %{},
      input: %{},
      performance: %{},
      mode: %{}
    }
  end

  @doc """
  Gets a configuration setting.
  Returns the setting value or nil.
  """
  @spec get_setting(Emulator.t(), atom()) :: any()
  def get_setting(emulator, setting) when is_atom(setting) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)

    case setting do
      :width -> config.width
      :height -> config.height
      :colors -> config.colors
      :styles -> config.styles
      :input -> config.input
      :performance -> config.performance
      :mode -> config.mode
      _ -> Map.get(config.mode, setting)
    end
  end

  @doc """
  Sets a configuration setting.
  Returns the updated emulator.
  """
  @spec set_setting(Emulator.t(), atom(), any()) :: Emulator.t()
  def set_setting(emulator, setting, value) when is_atom(setting) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    updated_config = update_config_setting(config, setting, value)

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, updated_config)
  end

  defp update_config_setting(config, :width, value)
       when is_integer(value) and value > 0 do
    %{config | width: value}
  end

  defp update_config_setting(config, :height, value)
       when is_integer(value) and value > 0 do
    %{config | height: value}
  end

  defp update_config_setting(config, :colors, value) when is_map(value) do
    %{config | colors: Map.merge(config.colors, value)}
  end

  defp update_config_setting(config, :styles, value) when is_map(value) do
    %{config | styles: Map.merge(config.styles, value)}
  end

  defp update_config_setting(config, :input, value) when is_map(value) do
    %{config | input: Map.merge(config.input, value)}
  end

  defp update_config_setting(config, :performance, value) when is_map(value) do
    %{config | performance: Map.merge(config.performance, value)}
  end

  defp update_config_setting(config, :mode, value) when is_map(value) do
    %{config | mode: Map.merge(config.mode, value)}
  end

  defp update_config_setting(config, setting, value) when is_atom(setting) do
    # Store custom settings in the mode field
    mode = Map.put(config.mode, setting, value)
    %{config | mode: mode}
  end

  defp update_emulator_config(true, emulator, updated_config) do
    GenServer.call(emulator.config, {:update_config, updated_config})
    emulator
  end

  defp update_emulator_config(false, emulator, updated_config) do
    %{emulator | config: updated_config}
  end

  @doc """
  Gets a preference value.
  Returns the preference value or nil.
  """
  @spec get_preference(Emulator.t(), atom()) :: any()
  def get_preference(emulator, preference) when is_atom(preference) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    get_in(config.mode, [preference])
  end

  @doc """
  Sets a preference value.
  Returns the updated emulator.
  """
  @spec set_preference(Emulator.t(), atom(), any()) :: Emulator.t()
  def set_preference(emulator, preference, value) when is_atom(preference) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    mode = Map.put(config.mode, preference, value)
    updated_config = %{config | mode: mode}

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, updated_config)
  end

  @doc """
  Gets an environment variable.
  Returns the environment variable value or nil.
  """
  @spec get_environment(Emulator.t(), String.t()) :: String.t() | nil
  def get_environment(emulator, key) when is_binary(key) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    get_in(config.input, [key])
  end

  @doc """
  Sets an environment variable.
  Returns the updated emulator.
  """
  @spec set_environment(Emulator.t(), String.t(), String.t()) :: Emulator.t()
  def set_environment(emulator, key, value)
      when is_binary(key) and is_binary(value) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    input = Map.put(config.input, key, value)
    updated_config = %{config | input: input}

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, updated_config)
  end

  @doc """
  Gets all environment variables.
  Returns the map of environment variables.
  """
  @spec get_all_environment(Emulator.t()) :: %{String.t() => String.t()}
  def get_all_environment(emulator) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    config.input
  end

  @doc """
  Sets multiple environment variables.
  Returns the updated emulator.
  """
  @spec set_environment_variables(Emulator.t(), %{String.t() => String.t()}) ::
          Emulator.t()
  def set_environment_variables(emulator, variables) when is_map(variables) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    input = Map.merge(config.input, variables)
    updated_config = %{config | input: input}

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, updated_config)
  end

  @doc """
  Clears all environment variables.
  Returns the updated emulator.
  """
  @spec clear_environment(Emulator.t()) :: Emulator.t()
  def clear_environment(emulator) do
    config = Raxol.Terminal.Emulator.get_config_struct(emulator)
    updated_config = %{config | input: %{}}

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, updated_config)
  end

  @doc """
  Resets the config manager to its initial state.
  Returns the updated emulator.
  """
  @spec reset_config_manager(Emulator.t()) :: Emulator.t()
  def reset_config_manager(emulator) do
    new_config = new()

    # Update the config through the GenServer if it's a PID
    update_emulator_config(is_pid(emulator.config), emulator, new_config)
  end
end
