defmodule Raxol.Earn.Console.DeliveryTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Console.{AgentOffering, BenchSlots, Delivery, Inference}

  @ctx %{job_id: "job-console-1", buyer: "0xb", seller: "0xs", state: :open}

  @request %{
    "purpose" => "Watch my repo and summarize new issues every morning.",
    "runtime" => "openclaw",
    "scheduled_tasks" => [%{"description" => "Morning digest", "cadence" => "0 7 * * *"}],
    "skills" => ["summarize github issues"]
  }

  @envelope Jason.encode!(%{
              "soul_md" =>
                "# Issue Scout\n\nIdentity: a terse repository watcher for one repo.\n" <>
                  "Purpose: summarize new issues each morning. Boundaries: read-only.\n",
              "agents_md" => "# Agents\n\nSingle agent: issue scout.\n",
              "tasks" => [
                %{
                  "name" => "morning_digest",
                  "description" => "Summarize new issues",
                  "cron" => "0 7 * * *",
                  "prompt" => "Summarize issues opened in the last 24h."
                }
              ],
              "skills" => [
                %{
                  "name" => "issue_summarizer",
                  "skill_md" =>
                    "---\nname: issue_summarizer\ndescription: summarizes issues\n---\n\n# Use\n"
                }
              ]
            })

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "raxol_console_artifacts_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    Application.put_env(:raxol_earn, :console_inference, module: Inference.Static)
    Application.put_env(:raxol_earn, :console_inference_static, @envelope)
    Application.put_env(:raxol_earn, :console_bench_module, Raxol.Earn.Console.Bench.Mock)

    Application.put_env(:raxol_earn, :console_artifact_store,
      module: Raxol.Earn.Console.ArtifactStore.Local,
      dir: tmp
    )

    on_exit(fn ->
      for key <- [
            :console_inference,
            :console_inference_static,
            :console_bench_module,
            :console_artifact_store,
            :console_bench_mock
          ],
          do: Application.delete_env(:raxol_earn, key)

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "AgentOffering.handle_request/2 (pre-escrow gate)" do
    test "rejects fail-closed when the bench-slot ledger is not running" do
      assert {:reject, :bench_unavailable} = AgentOffering.handle_request(@request, @ctx)
    end

    test "accepts with a slot, rejects at capacity, package_only bypasses" do
      start_supervised!({BenchSlots, max: 1})

      assert {:accept, @request} = AgentOffering.handle_request(@request, @ctx)
      # same job re-offered: idempotent reserve, still accepted
      assert {:accept, @request} = AgentOffering.handle_request(@request, @ctx)

      other = %{@ctx | job_id: "job-console-2"}
      assert {:reject, :at_bench_capacity} = AgentOffering.handle_request(@request, other)

      pkg_only = Map.put(@request, "validation", "package_only")
      assert {:accept, ^pkg_only} = AgentOffering.handle_request(pkg_only, other)
    end

    test "rejects malformed requirements with a typed reason" do
      assert {:reject, {:invalid_requirement, "purpose", :missing}} =
               AgentOffering.handle_request(Map.delete(@request, "purpose"), @ctx)
    end

    test "handle_release frees a reserved bench slot (no leak on non-delivery)" do
      start_supervised!({BenchSlots, max: 1})

      assert {:accept, _} = AgentOffering.handle_request(@request, @ctx)
      other = %{@ctx | job_id: "job-console-rel"}
      assert {:reject, :at_bench_capacity} = AgentOffering.handle_request(@request, other)

      # the accepted job ends without delivering -> release its slot
      assert :ok = AgentOffering.handle_release(@request, @ctx)
      assert {:accept, _} = AgentOffering.handle_request(@request, other)
    end
  end

  describe "Delivery.run/2" do
    test "full bench-validated pipeline yields the deliverable contract", %{tmp: tmp} do
      start_supervised!({BenchSlots, max: 1})
      assert :ok = BenchSlots.reserve(@ctx.job_id)

      assert {:deliver, deliverable} = Delivery.run(@request, @ctx)

      assert %{
               "package_tarball_url" => tar_url,
               "sha256" => sha,
               "manifest" => %{"runtime" => "openclaw", "files" => files},
               "evidence" => %{"checks" => ["boot", "prompt", "task_dry_run"]}
             } = deliverable

      assert "soul.md" in files and "AGENTS.md" in files and "tasks.json" in files
      assert "skills/issue_summarizer/SKILL.md" in files

      "file://" <> tar_path = tar_url
      assert sha == :crypto.hash(:sha256, File.read!(tar_path)) |> Base.encode16(case: :lower)

      # slot released in `after`: a new job can reserve immediately
      assert :ok = BenchSlots.reserve("job-console-3")

      # replay lands at the same job-deterministic artifact path
      assert {:deliver, %{"package_tarball_url" => ^tar_url}} = Delivery.run(@request, @ctx)
      assert File.dir?(Path.join(tmp, @ctx.job_id |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")))
    end

    test "package_only skips the bench and carries nil evidence" do
      req = Map.put(@request, "validation", "package_only")
      assert {:deliver, %{"evidence" => nil}} = Delivery.run(req, @ctx)
    end

    test "a failing bench blocks delivery with the typed reason" do
      start_supervised!({BenchSlots, max: 1})

      Application.put_env(
        :raxol_earn,
        :console_bench_mock,
        {:error, {:bench_failed, :boot, 1, ""}}
      )

      assert {:error, {:bench_failed, :boot, 1, ""}} = Delivery.run(@request, @ctx)
    end

    test "a malformed generation envelope blocks delivery" do
      Application.put_env(:raxol_earn, :console_inference_static, "not json at all")
      assert {:error, {:generation_not_json, _}} = Delivery.run(@request, @ctx)
    end

    test "a skill name that would escape the package dir is rejected before any write" do
      evil =
        Jason.encode!(%{
          "soul_md" =>
            "# Scout\n\nIdentity: a watcher.\nPurpose: summarize.\nBoundaries: read-only.\n",
          "agents_md" => "# Agents\n",
          "tasks" => [],
          "skills" => [
            %{
              "name" => "../../../../etc/evil",
              "skill_md" => "---\nname: x\ndescription: y\n---\n"
            }
          ]
        })

      Application.put_env(:raxol_earn, :console_inference_static, evil)

      assert {:error, {:generation_unsafe_skill_name, "../../../../etc/evil"}} =
               Delivery.run(@request, @ctx)
    end
  end
end
