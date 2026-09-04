defmodule Raxol.Symphony.Trackers.GitHub do
  @moduledoc """
  GitHub Issues tracker adapter (SPEC s11 extension).

  GitHub's native open/closed states are not granular enough for Symphony
  workflows, so this adapter uses the convention of `state/<name>` labels:
  e.g. `state/todo`, `state/in-progress`, `state/human-review`,
  `state/done`. The configured `active_states` and `terminal_states` are
  matched against label slugs case-insensitively, with spaces normalized
  to dashes (`"In Progress" <-> "state/in-progress"`). The `state/` prefix
  is matched case-insensitively too, so `STATE/todo` and `State/Todo` are
  the same label; `stateful` and `state-todo` are not state labels at all.

  ## Configuration

  - `tracker.endpoint` -- API base URL (defaults to `https://api.github.com`)
  - `tracker.api_key` -- GitHub PAT or fine-grained token (`$GITHUB_TOKEN`);
    sent as `Authorization: Bearer <key>`
  - `tracker.project_slug` -- `"owner/repo"` (REQUIRED)
  - `tracker.active_states` -- state names (e.g. `["Todo", "In Progress"]`)
    that map to `state/<slug>` labels
  - `tracker.terminal_states` -- handoff state names

  ## Filters

  - `fetch_candidate_issues/1` -- fetches open issues, filters to those with
    a matching state label.
  - `fetch_issues_by_states/2` -- fetches with `state=all` so closed issues
    in terminal states are reachable, then filters by label.
  - `fetch_issue_states_by_ids/2` -- fetches each ID via the per-issue
    endpoint in parallel (concurrency 5). An ID that answers 404/410 is
    omitted from the result, because that is knowledge: the issue is deleted,
    transferred, or invisible to this token. Any OTHER per-ID failure fails
    the whole call, because callers read a short list as "this issue is gone"
    and act on it destructively -- `Orchestrator.retry_with_fresh_state/3`
    releases the issue, and the runners' `still_active?/2` ends the run.

  ## Pagination

  Follows the `Link: <...>; rel="next"` header up to 20 pages per call,
  then returns `{:error, :github_pagination_exhausted}`.

  ## Errors

  - `:missing_tracker_api_key`
  - `:missing_tracker_project_slug`
  - `{:invalid_github_repo, slug}` -- `project_slug` not in `owner/repo` form
  - `{:github_api_request, term}`
  - `{:github_api_status, integer}`
  - `:github_unknown_payload`
  - `:github_pagination_exhausted`

  ## Test injection

  Inject a `Plug` stub via app config (mirrors `Trackers.Linear`):

      config :raxol_symphony, github: [plug: my_plug]

  Or inject a custom adapter for transport-error simulation:

      config :raxol_symphony, github: [adapter: my_adapter]
  """

  @behaviour Raxol.Symphony.Tracker

  import Raxol.Symphony.Util, only: [blank?: 1]

  alias Raxol.Symphony.{Config, Issue}

  @max_pages 20
  @page_size 100
  @default_endpoint "https://api.github.com"
  @max_id_concurrency 5
  @default_receive_timeout 15_000
  @id_fetch_grace 5_000

  @impl true
  def fetch_candidate_issues(%Config{tracker: tracker} = _config) do
    with :ok <- validate(tracker) do
      case list_issues(tracker, "open") do
        {:ok, issues} -> {:ok, filter_by_states(issues, tracker.active_states, tracker)}
        err -> err
      end
    end
  end

  @impl true
  def fetch_issues_by_states(%Config{tracker: tracker} = _config, state_names)
      when is_list(state_names) do
    with :ok <- validate(tracker) do
      case list_issues(tracker, "all") do
        {:ok, issues} -> {:ok, filter_by_states(issues, state_names, tracker)}
        err -> err
      end
    end
  end

  @impl true
  def fetch_issue_states_by_ids(%Config{tracker: tracker} = _config, ids) when is_list(ids) do
    with :ok <- validate(tracker) do
      ids
      |> Task.async_stream(
        fn id -> fetch_one(tracker, id) end,
        max_concurrency: @max_id_concurrency,
        timeout: id_fetch_timeout(),
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.reduce_while({:ok, []}, &collect_one/2)
      |> case do
        {:ok, acc} ->
          {:ok, acc |> Enum.reverse() |> Enum.map(&assign_state_name(&1, tracker))}

        {:error, _reason} = err ->
          err
      end
    end
  end

  # An absent issue and an unreachable API must not reach the caller looking
  # the same. `Orchestrator.retry_with_fresh_state/3` releases the issue on
  # `{:ok, []}` and requeues the retry on `{:error, _}`; the runners'
  # `still_active?/2` ends the run on `{:ok, []}`. Folding a 500 into an empty
  # list therefore picked the destructive branch of both on a transient blip,
  # and left those `{:error, _}` clauses unreachable on this tracker.
  # `Trackers.Linear` already propagates transport failures, so this is also
  # what stops the two disagreeing about what silence means.
  defp collect_one({:ok, {:ok, issue}}, {:ok, acc}),
    do: {:cont, {:ok, [issue | acc]}}

  defp collect_one({:ok, :gone}, {:ok, acc}), do: {:cont, {:ok, acc}}

  defp collect_one({:ok, {:error, reason}}, _acc), do: {:halt, {:error, reason}}

  defp collect_one({:exit, reason}, _acc),
    do: {:halt, {:error, {:github_api_request, reason}}}

  # -- Validation -------------------------------------------------------------

  defp validate(tracker) do
    cond do
      blank?(tracker.api_key) ->
        {:error, :missing_tracker_api_key}

      blank?(tracker.project_slug) ->
        {:error, :missing_tracker_project_slug}

      not valid_repo?(tracker.project_slug) ->
        {:error, {:invalid_github_repo, tracker.project_slug}}

      true ->
        :ok
    end
  end

  defp valid_repo?(slug) when is_binary(slug) do
    case String.split(slug, "/") do
      [owner, repo] when byte_size(owner) > 0 and byte_size(repo) > 0 -> true
      _ -> false
    end
  end

  # -- List + paginate --------------------------------------------------------

  defp list_issues(tracker, state) do
    base_path = "/repos/#{tracker.project_slug}/issues"

    initial_params = [
      {"state", state},
      {"per_page", Integer.to_string(@page_size)},
      # GitHub returns PRs alongside issues; this filter is server-side via
      # the `pulls` endpoint splitting, but we double-check by skipping
      # pull_request entries during normalization.
      {"page", "1"}
    ]

    do_paginate(tracker, base_path, initial_params, [], 0)
  end

  defp do_paginate(_tracker, _path, _params, _acc, page) when page >= @max_pages do
    {:error, :github_pagination_exhausted}
  end

  defp do_paginate(tracker, path, params, acc, page) do
    request_params = put_page(params, page + 1)

    tracker
    |> client()
    |> Req.get(url: path, params: request_params)
    |> handle_page_response(tracker, path, params, acc, page)
  end

  defp handle_page_response(
         {:ok, %Req.Response{status: 200, body: body, headers: headers}},
         tracker,
         path,
         params,
         acc,
         page
       )
       when is_list(body) do
    next_acc = acc ++ Enum.flat_map(body, &normalize_or_skip/1)

    if has_next_page?(headers) do
      do_paginate(tracker, path, params, next_acc, page + 1)
    else
      {:ok, next_acc}
    end
  end

  defp handle_page_response({:ok, %Req.Response{status: 200}}, _, _, _, _, _),
    do: {:error, :github_unknown_payload}

  defp handle_page_response({:ok, %Req.Response{status: status}}, _, _, _, _, _),
    do: {:error, {:github_api_status, status}}

  defp handle_page_response({:error, reason}, _, _, _, _, _),
    do: {:error, {:github_api_request, reason}}

  defp put_page(params, page_no) do
    [{"page", Integer.to_string(page_no)} | Enum.reject(params, fn {k, _} -> k == "page" end)]
  end

  defp fetch_one(tracker, id) do
    tracker
    |> client()
    |> Req.get(url: "/repos/#{tracker.project_slug}/issues/#{id}")
    |> classify_one()
  end

  defp classify_one({:ok, %Req.Response{status: 200, body: body}}) when is_map(body) do
    # A 200 that normalizes away is a pull request, which is not an issue this
    # tracker owns: absent rather than broken.
    case normalize_or_skip(body) do
      [issue] -> {:ok, issue}
      _ -> :gone
    end
  end

  defp classify_one({:ok, %Req.Response{status: 200}}),
    do: {:error, :github_unknown_payload}

  # The only two statuses that are knowledge rather than a failure to acquire
  # it: 404 covers deleted, transferred, and not-visible-to-this-token; 410 is
  # GitHub's answer for an issue deleted outright.
  defp classify_one({:ok, %Req.Response{status: status}}) when status in [404, 410],
    do: :gone

  defp classify_one({:ok, %Req.Response{status: status}}),
    do: {:error, {:github_api_status, status}}

  defp classify_one({:error, reason}), do: {:error, {:github_api_request, reason}}

  # The stream timeout has to sit ABOVE the HTTP receive timeout. At a fixed
  # 10s against a 15s default it was the stream that killed a merely-slow
  # request, so the configured `receive_timeout` never applied on this path and
  # raising it did nothing.
  defp id_fetch_timeout, do: receive_timeout() + @id_fetch_grace

  defp receive_timeout do
    :raxol_symphony
    |> Application.get_env(:github, [])
    |> Keyword.get(:receive_timeout, @default_receive_timeout)
  end

  # -- Header parsing ---------------------------------------------------------

  defp has_next_page?(headers) do
    Enum.any?(headers, &link_header_has_next?/1)
  end

  defp link_header_has_next?({key, value}) when is_binary(key) and is_binary(value) do
    String.downcase(key) == "link" and contains_rel_next?(value)
  end

  defp link_header_has_next?({key, values}) when is_binary(key) and is_list(values) do
    String.downcase(key) == "link" and Enum.any?(values, &contains_rel_next?/1)
  end

  defp link_header_has_next?(_), do: false

  defp contains_rel_next?(value) when is_binary(value),
    do: String.contains?(value, ~s(rel="next"))

  defp contains_rel_next?(_), do: false

  # -- Filtering --------------------------------------------------------------

  defp filter_by_states(issues, state_names, tracker) do
    needles = MapSet.new(state_names, &slugify_state/1)

    issues
    |> Enum.map(&assign_state_name(&1, tracker))
    |> Enum.filter(fn issue ->
      issue.state != "" and MapSet.member?(needles, slugify_state(issue.state))
    end)
  end

  # Replace the slug-derived state name with the configured original-case
  # name when it matches; this lets downstream code do case-sensitive
  # comparisons against `active_states`/`terminal_states` strings.
  defp assign_state_name(%Issue{state: ""} = issue, _tracker), do: issue

  defp assign_state_name(%Issue{state: state} = issue, tracker) do
    lookup = state_lookup(tracker)
    canonical = Map.get(lookup, slugify_state(state), state)
    %Issue{issue | state: canonical}
  end

  defp state_lookup(tracker) do
    (tracker.active_states ++ tracker.terminal_states)
    |> Enum.uniq()
    |> Map.new(fn name -> {slugify_state(name), name} end)
  end

  defp slugify_state(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  defp slugify_state(_), do: ""

  # -- Normalization ----------------------------------------------------------

  # GitHub's /issues endpoint returns pull requests too -- skip those, they
  # have a top-level `pull_request` key.
  defp normalize_or_skip(%{"pull_request" => pr}) when not is_nil(pr), do: []

  defp normalize_or_skip(node) when is_map(node) do
    raw_labels = extract_label_names(node["labels"])
    [build_issue(node, raw_labels)]
  end

  defp normalize_or_skip(_), do: []

  defp build_issue(node, raw_labels) do
    labels = Enum.map(raw_labels, &String.downcase/1)

    %Issue{
      id: to_string(node["number"] || ""),
      identifier: identifier_for(node),
      title: node["title"] || "",
      description: node["body"],
      priority: priority_from_labels(labels),
      url: node["html_url"],
      state: extract_state(raw_labels),
      labels: labels,
      created_at: parse_iso8601(node["created_at"]),
      updated_at: parse_iso8601(node["updated_at"])
    }
  end

  defp identifier_for(%{"number" => n}) when is_integer(n), do: "##{n}"
  defp identifier_for(%{"number" => n}) when is_binary(n), do: "##{n}"
  defp identifier_for(_), do: "#?"

  defp extract_label_names(nil), do: []

  defp extract_label_names(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp extract_label_names(_), do: []

  defp extract_state(labels), do: Enum.find_value(labels, "", &state_slug/1)

  # `state/<slug>`, with the prefix matched case-insensitively. The suffix
  # already was (`slugify_state/1` downcases it), but the prefix was two
  # hand-written spellings, so a repo labelling its issues `STATE/todo` had
  # every issue read as stateless: the orchestrator polled a correctly
  # labelled repo forever, claimed nothing, and raised no error saying why.
  #
  # Split rather than prefix-matched so `stateful` and `state-todo` stay what
  # they are -- ordinary labels, not a state named `ful`.
  defp state_slug(label) when is_binary(label) do
    case String.split(label, "/", parts: 2) do
      [prefix, rest] when rest != "" ->
        if String.downcase(prefix) == "state", do: rest

      _ ->
        nil
    end
  end

  defp state_slug(_), do: nil

  defp priority_from_labels(labels) do
    labels
    |> Enum.find_value(fn
      "priority/" <> rest ->
        case Integer.parse(rest) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
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

  # -- Transport --------------------------------------------------------------

  defp client(tracker) do
    extra = Application.get_env(:raxol_symphony, :github, [])
    plug = Keyword.get(extra, :plug)
    adapter = Keyword.get(extra, :adapter)
    receive_timeout = Keyword.get(extra, :receive_timeout, @default_receive_timeout)
    base_url = tracker.endpoint || @default_endpoint

    Raxol.Symphony.GitHub.Client.build(
      base_url,
      tracker.api_key,
      plug,
      adapter,
      receive_timeout
    )
  end
end
