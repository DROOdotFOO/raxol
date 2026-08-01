defmodule Raxol.ACP.Console.PackageTest do
  # async: false -- the round-trip test flips the inference module via app env.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Console.{Generator, Package, Spec}

  describe "parse/1 <-> Generator round-trip" do
    setup do
      prev_inf = Application.get_env(:raxol_acp, :console_inference)
      prev_static = Application.get_env(:raxol_acp, :console_inference_static)

      envelope =
        Jason.encode!(%{
          "soul_md" => "# Ops Bot\n\nYou are Ops Bot, an operations assistant.",
          "agents_md" => "# Operating rules\n\nBe concise and cite sources.",
          "tasks" => [
            %{
              "name" => "daily_summary",
              "description" => "Summarize open PRs",
              "cron" => "0 9 * * 1-5",
              "prompt" => "Summarize my open PRs and post them."
            }
          ],
          "skills" => [
            %{
              "name" => "pr_review",
              "skill_md" => "---\nname: pr_review\ndescription: review PRs\n---\n\nReview the PR."
            }
          ]
        })

      Application.put_env(:raxol_acp, :console_inference,
        module: Raxol.ACP.Console.Inference.Static
      )

      Application.put_env(:raxol_acp, :console_inference_static, envelope)

      on_exit(fn ->
        restore(:console_inference, prev_inf)
        restore(:console_inference_static, prev_static)
      end)

      :ok
    end

    test "a :raxol package generated then parsed round-trips with fidelity" do
      {:ok, spec} =
        Spec.validate(%{
          "purpose" => "operations assistant",
          "runtime" => "raxol",
          "agent_name" => "ops_bot",
          "scheduled_tasks" => [%{"description" => "summarize PRs", "cadence" => "0 9 * * 1-5"}],
          "skills" => ["pr_review"]
        })

      assert spec.runtime == :raxol

      {:ok, pkg} = Generator.generate(spec, "job-round-trip")
      assert pkg.runtime == :raxol
      # :raxol now emits AGENTS.md (the loader consumes both soul.md + AGENTS.md).
      assert Map.has_key?(pkg.files, "AGENTS.md")
      assert Map.has_key?(pkg.files, "skills/pr_review/SKILL.md")

      {:ok, parsed} = Package.parse(pkg.files)

      assert parsed.runtime == :raxol
      assert parsed.soul_md =~ "Ops Bot"
      assert parsed.agents_md =~ "Operating rules"

      assert [%{name: "daily_summary", cron: "0 9 * * 1-5", prompt: prompt, description: _}] =
               parsed.tasks

      assert prompt =~ "Summarize"

      assert [%{name: "pr_review", skill_md: skill_md}] = parsed.skills
      assert skill_md =~ "review PRs"
    end
  end

  describe "parse/1 validation" do
    test "requires soul.md" do
      assert {:error, {:invalid_package, "soul.md", :missing}} = Package.parse(%{})
    end

    test "rejects a non-map" do
      assert {:error, {:invalid_package, :root, {:not_a_map, "x"}}} = Package.parse("x")
    end

    test "rejects an unknown runtime in the manifest" do
      files = %{
        "soul.md" => "# Bot",
        "manifest.json" => Jason.encode!(%{"runtime" => "bogus"})
      }

      assert {:error, {:invalid_package, :runtime, {:unknown, "bogus"}}} = Package.parse(files)
    end

    test "rejects a task with an invalid cron" do
      files = %{
        "soul.md" => "# Bot",
        "tasks.json" =>
          Jason.encode!(%{
            "tasks" => [
              %{"name" => "t1", "description" => "d", "cron" => "99 9 * * *", "prompt" => "p"}
            ]
          })
      }

      assert {:error, {:invalid_package, :task, {:bad_cron, "t1", "99 9 * * *"}}} =
               Package.parse(files)
    end

    test "silently excludes skill paths that escape the single-segment slug" do
      files = %{
        "soul.md" => "# Bot",
        "skills/ok/SKILL.md" => "safe",
        "skills/../evil/SKILL.md" => "unsafe"
      }

      assert {:ok, %Package{skills: [%{name: "ok", skill_md: "safe"}]}} = Package.parse(files)
    end

    test "parses with no manifest, tasks, or skills (soul-only)" do
      assert {:ok, %Package{runtime: nil, tasks: [], skills: [], soul_md: "# Bot"}} =
               Package.parse(%{"soul.md" => "# Bot"})
    end
  end

  describe "load/1" do
    test "reads a package directory into a %Package{}" do
      dir = Path.join(System.tmp_dir!(), "console_pkg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "skills/greet"))
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "soul.md"), "# Loaded Bot")
      File.write!(Path.join(dir, "AGENTS.md"), "# Rules")

      File.write!(
        Path.join(dir, "tasks.json"),
        Jason.encode!(%{
          "tasks" => [
            %{"name" => "t", "description" => "d", "cron" => "*/5 * * * *", "prompt" => "go"}
          ]
        })
      )

      File.write!(Path.join(dir, "skills/greet/SKILL.md"), "hello skill")
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"runtime" => "raxol"}))

      assert {:ok, pkg} = Package.load(dir)
      assert pkg.runtime == :raxol
      assert pkg.soul_md == "# Loaded Bot"
      assert pkg.agents_md == "# Rules"
      assert [%{name: "t", cron: "*/5 * * * *"}] = pkg.tasks
      assert [%{name: "greet", skill_md: "hello skill"}] = pkg.skills
    end

    test "errors when the path is not a directory" do
      assert {:error, {:invalid_package, :dir, {:not_a_directory, "/no/such/dir"}}} =
               Package.load("/no/such/dir")
    end

    test "skips symlinked entries so a package cannot smuggle host files" do
      dir = Path.join(System.tmp_dir!(), "console_pkg_#{System.unique_integer([:positive])}")

      secret =
        Path.join(System.tmp_dir!(), "console_secret_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "skills/evil"))
      File.write!(secret, "TOP SECRET HOST FILE")

      on_exit(fn ->
        File.rm_rf(dir)
        File.rm_rf(secret)
      end)

      File.write!(Path.join(dir, "soul.md"), "# Bot")
      # A symlinked SKILL.md pointing at a host file: must NOT be read in.
      File.ln_s!(secret, Path.join(dir, "skills/evil/SKILL.md"))

      assert {:ok, pkg} = Package.load(dir)
      assert pkg.skills == []
    end

    test "a symlinked required file fails closed rather than reading the target" do
      dir = Path.join(System.tmp_dir!(), "console_pkg_#{System.unique_integer([:positive])}")

      secret =
        Path.join(System.tmp_dir!(), "console_secret_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(secret, "TOP SECRET")

      on_exit(fn ->
        File.rm_rf(dir)
        File.rm_rf(secret)
      end)

      # soul.md is a symlink to a host file: skipped, so the package is missing it.
      File.ln_s!(secret, Path.join(dir, "soul.md"))

      assert {:error, {:invalid_package, "soul.md", :missing}} = Package.load(dir)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:raxol_acp, key)
  defp restore(key, val), do: Application.put_env(:raxol_acp, key, val)
end
