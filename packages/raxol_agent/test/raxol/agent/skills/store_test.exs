defmodule Raxol.Agent.Skills.StoreTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Skill
  alias Raxol.Agent.Skills.Store

  setup do
    base = Path.join(System.tmp_dir!(), "skills_#{System.unique_integer([:positive])}")
    root = Path.join(base, "managed")
    external = Path.join(base, "external")
    dets = Path.join(base, "usage.dets")
    File.mkdir_p!(root)
    File.mkdir_p!(external)

    # Seed one read-only external skill.
    write_skill(external, %Skill{
      name: "git-bisect",
      description: "Find a regression with git bisect.",
      created_by: :user,
      body: "# git bisect\n\nRun `git bisect start`.\n"
    })

    on_exit(fn -> File.rm_rf(base) end)

    name = :"skills_#{System.unique_integer([:positive])}"
    start_supervised!(start_spec(name, root, external, dets))

    %{server: name, root: root, external: external, dets: dets, base: base}
  end

  describe "indexing" do
    test "lists external skills (metadata only)", %{server: s} do
      assert [%{name: "git-bisect", source: :external, state: :active} = meta] =
               Store.list(server: s)

      assert meta.description =~ "git bisect"
      refute Map.has_key?(meta, :body)
    end

    test "view returns the SKILL.md body", %{server: s} do
      assert {:ok, body} = Store.view("git-bisect", nil, server: s)
      assert body =~ "git bisect start"
    end

    test "get returns the full parsed skill", %{server: s} do
      assert {:ok, %Skill{name: "git-bisect", created_by: :user}} =
               Store.get("git-bisect", server: s)
    end

    test "missing skill is not_found", %{server: s} do
      assert {:error, :not_found} = Store.get("nope", server: s)
      assert {:error, :not_found} = Store.view("nope", nil, server: s)
    end
  end

  describe "create / patch / delete" do
    test "creates a managed skill, indexes it, and writes SKILL.md to disk", %{
      server: s,
      root: root
    } do
      assert {:ok, %Skill{name: "deploy"}} =
               Store.create(
                 %{
                   name: "deploy",
                   category: "ops",
                   description: "Deploy it.",
                   body: "# Deploy\n",
                   created_by: :user
                 },
                 server: s
               )

      assert File.exists?(Path.join([root, "ops", "deploy", "SKILL.md"]))
      assert "deploy" in Enum.map(Store.list(server: s), & &1.name)
      assert {:ok, "# Deploy\n"} = Store.view("deploy", nil, server: s)
    end

    test "patch merges changes and rewrites the file", %{server: s} do
      Store.create(%{name: "p", description: "v1", body: "old", created_by: :user}, server: s)

      assert {:ok, %Skill{body: "new", description: "v1"}} =
               Store.patch("p", %{body: "new"}, server: s)

      assert {:ok, "new"} = Store.view("p", nil, server: s)
    end

    test "delete removes a managed skill and its directory", %{server: s, root: root} do
      Store.create(%{name: "tmp", body: "x", created_by: :user}, server: s)
      assert :ok = Store.delete("tmp", server: s)
      assert {:error, :not_found} = Store.get("tmp", server: s)
      refute File.exists?(Path.join([root, "tmp"]))
    end

    test "external skills are read-only", %{server: s} do
      assert {:error, :read_only_skill} = Store.patch("git-bisect", %{body: "x"}, server: s)
      assert {:error, :read_only_skill} = Store.delete("git-bisect", server: s)
    end

    test "a managed skill shadows an external skill of the same name", %{server: s} do
      assert {:ok, _} =
               Store.create(%{name: "git-bisect", body: "managed wins", created_by: :user},
                 server: s
               )

      assert {:ok, "managed wins"} = Store.view("git-bisect", nil, server: s)
      assert [%{name: "git-bisect", source: :managed}] = Store.list(server: s)
    end
  end

  describe "supporting-file view" do
    test "reads a supporting file relative to the skill dir", %{server: s, root: root} do
      Store.create(%{name: "withref", body: "# main\n", created_by: :user}, server: s)
      File.write!(Path.join([root, "withref", "notes.md"]), "extra notes")
      assert {:ok, "extra notes"} = Store.view("withref", "notes.md", server: s)
    end

    test "rejects path traversal", %{server: s} do
      Store.create(%{name: "guarded", body: "x", created_by: :user}, server: s)
      assert {:error, :unsafe_path} = Store.view("guarded", "../../etc/passwd", server: s)
      assert {:error, :unsafe_path} = Store.view("guarded", "/etc/passwd", server: s)
    end
  end

  describe "usage telemetry" do
    test "record_use increments use_count and sets last_used_at", %{server: s} do
      Store.create(%{name: "u", body: "x", created_by: :agent}, server: s)
      assert {:ok, %{use_count: 0, last_used_at: nil}} = Store.usage("u", server: s)

      Store.record_use("u", server: s)
      Store.record_use("u", server: s)
      assert {:ok, %{use_count: count, last_used_at: ts}} = Store.usage("u", server: s)
      assert count == 2
      assert is_integer(ts)
    end

    test "view bumps view_count", %{server: s} do
      Store.create(%{name: "v", body: "x", created_by: :agent}, server: s)
      Store.view("v", nil, server: s)
      assert {:ok, %{view_count: 1}} = Store.usage("v", server: s)
    end

    test "telemetry survives a restart via DETS", %{
      server: s,
      root: root,
      external: external,
      dets: dets
    } do
      Store.create(%{name: "persist", body: "x", created_by: :agent}, server: s)
      Store.record_use("persist", server: s)
      assert {:ok, %{use_count: 1}} = Store.usage("persist", server: s)

      stop_supervised!(s)
      restart = :"skills_#{System.unique_integer([:positive])}"
      start_supervised!(start_spec(restart, root, external, dets))

      # The skill is re-read from disk; its usage is restored from DETS.
      assert {:ok, %{use_count: 1}} = Store.usage("persist", server: restart)
    end
  end

  defp start_spec(name, root, external, dets) do
    %{
      id: name,
      start:
        {Store, :start_link,
         [[name: name, skills_root: root, external_dirs: [external], dets_path: dets]]}
    }
  end

  defp write_skill(root, %Skill{name: skill_name} = skill) do
    dir = Path.join(root, skill_name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), Skill.render(skill))
  end
end
