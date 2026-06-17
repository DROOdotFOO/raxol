defmodule Raxol.Agent.Actions.Skills.View do
  @moduledoc "Read a skill's `SKILL.md` body, or one supporting file within it."

  use Raxol.Agent.Action,
    name: "skill_view",
    description:
      "Read a skill's contents by name. Omit `path` to read the SKILL.md body; " <>
        "pass a relative `path` to read one supporting file inside the skill directory.",
    schema: [
      input: [
        name: [type: :string, required: true, description: "The skill's name."],
        path: [
          type: :string,
          description: "Optional relative path to a supporting file within the skill."
        ]
      ],
      output: [
        content: [type: :string]
      ]
    ]

  @impl true
  def run(params, context) do
    case Map.fetch(context, :skills) do
      {:ok, {mod, opts}} -> view(mod, opts, params)
      :error -> {:error, :skills_not_configured}
    end
  end

  defp view(mod, opts, params) do
    case mod.view(params.name, Map.get(params, :path), opts) do
      {:ok, content} -> {:ok, %{content: content}}
      {:error, reason} -> {:error, reason}
    end
  end
end
