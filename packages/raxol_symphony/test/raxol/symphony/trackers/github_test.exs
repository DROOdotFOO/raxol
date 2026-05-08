defmodule Raxol.Symphony.Trackers.GitHubTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Tracker}

  setup do
    on_exit(fn -> Application.delete_env(:raxol_symphony, :github) end)
    :ok
  end

  defp config(overrides \\ []) do
    tracker =
      Map.merge(
        %{
          kind: "github",
          api_key: "ghp_test",
          project_slug: "owner/repo",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        Map.new(overrides)
      )

    Config.from_workflow(%{config: %{tracker: tracker}, prompt_template: ""})
  end

  defp install_handler(handler) when is_function(handler, 1) do
    plug = fn conn ->
      response = handler.(conn)
      send_response(conn, response)
    end

    Application.put_env(:raxol_symphony, :github, plug: plug)
  end

  defp send_response(conn, {:status, status, payload}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp send_response(conn, {:list, payload}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp send_response(conn, {:list, payload, link_header}) do
    conn
    |> Plug.Conn.put_resp_header("link", link_header)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp issue_node(overrides) do
    overrides = Map.new(overrides)
    number = Map.get(overrides, "number", 1)

    base = %{
      "number" => number,
      "title" => "Hello",
      "body" => "world",
      "state" => "open",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "created_at" => "2026-05-01T12:00:00Z",
      "updated_at" => "2026-05-02T12:00:00Z",
      "labels" => [%{"name" => "state/todo"}]
    }

    Map.merge(base, overrides)
  end

  # -- Validation -------------------------------------------------------------

  describe "validation" do
    test "missing api_key surfaces :missing_tracker_api_key" do
      cfg = config(api_key: nil)
      assert {:error, :missing_tracker_api_key} = Tracker.fetch_candidate_issues(cfg)
    end

    test "missing project_slug surfaces :missing_tracker_project_slug" do
      cfg = config(project_slug: nil)
      assert {:error, :missing_tracker_project_slug} = Tracker.fetch_candidate_issues(cfg)
    end

    test "non owner/repo slug surfaces :invalid_github_repo" do
      cfg = config(project_slug: "owner-only")

      assert {:error, {:invalid_github_repo, "owner-only"}} =
               Tracker.fetch_candidate_issues(cfg)
    end
  end

  # -- Request shape ----------------------------------------------------------

  describe "request shape" do
    test "sends Bearer auth, GitHub accept header, and api version" do
      parent = self()
      ref = make_ref()

      install_handler(fn conn ->
        send(parent, {ref, :headers, conn.req_headers, conn.request_path, conn.params})
        {:list, []}
      end)

      assert {:ok, []} = Tracker.fetch_candidate_issues(config())

      assert_receive {^ref, :headers, headers, path, _params}
      assert {"authorization", "Bearer ghp_test"} in headers
      assert {"accept", "application/vnd.github+json"} in headers
      assert {"x-github-api-version", "2022-11-28"} in headers
      assert path == "/repos/owner/repo/issues"
    end

    test "fetch_candidate_issues uses state=open" do
      parent = self()
      ref = make_ref()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {ref, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([]))
      end

      Application.put_env(:raxol_symphony, :github, plug: plug)

      assert {:ok, []} = Tracker.fetch_candidate_issues(config())

      assert_receive {^ref, params}
      assert params["state"] == "open"
      assert params["per_page"] == "100"
    end

    test "fetch_issues_by_states uses state=all" do
      parent = self()
      ref = make_ref()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {ref, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([]))
      end

      Application.put_env(:raxol_symphony, :github, plug: plug)

      assert {:ok, []} = Tracker.fetch_issues_by_states(config(), ["Done"])

      assert_receive {^ref, params}
      assert params["state"] == "all"
    end
  end

  # -- Filtering by state labels ----------------------------------------------

  describe "state-label filtering" do
    test "fetch_candidate_issues keeps only issues whose state label matches active_states" do
      install_handler(fn _conn ->
        {:list,
         [
           issue_node(%{"number" => 1, "labels" => [%{"name" => "state/todo"}]}),
           issue_node(%{"number" => 2, "labels" => [%{"name" => "state/in-progress"}]}),
           issue_node(%{"number" => 3, "labels" => [%{"name" => "state/done"}]}),
           issue_node(%{"number" => 4, "labels" => [%{"name" => "bug"}]})
         ]}
      end)

      assert {:ok, issues} = Tracker.fetch_candidate_issues(config())
      assert Enum.map(issues, & &1.identifier) |> Enum.sort() == ["#1", "#2"]
    end

    test "preserves the original-case state name from active_states" do
      install_handler(fn _conn ->
        {:list,
         [
           issue_node(%{"labels" => [%{"name" => "state/in-progress"}]})
         ]}
      end)

      assert {:ok, [%Issue{state: "In Progress"}]} = Tracker.fetch_candidate_issues(config())
    end

    test "fetch_issues_by_states picks up closed issues with terminal-state labels" do
      install_handler(fn _conn ->
        {:list,
         [
           issue_node(%{
             "number" => 5,
             "state" => "closed",
             "labels" => [%{"name" => "state/done"}]
           })
         ]}
      end)

      assert {:ok, [%Issue{identifier: "#5", state: "Done"}]} =
               Tracker.fetch_issues_by_states(config(), ["Done"])
    end

    test "skips pull requests (issues with pull_request key)" do
      install_handler(fn _conn ->
        {:list,
         [
           issue_node(%{
             "number" => 9,
             "pull_request" => %{"url" => "https://api.github.com/owner/repo/pulls/9"}
           })
         ]}
      end)

      assert {:ok, []} = Tracker.fetch_candidate_issues(config())
    end
  end

  # -- Normalization ----------------------------------------------------------

  describe "normalization" do
    test "maps GitHub fields onto Issue struct" do
      install_handler(fn _conn ->
        {:list,
         [
           issue_node(%{
             "number" => 42,
             "title" => "fix the thing",
             "body" => "details",
             "labels" => [
               %{"name" => "state/todo"},
               %{"name" => "Bug"},
               %{"name" => "priority/2"}
             ]
           })
         ]}
      end)

      assert {:ok, [%Issue{} = issue]} = Tracker.fetch_candidate_issues(config())
      assert issue.id == "42"
      assert issue.identifier == "#42"
      assert issue.title == "fix the thing"
      assert issue.description == "details"
      assert issue.priority == 2
      assert issue.url == "https://github.com/owner/repo/issues/42"
      assert issue.state == "Todo"
      assert issue.labels == ["state/todo", "bug", "priority/2"]
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "tolerates missing optional fields" do
      install_handler(fn _conn ->
        {:list,
         [
           %{
             "number" => 7,
             "labels" => [%{"name" => "state/todo"}]
           }
         ]}
      end)

      assert {:ok, [%Issue{} = issue]} = Tracker.fetch_candidate_issues(config())
      assert issue.title == ""
      assert issue.description == nil
      assert issue.priority == nil
      assert issue.created_at == nil
    end
  end

  # -- Pagination -------------------------------------------------------------

  describe "pagination" do
    test "follows Link rel=next across pages" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        conn = Plug.Conn.fetch_query_params(conn)
        page = Map.get(conn.params, "page", "1")

        case page do
          "1" ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://api.github.com/repos/owner/repo/issues?page=2>; rel="next", <https://api.github.com/repos/owner/repo/issues?page=2>; rel="last")
            )
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!([issue_node(%{"number" => 1})])
            )

          "2" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!([issue_node(%{"number" => 2})])
            )
        end
      end

      Application.put_env(:raxol_symphony, :github, plug: plug)

      assert {:ok, issues} = Tracker.fetch_candidate_issues(config())
      assert :counters.get(counter, 1) == 2
      assert Enum.map(issues, & &1.identifier) |> Enum.sort() == ["#1", "#2"]
    end

    test "stops paginating when Link header lacks rel=next" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<https://api.github.com/repos/owner/repo/issues?page=1>; rel="prev")
        )
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([issue_node(%{})]))
      end

      Application.put_env(:raxol_symphony, :github, plug: plug)

      assert {:ok, _} = Tracker.fetch_candidate_issues(config())
      assert :counters.get(counter, 1) == 1
    end
  end

  # -- fetch_issue_states_by_ids ---------------------------------------------

  describe "fetch_issue_states_by_ids/2" do
    test "fetches each ID via the per-issue endpoint and returns ordered results" do
      install_handler(fn conn ->
        case conn.request_path do
          "/repos/owner/repo/issues/1" ->
            {:list, issue_node(%{"number" => 1, "labels" => [%{"name" => "state/todo"}]})}

          "/repos/owner/repo/issues/2" ->
            {:list,
             issue_node(%{
               "number" => 2,
               "state" => "closed",
               "labels" => [%{"name" => "state/done"}]
             })}
        end
      end)

      assert {:ok, issues} = Tracker.fetch_issue_states_by_ids(config(), ["1", "2"])
      assert Enum.map(issues, & &1.identifier) == ["#1", "#2"]
      assert Enum.map(issues, & &1.state) == ["Todo", "Done"]
    end

    test "skips IDs that 404 without erroring the whole batch" do
      install_handler(fn conn ->
        case conn.request_path do
          "/repos/owner/repo/issues/1" ->
            {:list, issue_node(%{"number" => 1})}

          _ ->
            {:status, 404, %{"message" => "Not Found"}}
        end
      end)

      assert {:ok, [%Issue{identifier: "#1"}]} =
               Tracker.fetch_issue_states_by_ids(config(), ["1", "999"])
    end
  end

  # -- Errors -----------------------------------------------------------------

  describe "errors" do
    test "non-200 list status surfaces :github_api_status" do
      install_handler(fn _conn -> {:status, 503, %{}} end)

      assert {:error, {:github_api_status, 503}} = Tracker.fetch_candidate_issues(config())
    end

    test "non-list 200 body surfaces :github_unknown_payload" do
      install_handler(fn _conn -> {:status, 200, %{"message" => "scalar"}} end)

      assert {:error, :github_unknown_payload} = Tracker.fetch_candidate_issues(config())
    end

    test "transport failure surfaces {:github_api_request, _}" do
      adapter = fn req -> {req, %Req.TransportError{reason: :nxdomain}} end
      Application.put_env(:raxol_symphony, :github, adapter: adapter)

      assert {:error, {:github_api_request, %Req.TransportError{reason: :nxdomain}}} =
               Tracker.fetch_candidate_issues(config())
    end
  end
end
