defmodule Raxol.Earn.JobApi.HTTP do
  @moduledoc """
  Real `Raxol.Earn.JobApi` implementation against the Virtuals ACP REST
  API.

  ## Endpoints

  | Method | Path | Used for |
  |---|---|---|
  | GET  | `/jobs`                                       | `get_active_jobs/1` |
  | GET  | `/jobs/{chainId}/{jobId}`                     | (single job lookup) |
  | POST | `/jobs/{chainId}/{jobId}/deliverable`         | `post_deliverable/4` |
  | GET  | `/agents/search?query=&chainIds=`             | `browse_agents/3` |
  | GET  | `/agents/wallet/{walletAddress}`              | `get_agent_by_wallet_address/2`, `get_me/1` |

  All requests carry `Authorization: Bearer <jwt>` where the JWT comes
  from `Raxol.Earn.Auth`. On a 401 the token is invalidated and the
  request is retried once.

  ## Construction

      api =
        Raxol.Earn.JobApi.HTTP.new(
          auth: my_auth_pid,
          server_url: "https://api-dev.acp.virtuals.io",
          chain_ids: [8453]
        )
  """

  @behaviour Raxol.Earn.JobApi

  alias Raxol.Earn.Auth

  @doc """
  Build an adapter.

  ## Required options

  - `:auth` -- `pid()` or name of a `Raxol.Earn.Auth` GenServer.
  - `:server_url` -- e.g. `https://api-dev.acp.virtuals.io`.

  ## Optional

  - `:chain_ids` -- list of chain IDs to send as the `chainIds` query
    param on `browse_agents`. Default `[8453]`.
  - `:req_options` -- extra options threaded into Req (useful for
    stubbing).
  """
  @spec new(keyword()) :: Raxol.Earn.JobApi.t()
  def new(opts) do
    config = %{
      auth: Keyword.fetch!(opts, :auth),
      server_url: opts |> Keyword.fetch!(:server_url) |> String.trim_trailing("/"),
      chain_ids: Keyword.get(opts, :chain_ids, [8453]),
      req_options: Keyword.get(opts, :req_options, [])
    }

    %{adapter: __MODULE__, config: config}
  end

  # -- Behaviour callbacks --

  @impl Raxol.Earn.JobApi
  def browse_agents(%{config: cfg}, keyword, params) do
    query = build_browse_query(keyword, params, cfg.chain_ids)
    url = cfg.server_url <> "/agents/search?" <> URI.encode_query(query)

    case authed_request(cfg, :get, url, nil) do
      {:ok, %{"data" => agents}} when is_list(agents) ->
        {:ok, Enum.map(agents, &normalize_agent/1)}

      {:ok, body} ->
        {:error, {:unexpected_body, body}}

      err ->
        err
    end
  end

  @impl Raxol.Earn.JobApi
  def get_agent_by_wallet_address(%{config: cfg}, wallet_address) do
    url = cfg.server_url <> "/agents/wallet/" <> wallet_address

    case authed_request(cfg, :get, url, nil) do
      {:ok, %{"data" => nil}} -> {:ok, nil}
      {:ok, %{"data" => agent}} -> {:ok, normalize_agent(agent)}
      {:error, {:http_status, 404, _}} -> {:ok, nil}
      err -> err
    end
  end

  @impl Raxol.Earn.JobApi
  def get_me(%{config: cfg} = api) do
    # We need our own wallet address. Fetch from the Auth process's provider.
    # Cheaper: ask the Auth state.
    address = our_address(cfg)
    get_agent_by_wallet_address(api, address)
  end

  @impl Raxol.Earn.JobApi
  def get_active_jobs(%{config: cfg}) do
    url = cfg.server_url <> "/jobs"

    case authed_request(cfg, :get, url, nil) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, body} -> {:error, {:unexpected_body, body}}
      err -> err
    end
  end

  @impl Raxol.Earn.JobApi
  def post_deliverable(%{config: cfg}, chain_id, job_id, deliverable) do
    url = cfg.server_url <> "/jobs/#{chain_id}/#{job_id}/deliverable"

    payload =
      case deliverable do
        s when is_binary(s) -> %{"deliverable" => s}
        other -> %{"deliverable" => Jason.encode!(other)}
      end

    case authed_request(cfg, :post, url, payload) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # -- Internal --

  defp authed_request(cfg, method, url, body, retried? \\ false) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        headers = [{"authorization", "Bearer " <> token}, {"accept", "application/json"}]
        opts = base_opts(cfg) ++ [url: url, method: method, headers: headers]

        opts =
          if body do
            opts ++ [json: body]
          else
            opts
          end

        case Req.request(opts) do
          {:ok, %Req.Response{status: 200, body: resp}} ->
            {:ok, resp}

          {:ok, %Req.Response{status: 401, body: _}} when not retried? ->
            :ok = Auth.invalidate(cfg.auth)
            authed_request(cfg, method, url, body, true)

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_status, status, body}}

          {:error, reason} ->
            {:error, {:transport, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp base_opts(cfg), do: cfg.req_options

  defp build_browse_query(keyword, params, default_chain_ids) do
    chain_ids = Map.get(params, :chain_ids, default_chain_ids) |> Enum.join(",")

    base = %{"query" => keyword, "chainIds" => chain_ids}

    base
    |> maybe_put_query("topK", Map.get(params, :top_k))
    |> maybe_put_query("isOnline", encode_online(Map.get(params, :is_online)))
    |> maybe_put_query("cluster", Map.get(params, :cluster))
    |> maybe_put_query("sortBy", encode_sort(Map.get(params, :sort_by)))
    |> maybe_put_query("showHidden", Map.get(params, :show_hidden))
  end

  defp maybe_put_query(map, _key, nil), do: map
  defp maybe_put_query(map, key, value), do: Map.put(map, key, value)

  defp encode_online(:online), do: "true"
  defp encode_online(:offline), do: "false"
  defp encode_online(_), do: nil

  defp encode_sort(nil), do: nil
  defp encode_sort(atom), do: Atom.to_string(atom)

  # Pull the agent's wallet address from the underlying Auth's provider.
  defp our_address(cfg) do
    case Auth.get_state(cfg.auth) do
      %Auth{provider: provider} ->
        Raxol.Earn.ProviderAdapter.get_address(provider)
    end
  end

  defp normalize_agent(agent) when is_map(agent) do
    %{
      wallet_address: agent["walletAddress"] || agent["wallet_address"],
      name: agent["name"] || "",
      description: agent["description"],
      cluster: agent["cluster"],
      offerings: agent["offerings"],
      is_online: agent["isOnline"] || agent["is_online"],
      successful_job_count: agent["successfulJobCount"] || agent["successful_job_count"],
      success_rate: agent["successRate"] || agent["success_rate"]
    }
  end
end
