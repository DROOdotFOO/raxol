defmodule Raxol.Agent.Actions.Skills.Manage do
  @moduledoc """
  Create, patch, or delete a managed skill.

  Foreground `skill_manage` calls are user-directed, so skills created here are
  tagged `created_by: :user`. The background curation reviewer authors skills by
  calling `Raxol.Agent.Skills.Store.create/2` directly with `created_by: :agent`;
  the Curator only ages and rewrites `:agent` artifacts, never these.
  """

  use Raxol.Agent.Action,
    name: "skill_manage",
    description:
      "Create, patch, or delete a skill (procedural memory). " <>
        "action create: write a new skill; patch/edit: update an existing one; delete: remove it.",
    schema: [
      input: [
        action: [
          type: :string,
          required: true,
          enum: ["create", "patch", "edit", "delete"],
          description: "What to do."
        ],
        name: [type: :string, required: true, description: "The skill's name."],
        description: [type: :string, description: "One-line summary of the skill."],
        category: [type: :string, description: "Optional category (also the on-disk subdir)."],
        version: [type: :string, description: "Optional version string."],
        body: [type: :string, description: "The skill's markdown body (the procedure)."],
        metadata: [type: :map, description: "Optional extra frontmatter."]
      ],
      output: [
        ok: [type: :boolean],
        name: [type: :string]
      ]
    ]

  @impl true
  def run(params, context) do
    case Map.fetch(context, :skills) do
      {:ok, {mod, opts}} -> dispatch(mod, opts, params)
      :error -> {:error, :skills_not_configured}
    end
  end

  defp dispatch(mod, opts, %{action: "create", name: name} = params) do
    attrs = params |> change_attrs() |> Map.merge(%{name: name, created_by: :user})

    case mod.create(attrs, opts) do
      {:ok, _skill} -> {:ok, %{ok: true, name: name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(mod, opts, %{action: action, name: name} = params)
       when action in ["patch", "edit"] do
    case mod.patch(name, change_attrs(params), opts) do
      {:ok, _skill} -> {:ok, %{ok: true, name: name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(mod, opts, %{action: "delete", name: name}) do
    case mod.delete(name, opts) do
      :ok -> {:ok, %{ok: true, name: name}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only the frontmatter/body fields the caller actually supplied, so a patch
  # leaves untouched fields alone.
  defp change_attrs(params) do
    params
    |> Map.take([:description, :category, :version, :body, :metadata])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
