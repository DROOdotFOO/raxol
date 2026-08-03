defmodule Raxol.Earn.Console.SpecValidatorTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Console.{Cron, Spec, Validator}

  @valid %{
    "purpose" => "Watch my repo and summarize new issues every morning.",
    "runtime" => "hermes",
    "agent_name" => "issue-scout",
    "scheduled_tasks" => [
      %{"description" => "Summarize new issues", "cadence" => "0 7 * * *"},
      %{"description" => "Weekly digest", "cadence" => "every friday afternoon"}
    ],
    "skills" => ["summarize github issues"],
    "constraints" => %{"tone" => "terse"}
  }

  describe "Cron.valid?/1" do
    test "accepts *, values, ranges, steps, lists" do
      for expr <- ["* * * * *", "0 7 * * *", "*/5 0-12 1,15 * 1-5", "0 0 1-31/2 * *"] do
        assert Cron.valid?(expr), expr
      end
    end

    test "rejects wrong arity, out-of-bounds, names, garbage" do
      for expr <- ["* * * *", "60 * * * *", "* 24 * * *", "0 7 * * mon", "not cron", ""] do
        refute Cron.valid?(expr), expr
      end
    end
  end

  describe "Spec.validate/1" do
    test "normalizes a valid request; cron kept, NL flagged for canonicalization" do
      assert {:ok, %Spec{} = spec} = Spec.validate(@valid)
      assert spec.runtime == :hermes
      assert spec.validation == :bench_validated
      assert [%{cadence: {:cron, "0 7 * * *"}}, %{cadence: {:nl, _}}] = spec.scheduled_tasks
    end

    test "rejects missing purpose, bad runtime, bad agent_name, oversize task list" do
      assert {:error, {:invalid_requirement, "purpose", :missing}} =
               Spec.validate(Map.delete(@valid, "purpose"))

      assert {:error, {:invalid_requirement, "runtime", {:not_in_enum, "nope"}}} =
               Spec.validate(%{@valid | "runtime" => "nope"})

      assert {:error, {:invalid_requirement, :agent_name, _}} =
               Spec.validate(Map.put(@valid, "agent_name", "Bad Name!"))

      too_many = List.duplicate(%{"description" => "t", "cadence" => "* * * * *"}, 6)

      assert {:error, {:invalid_requirement, :scheduled_tasks, _}} =
               Spec.validate(Map.put(@valid, "scheduled_tasks", too_many))
    end

    test "content policy rejects configured deny terms before escrow" do
      Application.put_env(:raxol_earn, :console_deny_terms, ["clone of"])
      on_exit(fn -> Application.delete_env(:raxol_earn, :console_deny_terms) end)

      assert {:error, {:denied_purpose, "clone of"}} =
               Spec.validate(%{@valid | "purpose" => "An exact CLONE OF another agent's soul"})
    end
  end

  describe "Validator.validate/1" do
    defp pkg(files, tasks) do
      listed = Enum.sort(["manifest.json" | Map.keys(files)])
      files = Map.put(files, "manifest.json", Jason.encode!(%{"files" => listed}))
      %{files: files, tasks: tasks}
    end

    @soul "# Issue Scout\n\nIdentity: a terse repository watcher.\nPurpose: summarize issues.\n"
    @task %{"name" => "digest", "description" => "d", "cron" => "0 7 * * *", "prompt" => "go"}

    test "passes a well-formed package and reports every check" do
      files = %{
        "soul.md" => @soul,
        "tasks.json" => Jason.encode!(%{"tasks" => [@task]}),
        "skills/greet/SKILL.md" => "---\nname: greet\ndescription: says hi\n---\n\n# Greet\n"
      }

      assert {:ok, report} = Validator.validate(pkg(files, [@task]))
      assert Keyword.keys(report) == [:soul, :placeholders, :secrets, :tasks, :skills, :manifest]
    end

    test "fails on missing H1, placeholders, secret-shaped strings, bad cron, bad skill" do
      base = %{"soul.md" => @soul, "tasks.json" => Jason.encode!(%{"tasks" => []})}

      assert {:error, {:soul, :no_h1_title}} =
               Validator.validate(pkg(%{base | "soul.md" => String.duplicate("plain\n", 20)}, []))

      assert {:error, {:placeholders, {"soul.md", _}}} =
               Validator.validate(pkg(%{base | "soul.md" => @soul <> "{{agent_name}}"}, []))

      assert {:error, {:secrets, {"soul.md", :redacted}}} =
               Validator.validate(
                 pkg(%{base | "soul.md" => @soul <> "key sk-abcdefghijklmnop1234"}, [])
               )

      bad_task = %{@task | "cron" => "every day"}

      assert {:error, {:tasks, {:invalid_cron, "digest", "every day"}}} =
               Validator.validate(pkg(base, [bad_task]))

      bad_skill = Map.put(base, "skills/x/SKILL.md", "# no frontmatter\n")

      assert {:error, {:skills, {:bad_skill, "skills/x/SKILL.md"}}} =
               Validator.validate(pkg(bad_skill, []))
    end
  end
end
