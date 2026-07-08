defmodule Raxol.Core.Runtime.Plugins.PluginInitializer do
  @moduledoc """
  Handles initialization of plugins, including state setup and command registration.
  """

  alias Raxol.Core.Runtime.Plugins.PluginCommandManager

  @doc """
  Initializes all plugins in the given load order.
  """
  @spec initialize_plugins(
          map() | list(),
          map(),
          map() | nil,
          map(),
          list(),
          map() | atom() | reference(),
          keyword() | map() | nil
        ) ::
          {:ok, {map(), map(), map()}} | {:error, term()}
  def initialize_plugins(
        plugins,
        metadata,
        config,
        states,
        load_order,
        command_table,
        _opts
      ) do
    table =
      PluginCommandManager.initialize_command_table(command_table, plugins)

    Enum.reduce_while(
      load_order,
      {:ok, {metadata, states, table}},
      fn plugin_id, acc ->
        initialize_plugin(plugin_id, acc, plugins, config || %{})
      end
    )
  end

  @doc """
  Initializes a single plugin.
  """
  @spec initialize_plugin(
          atom() | String.t(),
          {:ok, {map(), map(), map()}},
          map(),
          map()
        ) ::
          {:cont, {:ok, {map(), map(), map()}}}
          | {:halt, {:error, term()}}
  def initialize_plugin(
        plugin_id,
        {:ok, {meta, sts, tbl}},
        plugins,
        plugin_config
      ) do
    case Map.get(plugins, plugin_id) do
      nil ->
        {:cont, {:ok, {meta, sts, tbl}}}

      plugin ->
        handle_plugin_init(plugin, plugin_id, meta, sts, tbl, plugin_config)
    end
  end

  @doc """
  Handles the initialization of a specific plugin.
  """
  def handle_plugin_init(plugin, plugin_id, meta, sts, tbl, plugin_config) do
    case plugin.init(Map.get(plugin_config, plugin_id, %{})) do
      {:ok, new_states} ->
        new_meta = Map.put(meta, plugin_id, %{status: :active})
        plugin_map = if is_map(plugin), do: plugin, else: %{commands: []}
        new_tbl = PluginCommandManager.update_command_table(tbl, plugin_map)
        {:cont, {:ok, {new_meta, Map.merge(sts, new_states), new_tbl}}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "Failed to initialize plugin",
          reason,
          nil,
          %{module: __MODULE__, plugin_id: plugin_id, reason: reason}
        )

        {:halt, {:error, reason}}
    end
  end
end
