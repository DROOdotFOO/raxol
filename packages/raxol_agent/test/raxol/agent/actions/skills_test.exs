defmodule Raxol.Agent.Actions.SkillsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Skills.{List, Manage, View}
  alias Raxol.Agent.Skills.Store

  defmodule SkilledAgent do
    use Raxol.Agent
    def skills_provider, do: Raxol.Agent.Skills.Store
  end

  defmodule PlainAgent do
    use Raxol.Agent
  end

  setup do
    base = Path.join(System.tmp_dir!(), "skillact_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "managed"))
    on_exit(fn -> File.rm_rf(base) end)

    name = :"skillact_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start:
        {Store, :start_link,
         [[name: name, skills_root: Path.join(base, "managed"), external_dirs: []]]}
    })

    %{context: %{skills: {Store, [server: name]}}}
  end

  describe "skill_manage" do
    test "creates a skill and reports ok", %{context: ctx} do
      assert {:ok, %{ok: true, name: "alpha"}} =
               Manage.call(%{action: "create", name: "alpha", body: "# Alpha\n"}, ctx)
    end

    test "foreground create is tagged created_by: :user", %{context: ctx} do
      Manage.call(%{action: "create", name: "beta", body: "x"}, ctx)
      {Store, opts} = ctx.skills
      assert {:ok, %{created_by: :user}} = Store.get("beta", opts)
    end

    test "patches and deletes", %{context: ctx} do
      Manage.call(%{action: "create", name: "gamma", body: "old"}, ctx)
      assert {:ok, %{ok: true}} = Manage.call(%{action: "patch", name: "gamma", body: "new"}, ctx)
      assert {:ok, %{content: "new"}} = View.call(%{name: "gamma"}, ctx)
      assert {:ok, %{ok: true}} = Manage.call(%{action: "delete", name: "gamma"}, ctx)
    end
  end

  describe "skills_list and skill_view" do
    test "lists created skills as metadata", %{context: ctx} do
      Manage.call(%{action: "create", name: "one", description: "first", body: "x"}, ctx)
      assert {:ok, %{skills: skills}} = List.call(%{}, ctx)
      assert Enum.any?(skills, &(&1.name == "one" and &1.description == "first"))
    end

    test "views a created skill body", %{context: ctx} do
      Manage.call(%{action: "create", name: "doc", body: "# Doc\n\ncontents"}, ctx)
      assert {:ok, %{content: "# Doc\n\ncontents"}} = View.call(%{name: "doc"}, ctx)
    end
  end

  describe "without a skills provider in context" do
    test "every action returns skills_not_configured" do
      assert {:error, :skills_not_configured} = List.call(%{}, %{})
      assert {:error, :skills_not_configured} = View.call(%{name: "x"}, %{})
      assert {:error, :skills_not_configured} = Manage.call(%{action: "delete", name: "x"}, %{})
    end
  end

  describe "available_actions wiring" do
    test "an agent with a skills provider exposes the skill actions" do
      actions = SkilledAgent.available_actions()
      assert List in actions
      assert View in actions
      assert Manage in actions
    end

    test "an agent without a skills provider exposes no skill actions" do
      assert PlainAgent.available_actions() == []
    end
  end
end
