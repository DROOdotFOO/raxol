defmodule Raxol.Agent.Code.AppSkillsTest do
  # async: false -- these mutate the :raxol_agent app env.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Skills, as: SkillsActions
  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Skills.Store

  setup do
    prev = Application.get_env(:raxol_agent, :skills_provider)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:raxol_agent, :skills_provider)
        val -> Application.put_env(:raxol_agent, :skills_provider, val)
      end
    end)

    :ok
  end

  # A model built with the surface's default action list (no :actions override),
  # so model.actions reflects default_actions/0 -> Skills.enabled_actions/0.
  defp new_model do
    App.init(%{
      options: [
        runner: fn _, _, _, _ -> :ok end,
        sessions_dir:
          Path.join(System.tmp_dir!(), "raxol-code-skills-#{System.unique_integer([:positive])}")
      ]
    })
  end

  test "the coding agent exposes skill actions when a provider is configured" do
    Application.put_env(:raxol_agent, :skills_provider, Store)
    model = new_model()

    for action <- SkillsActions.actions() do
      assert action in model.actions
    end
  end

  test "the coding agent omits skill actions when no provider is configured" do
    Application.delete_env(:raxol_agent, :skills_provider)
    model = new_model()

    for action <- SkillsActions.actions() do
      refute action in model.actions
    end
  end
end
