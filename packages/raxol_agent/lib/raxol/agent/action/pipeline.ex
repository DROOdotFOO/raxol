defmodule Raxol.Agent.Action.Pipeline do
  @moduledoc """
  Composes actions into sequential pipelines.

  Each action's output is merged into a shared state map that the next
  action receives as params. The pipeline short-circuits on error.

  ## Example

      Pipeline.run(
        [ReadFile, AnalyzeCode, FormatReport],
        %{path: "lib/app.ex"},
        %{backend: mock_backend}
      )
      #=> {:ok, %{path: "lib/app.ex", content: "...", issues: [...], report: "..."}, []}
  """

  @type step :: module() | {module(), map()}
  @type pipeline :: [step()]

  @doc """
  Run a pipeline of actions sequentially.

  `initial_params` seeds the shared state. Each action's `{:ok, result}`
  is merged into the state for the next step. Commands from all steps
  are accumulated.

  Returns `{:ok, final_state, all_commands}` or `{:error, {step_module, reason}}`.
  """
  @type effect :: Raxol.Core.Runtime.Command.t() | Raxol.Agent.Directive.t()

  @spec run(pipeline(), map(), map()) ::
          {:ok, map(), [effect()]} | {:error, {module(), term()}}
  def run(steps, initial_params, context \\ %{}) do
    Enum.reduce_while(steps, {:ok, initial_params, []}, fn step, {:ok, state, cmds} ->
      {module, step_params} = normalize_step(step)
      merged_params = Map.merge(state, step_params)

      case module.call(merged_params, context) do
        {:ok, result} ->
          {:cont, {:ok, Map.merge(state, result), cmds}}

        {:ok, result, new_cmds} ->
          {:cont, {:ok, Map.merge(state, result), cmds ++ new_cmds}}

        {:error, reason} ->
          {:halt, {:error, {module, reason}}}
      end
    end)
  end

  defp normalize_step({module, params}) when is_atom(module) and is_map(params),
    do: {module, params}

  defp normalize_step(module) when is_atom(module),
    do: {module, %{}}
end
