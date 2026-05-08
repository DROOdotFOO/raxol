defmodule Raxol.Symphony.Evidence.GitHubTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Evidence}
  alias Raxol.Symphony.Evidence.GitHub

  defp config(token \\ "ghp_test") do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "github", api_key: token, project_slug: "raxol/test"}
      },
      prompt_template: ""
    })
  end

  defp evidence(extra \\ %{}) do
    base = %Evidence{workspace: "/tmp/x", repo: "raxol/test"}
    struct!(base, extra)
  end

  defp stub_plug(routes) do
    fn conn ->
      key = {conn.method, conn.request_path}

      case Map.get(routes, key) do
        nil ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(404, ~s({"message":"Not Found"}))

        {status, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end
  end

  describe "auth resolution" do
    test "falls back to $GITHUB_TOKEN when tracker is not github" do
      System.put_env("GITHUB_TOKEN", "env-token")

      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "linear", api_key: "linear-key"}},
          prompt_template: ""
        })

      result =
        GitHub.collect(evidence(%{ref: "main"}), cfg,
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/actions/runs"} => {200, %{"workflow_runs" => []}}
            })
        )

      refute Map.has_key?(result.errors, :github)
    after
      System.delete_env("GITHUB_TOKEN")
    end

    test "records :no_token when neither tracker nor env is set" do
      System.delete_env("GITHUB_TOKEN")

      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "memory"}},
          prompt_template: ""
        })

      result = GitHub.collect(evidence(%{ref: "main"}), cfg, [])
      assert result.errors[:github] == :no_token
    end

    test "records :no_repo when subject lacks a repo" do
      result =
        GitHub.collect(%Evidence{workspace: "/tmp/x", ref: "main"}, config(), [])

      assert result.errors[:github] == :no_repo
    end
  end

  describe "CI lookup" do
    test "populates :ci from the latest workflow run for the ref" do
      run = %{
        "id" => 42,
        "name" => "CI",
        "status" => "completed",
        "conclusion" => "success",
        "head_branch" => "main",
        "head_sha" => "abc123",
        "run_number" => 5,
        "html_url" => "https://github.com/raxol/test/actions/runs/42",
        "created_at" => "2026-05-08T10:00:00Z",
        "updated_at" => "2026-05-08T10:01:00Z"
      }

      result =
        GitHub.collect(evidence(%{ref: "main"}), config(),
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/actions/runs"} => {200, %{"workflow_runs" => [run]}}
            })
        )

      assert result.ci.id == 42
      assert result.ci.conclusion == "success"
      assert result.ci.url == "https://github.com/raxol/test/actions/runs/42"
    end

    test "returns :no_runs marker when API yields an empty list" do
      result =
        GitHub.collect(evidence(%{ref: "feature"}), config(),
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/actions/runs"} => {200, %{"workflow_runs" => []}}
            })
        )

      assert result.ci == %{status: :no_runs, ref: "feature"}
    end

    test "non-200 lands in errors[:github_ci]" do
      result =
        GitHub.collect(evidence(%{ref: "main"}), config(),
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/actions/runs"} => {403, %{"message" => "rate limited"}}
            })
        )

      assert result.errors[:github_ci] == {:status, 403}
    end

    test "skipped when subject has no ref" do
      result =
        GitHub.collect(evidence(), config(), plug: stub_plug(%{}))

      assert is_nil(result.ci)
    end
  end

  describe "PR / issue comments" do
    test "populates :pr_comments when issue_number is set" do
      comments = [
        %{
          "id" => 1,
          "user" => %{"login" => "alice"},
          "body" => "looks good",
          "created_at" => "2026-05-08T09:00:00Z",
          "updated_at" => "2026-05-08T09:00:00Z",
          "html_url" => "https://github.com/raxol/test/issues/7#1"
        }
      ]

      result =
        GitHub.collect(evidence(%{issue_number: 7}), config(),
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/issues/7/comments"} => {200, comments}
            })
        )

      assert [%{author: "alice", body: "looks good"}] = result.pr_comments
    end

    test "skipped when issue_number is nil" do
      result = GitHub.collect(evidence(), config(), plug: stub_plug(%{}))
      assert result.pr_comments == []
    end

    test "non-200 lands in errors[:github_pr_comments]" do
      result =
        GitHub.collect(evidence(%{issue_number: 7}), config(),
          plug:
            stub_plug(%{
              {"GET", "/repos/raxol/test/issues/7/comments"} => {500, %{"message" => "boom"}}
            })
        )

      assert result.errors[:github_pr_comments] == {:status, 500}
    end
  end
end
