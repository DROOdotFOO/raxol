defmodule Raxol.Core.Runtime.Plugins.PluginCommandManager do
  @moduledoc """
  Pure helpers that build a plugin command table from plugin command lists.
  """

  @doc """
  Initialize command table with initial plugins.
  """
  @spec initialize_command_table(map(), map() | list()) :: map()
  def initialize_command_table(command_table, plugins) do
    Enum.reduce(plugins, command_table, fn plugin, table ->
      case plugin do
        %{commands: commands} when is_list(commands) ->
          add_plugin_commands_to_table(commands, table)

        _ ->
          table
      end
    end)
  end

  @doc """
  Update command table with plugin commands.
  """
  @spec update_command_table(map(), map()) :: map()
  def update_command_table(table, plugin) do
    case plugin do
      %{commands: commands} when is_list(commands) ->
        Enum.reduce(commands, table, fn cmd, tbl ->
          Map.put(tbl, cmd.name, cmd)
        end)

      _ ->
        table
    end
  end

  defp add_plugin_commands_to_table(commands, table) do
    Enum.reduce(commands, table, fn cmd, tbl ->
      Map.put(tbl, cmd.name, cmd)
    end)
  end
end
