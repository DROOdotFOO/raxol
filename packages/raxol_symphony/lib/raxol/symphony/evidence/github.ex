defmodule Raxol.Symphony.Evidence.GitHub do
  @moduledoc """
  GitHub-backed evidence collector.

  Populates two fields on the `Evidence` struct:

  - `:ci`          -- latest workflow run for the subject's `:ref`
  - `:pr_comments` -- recent issue/PR comments when `:issue_number` is set

  ## Auth

  When the tracker is `github`, reuses `tracker.api_key`. Otherwise
  resolves `$GITHUB_TOKEN` via `Config.resolve_value/1`. With no token,
  records `:no_token` in `errors[:github]` and returns the struct unchanged.

  ## Test injection

      config :raxol_symphony, evidence_github: [plug: my_plug]
  """

  @behaviour Raxol.Symphony.Evidence.Backend

  require Logger

  alias Raxol.Symphony.{Config, Evidence}

  @default_endpoint "https://api.github.com"
  @default_pr_comment_limit 20

  @compile {:no_warn_undefined, Req}
  @compile {:no_warn_undefined, Req.Response}

  @impl true
  @spec collect(Evidence.t(), Config.t(), keyword()) :: Evidence.t()
  def collect(%Evidence{} = evidence, %Config{} = config, opts) do
    cond do
      not req_loaded?() ->
        Evidence.put_error(evidence, :github, :req_not_loaded)

      is_nil(evidence.repo) ->
        Evidence.put_error(evidence, :github, :no_repo)

      true ->
        case resolve_token(config) do
          nil -> Evidence.put_error(evidence, :github, :no_token)
          token -> do_collect(evidence, token, opts)
        end
    end
  end

  defp do_collect(evidence, token, opts) do
    client = build_client(token, opts)

    evidence
    |> fetch_ci(client)
    |> fetch_pr_comments(client, opts)
  end

  # ---------------------------------------------------------------------------
  # CI status
  # ---------------------------------------------------------------------------

  defp fetch_ci(%Evidence{ref: nil} = evidence, _client), do: evidence

  defp fetch_ci(%Evidence{repo: repo, ref: ref} = evidence, client) do
    path = "/repos/#{repo}/actions/runs"

    case Req.get(client, url: path, params: [branch: ref, per_page: 1]) do
      {:ok, %Req.Response{status: 200, body: %{"workflow_runs" => [run | _]}}} ->
        %Evidence{evidence | ci: normalize_workflow_run(run)}

      {:ok, %Req.Response{status: 200, body: %{"workflow_runs" => []}}} ->
        %Evidence{evidence | ci: %{status: :no_runs, ref: ref}}

      {:ok, %Req.Response{status: status}} ->
        Evidence.put_error(evidence, :github_ci, {:status, status})

      {:error, reason} ->
        Evidence.put_error(evidence, :github_ci, reason)
    end
  end

  defp normalize_workflow_run(run) do
    %{
      id: run["id"],
      name: run["name"],
      status: run["status"],
      conclusion: run["conclusion"],
      head_branch: run["head_branch"],
      head_sha: run["head_sha"],
      run_number: run["run_number"],
      url: run["html_url"],
      created_at: run["created_at"],
      updated_at: run["updated_at"]
    }
  end

  # ---------------------------------------------------------------------------
  # PR / issue comments
  # ---------------------------------------------------------------------------

  defp fetch_pr_comments(%Evidence{issue_number: nil} = evidence, _client, _opts), do: evidence

  defp fetch_pr_comments(%Evidence{repo: repo, issue_number: number} = evidence, client, opts) do
    limit = Keyword.get(opts, :pr_comment_limit, @default_pr_comment_limit)
    path = "/repos/#{repo}/issues/#{number}/comments"

    case Req.get(client, url: path, params: [per_page: limit]) do
      {:ok, %Req.Response{status: 200, body: comments}} when is_list(comments) ->
        %Evidence{evidence | pr_comments: Enum.map(comments, &normalize_comment/1)}

      {:ok, %Req.Response{status: status}} ->
        Evidence.put_error(evidence, :github_pr_comments, {:status, status})

      {:error, reason} ->
        Evidence.put_error(evidence, :github_pr_comments, reason)
    end
  end

  defp normalize_comment(comment) do
    %{
      id: comment["id"],
      author: get_in(comment, ["user", "login"]),
      body: comment["body"],
      created_at: comment["created_at"],
      updated_at: comment["updated_at"],
      url: comment["html_url"]
    }
  end

  # ---------------------------------------------------------------------------
  # Auth + transport
  # ---------------------------------------------------------------------------

  defp resolve_token(%Config{tracker: %{kind: "github", api_key: token}})
       when is_binary(token) and byte_size(token) > 0,
       do: token

  defp resolve_token(_config) do
    case Config.resolve_value("$GITHUB_TOKEN") do
      token when is_binary(token) and byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp build_client(token, opts) do
    extra = Application.get_env(:raxol_symphony, :evidence_github, [])
    plug = Keyword.get(opts, :plug) || Keyword.get(extra, :plug)
    adapter = Keyword.get(opts, :adapter) || Keyword.get(extra, :adapter)
    receive_timeout = Keyword.get(extra, :receive_timeout, 15_000)
    base_url = Keyword.get(opts, :endpoint, @default_endpoint)

    base = [
      base_url: base_url,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer #{token}"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "raxol-symphony"}
      ],
      receive_timeout: receive_timeout,
      retry: false
    ]

    base = if plug, do: Keyword.put(base, :plug, plug), else: base
    base = if adapter, do: Keyword.put(base, :adapter, adapter), else: base

    Req.new(base)
  end

  defp req_loaded?, do: Code.ensure_loaded?(Req)
end
