defmodule Raxol.Agent.SkillTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Skill

  @sample """
  ---
  name: deploy-fly
  description: >
    How to deploy a Raxol app to Fly.io.
  version: "1.2.0"
  category: ops
  created_by: agent
  metadata:
    author: tester
    tags:
      - deploy
      - fly
  ---

  # Deploy to Fly

  Run `flyctl deploy`.
  """

  describe "parse/1" do
    test "extracts modeled frontmatter fields and the body" do
      assert {:ok, skill} = Skill.parse(@sample)
      assert skill.name == "deploy-fly"
      assert skill.version == "1.2.0"
      assert skill.category == "ops"
      assert skill.created_by == :agent
      assert skill.description =~ "deploy a Raxol app"
      assert skill.body =~ "# Deploy to Fly"
      assert skill.body =~ "flyctl deploy"
    end

    test "preserves unmodeled frontmatter keys under :metadata" do
      assert {:ok, skill} = Skill.parse(@sample)

      assert %{"metadata" => %{"author" => "tester", "tags" => ["deploy", "fly"]}} =
               skill.metadata
    end

    test "decodes created_by to :agent, :user, or nil" do
      assert {:ok, %{created_by: :user}} = Skill.parse(frontmatter("name: x\ncreated_by: user"))
      assert {:ok, %{created_by: nil}} = Skill.parse(frontmatter("name: x\ncreated_by: robot"))
      assert {:ok, %{created_by: nil}} = Skill.parse(frontmatter("name: x"))
    end

    test "rejects content without frontmatter" do
      assert {:error, :missing_frontmatter} = Skill.parse("# just markdown, no frontmatter")
    end

    test "rejects frontmatter without a name" do
      assert {:error, :missing_name} = Skill.parse(frontmatter("description: no name here"))
    end
  end

  describe "render/1 round-trip" do
    test "parse(render(skill)) returns an equal struct" do
      {:ok, skill} = Skill.parse(@sample)
      {:ok, reparsed} = Skill.parse(Skill.render(skill))
      assert reparsed == skill
    end

    test "preserves the body byte-for-byte across a round trip" do
      {:ok, skill} = Skill.parse(@sample)
      {:ok, reparsed} = Skill.parse(Skill.render(skill))
      assert reparsed.body == skill.body
    end

    test "renders a minimal skill (name + body only)" do
      skill = %Skill{name: "tiny", body: "do the thing"}
      {:ok, reparsed} = Skill.parse(Skill.render(skill))
      assert reparsed.name == "tiny"
      assert reparsed.body == "do the thing"
    end
  end

  describe "from_file/1" do
    test "reads and parses a SKILL.md from disk" do
      dir = Path.join(System.tmp_dir!(), "skill_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file = Path.join(dir, "SKILL.md")
      File.write!(file, @sample)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, %Skill{name: "deploy-fly"}} = Skill.from_file(file)
    end

    test "returns an error tuple for a missing file" do
      assert {:error, {:read_failed, :enoent}} = Skill.from_file("/no/such/SKILL.md")
    end
  end

  defp frontmatter(yaml), do: "---\n" <> yaml <> "\n---\n\nbody\n"
end
