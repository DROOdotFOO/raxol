defmodule Raxol.Symphony.Trackers.Linear do
  @moduledoc """
  Linear GraphQL tracker adapter (SPEC s11).

  Talks to the Linear GraphQL API at the URL configured in
  `tracker.endpoint` (defaults to `https://api.linear.app/graphql`). The API
  key from `tracker.api_key` is sent in the `Authorization` header verbatim,
  matching Linear's documented personal-API-key flow (no `Bearer ` prefix).

  ## Filters

  - `fetch_candidate_issues/1` -- issues whose state name is in
    `tracker.active_states` for `tracker.project_slug`.
  - `fetch_issues_by_states/2` -- issues whose state name is in `state_names`
    for `tracker.project_slug`.
  - `fetch_issue_states_by_ids/2` -- issues whose internal `id` is in `ids`
    (no project filter, since IDs are globally unique within a workspace).

  ## Pagination

  Relay-style cursor pagination via `pageInfo.{hasNextPage,endCursor}`. Up
  to 50 nodes per page, capped at 20 pages per call to bound runaway loops
  (returns `{:error, :linear_pagination_exhausted}` on overrun).

  ## Errors (SPEC s11.4)

  - `:missing_tracker_api_key`
  - `:missing_tracker_project_slug`
  - `{:linear_api_request, term}`
  - `{:linear_api_status, integer}`
  - `{:linear_graphql_errors, list}`
  - `:linear_unknown_payload`
  - `:linear_missing_end_cursor`
  - `:linear_pagination_exhausted`

  ## Test injection

  The HTTP transport is a `Req` client. Tests inject a `Plug` stub via
  application config:

      config :raxol_symphony, linear: [plug: my_plug]

  No live network is required to exercise this module.
  """

  @behaviour Raxol.Symphony.Tracker

  alias Raxol.Symphony.{Config, Issue}

  @max_pages 20
  @page_size 50

  @impl true
  def fetch_candidate_issues(%Config{tracker: tracker} = _config) do
    with :ok <- validate(tracker, project_required: true) do
      filter = %{
        "project" => %{"slugId" => %{"eq" => tracker.project_slug}},
        "state" => %{"name" => %{"in" => tracker.active_states}}
      }

      paginate(tracker, filter)
    end
  end

  @impl true
  def fetch_issues_by_states(%Config{tracker: tracker} = _config, state_names)
      when is_list(state_names) do
    with :ok <- validate(tracker, project_required: true) do
      filter = %{
        "project" => %{"slugId" => %{"eq" => tracker.project_slug}},
        "state" => %{"name" => %{"in" => state_names}}
      }

      paginate(tracker, filter)
    end
  end

  @impl true
  def fetch_issue_states_by_ids(%Config{tracker: tracker} = _config, ids) when is_list(ids) do
    with :ok <- validate(tracker, project_required: false) do
      filter = %{"id" => %{"in" => ids}}
      paginate(tracker, filter)
    end
  end

  # -- Validation -------------------------------------------------------------

  defp validate(tracker, opts) do
    cond do
      blank?(tracker.api_key) ->
        {:error, :missing_tracker_api_key}

      Keyword.get(opts, :project_required, false) and blank?(tracker.project_slug) ->
        {:error, :missing_tracker_project_slug}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # -- Pagination -------------------------------------------------------------

  defp paginate(tracker, filter), do: do_paginate(tracker, filter, nil, [], 0)

  defp do_paginate(_tracker, _filter, _cursor, _acc, page) when page >= @max_pages do
    {:error, :linear_pagination_exhausted}
  end

  defp do_paginate(tracker, filter, cursor, acc, page) do
    variables = %{"filter" => filter, "first" => @page_size, "after" => cursor}

    case post_graphql(tracker, issues_query(), variables) do
      {:ok, %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}} when is_list(nodes) ->
        next_acc = acc ++ Enum.map(nodes, &normalize_issue/1)
        advance(tracker, filter, page_info, next_acc, page)

      {:ok, _other} ->
        {:error, :linear_unknown_payload}

      {:error, _} = err ->
        err
    end
  end

  defp advance(tracker, filter, %{"hasNextPage" => true, "endCursor" => cursor}, acc, page)
       when is_binary(cursor) do
    do_paginate(tracker, filter, cursor, acc, page + 1)
  end

  defp advance(_tracker, _filter, %{"hasNextPage" => true, "endCursor" => _}, _acc, _page) do
    {:error, :linear_missing_end_cursor}
  end

  defp advance(_tracker, _filter, _page_info, acc, _page), do: {:ok, acc}

  # -- Transport --------------------------------------------------------------

  defp post_graphql(tracker, query, variables) do
    body = %{query: query, variables: variables}

    case Req.post(client(tracker), json: body) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        decode_body(response_body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:linear_api_status, status}}

      {:error, reason} ->
        {:error, {:linear_api_request, reason}}
    end
  end

  defp decode_body(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_body(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp decode_body(_), do: {:error, :linear_unknown_payload}

  defp client(tracker) do
    extra = Application.get_env(:raxol_symphony, :linear, [])
    plug = Keyword.get(extra, :plug)
    adapter = Keyword.get(extra, :adapter)
    receive_timeout = Keyword.get(extra, :receive_timeout, 15_000)

    base = [
      url: tracker.endpoint,
      headers: [
        {"content-type", "application/json"},
        {"authorization", tracker.api_key}
      ],
      receive_timeout: receive_timeout
    ]

    base = if plug, do: Keyword.put(base, :plug, plug), else: base
    base = if adapter, do: Keyword.put(base, :adapter, adapter), else: base

    Req.new(base)
  end

  # -- GraphQL document -------------------------------------------------------

  defp issues_query do
    """
    query Issues($filter: IssueFilter, $first: Int, $after: String) {
      issues(filter: $filter, first: $first, after: $after, orderBy: createdAt) {
        nodes {
          id
          identifier
          title
          description
          priority
          branchName
          url
          createdAt
          updatedAt
          state { name }
          labels { nodes { name } }
          inverseRelations {
            nodes {
              type
              issue { id identifier state { name } }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  # -- Normalization ----------------------------------------------------------

  defp normalize_issue(node) do
    %Issue{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"] || "",
      description: node["description"],
      priority: node["priority"],
      branch_name: node["branchName"],
      url: node["url"],
      state: get_in(node, ["state", "name"]) || "",
      labels: extract_labels(node),
      blocked_by: extract_blockers(node),
      created_at: parse_iso8601(node["createdAt"]),
      updated_at: parse_iso8601(node["updatedAt"])
    }
  end

  defp extract_labels(node) do
    node
    |> get_in(["labels", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      _ -> []
    end)
  end

  defp extract_blockers(node) do
    node
    |> get_in(["inverseRelations", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "blocks", "issue" => issue} when is_map(issue) ->
        [
          %Issue.Blocker{
            id: issue["id"],
            identifier: issue["identifier"],
            state: get_in(issue, ["state", "name"])
          }
        ]

      _ ->
        []
    end)
  end

  defp parse_iso8601(nil), do: nil
  defp parse_iso8601(""), do: nil

  defp parse_iso8601(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
