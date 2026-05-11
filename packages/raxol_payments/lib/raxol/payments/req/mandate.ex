defmodule Raxol.Payments.Req.Mandate do
  @moduledoc """
  Req plugin that attaches a Xochi delegation envelope to outbound
  requests bound for Xochi endpoints.

  The plugin maps the request path to a Mandate scope (`/api/intent/quote`
  -> `"quote"`, `/api/intent/execute` -> `"execute"`,
  `/api/settlement/claim` -> `"stealth_claim"`), looks up the
  soonest-expiring active Mandate for the agent in
  `Raxol.Payments.Mandate.Store` via `Raxol.Payments.Mandate.Check`,
  and sets `X-Xochi-Delegation` to the base64url envelope.

  Requests to non-Xochi hosts pass through unchanged. Requests to
  unrecognized Xochi paths pass through unchanged. Missing/expired
  mandates pass through with no header -- the upstream will respond
  401/402 and the caller can decide how to handle it.

  ## Usage

      Req.new(url: "https://api.xochi.fi/api/intent/quote")
      |> Raxol.Payments.Req.Mandate.attach(
        agent_wallet: "0xabc...",
        # optional overrides
        hosts: ["xochi.fi", "api.xochi.fi"]
      )
      |> Req.post(json: quote_body)

  ## Options

  - `:agent_wallet` (required) -- the agent address whose mandates
    should be considered.
  - `:hosts` -- list of host suffixes treated as Xochi. Default:
    `["xochi.fi", "api.xochi.fi"]`. Suffix match, so
    `staging.xochi.fi` works.
  - `:path_scopes` -- map of path prefix to scope. Default:
    `%{"/api/intent/quote" => "quote", "/api/intent/execute" => "execute", "/api/settlement/claim" => "stealth_claim"}`.

  The Mandate Store is a singleton (`Raxol.Payments.Mandate.Store`);
  start exactly one per node.
  """

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Check

  @default_hosts ["xochi.fi", "api.xochi.fi"]
  @default_path_scopes %{
    "/api/intent/quote" => "quote",
    "/api/intent/execute" => "execute",
    "/api/settlement/claim" => "stealth_claim"
  }

  @doc "Attach the Mandate plugin to a Req request."
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    Req.Request.append_request_steps(req, mandate: &maybe_attach_header(&1, opts))
  end

  @spec maybe_attach_header(Req.Request.t(), keyword()) :: Req.Request.t()
  defp maybe_attach_header(%Req.Request{} = req, opts) do
    case resolve_envelope(req, opts) do
      {:ok, envelope} -> Req.Request.put_header(req, "x-xochi-delegation", envelope)
      :skip -> req
    end
  end

  defp resolve_envelope(%Req.Request{} = req, opts) do
    with {:ok, agent_wallet} <- fetch_agent_wallet(opts),
         {:ok, host} <- request_host(req),
         true <- xochi_host?(host, Keyword.get(opts, :hosts, @default_hosts)),
         {:ok, scope} <- match_scope(req, Keyword.get(opts, :path_scopes, @default_path_scopes)),
         {:ok, mandate} <- Check.select_for_scope(scope, agent_wallet) do
      Mandate.to_envelope(mandate)
    else
      _ -> :skip
    end
  end

  defp fetch_agent_wallet(opts) do
    case Keyword.get(opts, :agent_wallet) do
      wallet when is_binary(wallet) -> {:ok, wallet}
      _ -> {:error, :missing_agent_wallet}
    end
  end

  defp request_host(%Req.Request{url: %URI{host: host}}) when is_binary(host),
    do: {:ok, String.downcase(host)}

  defp request_host(_), do: {:error, :no_host}

  defp xochi_host?(host, hosts) do
    Enum.any?(hosts, fn allowed ->
      allowed = String.downcase(allowed)
      host == allowed or String.ends_with?(host, "." <> allowed)
    end)
  end

  defp match_scope(%Req.Request{url: %URI{path: path}}, path_scopes) when is_binary(path) do
    case Enum.find(path_scopes, fn {prefix, _scope} -> String.starts_with?(path, prefix) end) do
      {_prefix, scope} -> {:ok, scope}
      nil -> {:error, :no_scope_match}
    end
  end

  defp match_scope(_, _), do: {:error, :no_scope_match}
end
