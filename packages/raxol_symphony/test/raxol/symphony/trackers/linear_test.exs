defmodule Raxol.Symphony.Trackers.LinearTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Tracker}

  setup do
    on_exit(fn -> Application.delete_env(:raxol_symphony, :linear) end)
    :ok
  end

  defp config(overrides \\ []) do
    tracker =
      Map.merge(
        %{
          kind: "linear",
          api_key: "lin_api_test",
          project_slug: "demo",
          active_states: ["Todo", "In Progress"]
        },
        Map.new(overrides)
      )

    Config.from_workflow(%{config: %{tracker: tracker}, prompt_template: ""})
  end

  defp install_stub(handler) when is_function(handler, 1) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      case handler.(decoded) do
        {:status, status, payload} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(payload))

        {:status, status} ->
          Plug.Conn.send_resp(conn, status, "")

        payload when is_map(payload) ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(payload))
      end
    end

    Application.put_env(:raxol_symphony, :linear, plug: plug)
  end

  defp issue_node(overrides) do
    Map.merge(
      %{
        "id" => "iss_1",
        "identifier" => "MT-1",
        "title" => "Hello",
        "description" => nil,
        "priority" => 2,
        "branchName" => "mt-1-hello",
        "url" => "https://linear.app/demo/issue/MT-1",
        "createdAt" => "2026-05-01T12:00:00Z",
        "updatedAt" => "2026-05-02T12:00:00Z",
        "state" => %{"name" => "Todo"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      },
      overrides
    )
  end

  defp ok_payload(nodes, page_info \\ %{"hasNextPage" => false, "endCursor" => nil}) do
    %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}
  end

  # -- Validation -------------------------------------------------------------

  describe "validation" do
    test "missing api_key surfaces :missing_tracker_api_key" do
      cfg = config(api_key: nil)
      assert {:error, :missing_tracker_api_key} = Tracker.fetch_candidate_issues(cfg)
    end

    test "blank api_key surfaces :missing_tracker_api_key" do
      cfg = config(api_key: "   ")
      assert {:error, :missing_tracker_api_key} = Tracker.fetch_candidate_issues(cfg)
    end

    test "missing project_slug surfaces :missing_tracker_project_slug for candidates" do
      cfg = config(project_slug: nil)
      assert {:error, :missing_tracker_project_slug} = Tracker.fetch_candidate_issues(cfg)
    end

    test "fetch_issue_states_by_ids does not require project_slug" do
      cfg = config(project_slug: nil)
      install_stub(fn _ -> ok_payload([]) end)

      assert {:ok, []} = Tracker.fetch_issue_states_by_ids(cfg, ["iss_1"])
    end
  end

  # -- Request shape ----------------------------------------------------------

  describe "request shape" do
    test "sends authorization header verbatim and JSON content-type" do
      ref = make_ref()
      parent = self()

      plug = fn conn ->
        send(parent, {ref, :headers, conn.req_headers})
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {ref, :body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_payload([])))
      end

      Application.put_env(:raxol_symphony, :linear, plug: plug)

      assert {:ok, []} = Tracker.fetch_candidate_issues(config())

      assert_receive {^ref, :headers, headers}
      assert {"authorization", "lin_api_test"} in headers
      assert {"content-type", "application/json"} in headers

      assert_receive {^ref, :body, body}
      assert is_binary(body["query"])
      variables = body["variables"]
      assert variables["filter"]["project"]["slugId"]["eq"] == "demo"
      assert variables["filter"]["state"]["name"]["in"] == ["Todo", "In Progress"]
      assert variables["first"] == 50
      assert variables["after"] == nil
    end

    test "fetch_issues_by_states uses the given state list, not active_states" do
      parent = self()
      ref = make_ref()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_payload([])))
      end

      Application.put_env(:raxol_symphony, :linear, plug: plug)

      assert {:ok, []} = Tracker.fetch_issues_by_states(config(), ["Done", "Cancelled"])

      assert_receive {^ref, body}
      assert body["variables"]["filter"]["state"]["name"]["in"] == ["Done", "Cancelled"]
    end

    test "fetch_issue_states_by_ids filters by id only" do
      parent = self()
      ref = make_ref()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {ref, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_payload([])))
      end

      Application.put_env(:raxol_symphony, :linear, plug: plug)

      assert {:ok, []} = Tracker.fetch_issue_states_by_ids(config(), ["iss_a", "iss_b"])

      assert_receive {^ref, body}
      assert body["variables"]["filter"] == %{"id" => %{"in" => ["iss_a", "iss_b"]}}
    end
  end

  # -- Normalization ----------------------------------------------------------

  describe "normalization" do
    test "maps GraphQL fields onto Issue struct" do
      install_stub(fn _ ->
        ok_payload([
          issue_node(%{
            "labels" => %{"nodes" => [%{"name" => "Bug"}, %{"name" => "P1"}]}
          })
        ])
      end)

      assert {:ok, [%Issue{} = issue]} = Tracker.fetch_candidate_issues(config())
      assert issue.id == "iss_1"
      assert issue.identifier == "MT-1"
      assert issue.title == "Hello"
      assert issue.priority == 2
      assert issue.branch_name == "mt-1-hello"
      assert issue.url == "https://linear.app/demo/issue/MT-1"
      assert issue.state == "Todo"
      assert issue.labels == ["bug", "p1"]
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "extracts blockers from inverseRelations with type=blocks" do
      install_stub(fn _ ->
        ok_payload([
          issue_node(%{
            "inverseRelations" => %{
              "nodes" => [
                %{
                  "type" => "blocks",
                  "issue" => %{
                    "id" => "iss_2",
                    "identifier" => "MT-2",
                    "state" => %{"name" => "In Progress"}
                  }
                },
                %{
                  "type" => "duplicate",
                  "issue" => %{"id" => "iss_3", "identifier" => "MT-3", "state" => nil}
                }
              ]
            }
          })
        ])
      end)

      assert {:ok, [%Issue{blocked_by: [blocker]}]} = Tracker.fetch_candidate_issues(config())
      assert blocker.id == "iss_2"
      assert blocker.identifier == "MT-2"
      assert blocker.state == "In Progress"
    end

    test "tolerates nil/missing optional fields" do
      install_stub(fn _ ->
        ok_payload([
          %{
            "id" => "iss_min",
            "identifier" => "MT-X",
            "title" => nil,
            "state" => %{"name" => "Todo"},
            "labels" => nil,
            "inverseRelations" => nil,
            "createdAt" => nil,
            "updatedAt" => "not-a-date"
          }
        ])
      end)

      assert {:ok, [%Issue{} = issue]} = Tracker.fetch_candidate_issues(config())
      assert issue.title == ""
      assert issue.labels == []
      assert issue.blocked_by == []
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end
  end

  # -- Pagination -------------------------------------------------------------

  describe "pagination" do
    test "follows endCursor across pages and concatenates results" do
      counter = :counters.new(1, [])

      install_stub(fn body ->
        :counters.add(counter, 1, 1)

        case body["variables"]["after"] do
          nil ->
            ok_payload(
              [issue_node(%{"id" => "p1a", "identifier" => "MT-1"})],
              %{"hasNextPage" => true, "endCursor" => "cur1"}
            )

          "cur1" ->
            ok_payload(
              [issue_node(%{"id" => "p2a", "identifier" => "MT-2"})],
              %{"hasNextPage" => false, "endCursor" => nil}
            )
        end
      end)

      assert {:ok, issues} = Tracker.fetch_candidate_issues(config())
      assert :counters.get(counter, 1) == 2
      assert Enum.map(issues, & &1.identifier) == ["MT-1", "MT-2"]
    end

    test "errors when hasNextPage is true but endCursor is missing" do
      install_stub(fn _ ->
        ok_payload([issue_node(%{})], %{"hasNextPage" => true, "endCursor" => nil})
      end)

      assert {:error, :linear_missing_end_cursor} = Tracker.fetch_candidate_issues(config())
    end
  end

  # -- Errors -----------------------------------------------------------------

  describe "errors" do
    test "non-200 status surfaces :linear_api_status" do
      install_stub(fn _ -> {:status, 503, %{"message" => "boom"}} end)

      assert {:error, {:linear_api_status, 503}} = Tracker.fetch_candidate_issues(config())
    end

    test "GraphQL errors surface :linear_graphql_errors" do
      install_stub(fn _ ->
        %{
          "errors" => [
            %{"message" => "Project not found", "extensions" => %{"code" => "FORBIDDEN"}}
          ]
        }
      end)

      assert {:error, {:linear_graphql_errors, [err | _]}} =
               Tracker.fetch_candidate_issues(config())

      assert err["message"] == "Project not found"
    end

    test "GraphQL errors take precedence over partial data" do
      install_stub(fn _ ->
        %{
          "data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}},
          "errors" => [%{"message" => "Throttled"}]
        }
      end)

      assert {:error, {:linear_graphql_errors, _}} = Tracker.fetch_candidate_issues(config())
    end

    test "missing data surfaces :linear_unknown_payload" do
      install_stub(fn _ -> %{"weird" => "shape"} end)

      assert {:error, :linear_unknown_payload} = Tracker.fetch_candidate_issues(config())
    end

    test "transport failure surfaces {:linear_api_request, _}" do
      adapter = fn req ->
        {req, %Req.TransportError{reason: :econnrefused}}
      end

      Application.put_env(:raxol_symphony, :linear, adapter: adapter)

      assert {:error, {:linear_api_request, %Req.TransportError{reason: :econnrefused}}} =
               Tracker.fetch_candidate_issues(config())
    end
  end
end
