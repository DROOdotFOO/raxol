defmodule Raxol.Agent.SkillsTest do
  # async: false -- these mutate the :raxol_agent app env.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Skills, as: SkillsActions
  alias Raxol.Agent.Skills
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

  describe "with a skills provider configured" do
    setup do
      Application.put_env(:raxol_agent, :skills_provider, Store)
      :ok
    end

    test "default_provider/0 returns the configured store" do
      assert Skills.default_provider() == Store
    end

    test "enabled_actions/0 exposes skills_list, skill_view, and skill_manage" do
      actions = Skills.enabled_actions()

      assert actions == SkillsActions.actions()
      assert SkillsActions.List in actions
      assert SkillsActions.View in actions
      assert SkillsActions.Manage in actions
    end

    test "default_context/0 wires the store under context[:skills]" do
      assert Skills.default_context() == {Store, []}
    end
  end

  describe "with no skills provider configured" do
    setup do
      Application.delete_env(:raxol_agent, :skills_provider)
      :ok
    end

    test "default_provider/0 is nil" do
      assert Skills.default_provider() == nil
    end

    test "enabled_actions/0 exposes no skill actions" do
      assert Skills.enabled_actions() == []
    end

    test "default_context/0 is nil" do
      assert Skills.default_context() == nil
    end
  end
end
