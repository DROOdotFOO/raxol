defmodule Raxol.Agent.Actions.Vfs do
  @moduledoc """
  Virtual filesystem actions for AI agents.

  Each action exposes a VFS operation as an LLM-callable tool via the
  `Raxol.Agent.Action` behaviour. The agent maintains VFS state in its
  model and passes it through `context[:vfs]`. Mutating actions return
  the updated VFS in the result under the `:vfs` key.

  ## Usage with ToolConverter

      tools = ToolConverter.to_tool_definitions(Raxol.Agent.Actions.Vfs.actions())

      # After LLM returns a tool call:
      context = %{vfs: model.vfs}
      case ToolConverter.dispatch_tool_call(tool_call, actions(), context) do
        {:ok, result} -> Map.get(result, :vfs, model.vfs)
        {:error, reason} -> handle_tool_error(reason)  # e.g. {:vetoed, _} | {:tool_denied, _, _}
      end
  """

  @actions [
    Raxol.Agent.Actions.Vfs.ListDir,
    Raxol.Agent.Actions.Vfs.ReadFile,
    Raxol.Agent.Actions.Vfs.WriteFile,
    Raxol.Agent.Actions.Vfs.MakeDir,
    Raxol.Agent.Actions.Vfs.Remove,
    Raxol.Agent.Actions.Vfs.ChangeDir,
    Raxol.Agent.Actions.Vfs.GetTree
  ]

  @doc "Returns all VFS action modules."
  @spec actions() :: [module()]
  def actions, do: @actions

  @doc """
  Resolve VFS from params (pipeline state) or context.

  In a Pipeline, previous action results merge into params, so an updated
  VFS flows forward automatically. For direct calls, VFS comes from context.
  """
  @spec get_vfs(map(), map()) :: Raxol.Commands.FileSystem.t()
  def get_vfs(params, context) do
    Map.get(params, :vfs) || Map.get(context, :vfs, Raxol.Commands.FileSystem.new())
  end
end
