defmodule Raxol.Agent.Actions.Skills.List do
  @moduledoc "List available skills (metadata only -- the cheap progressive-disclosure level)."

  use Raxol.Agent.Action,
    name: "skills_list",
    description:
      "List available skills as metadata only (name, category, description, state). " <>
        "This is the cheap level; call skill_view with a name to read a skill's contents.",
    schema: [
      input: [],
      output: [
        skills: [type: :list]
      ]
    ]

  @impl true
  def run(_params, context) do
    case Map.fetch(context, :skills) do
      {:ok, {mod, opts}} -> {:ok, %{skills: mod.list(opts)}}
      :error -> {:error, :skills_not_configured}
    end
  end
end
