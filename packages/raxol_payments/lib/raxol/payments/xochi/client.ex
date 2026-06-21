defmodule Raxol.Payments.Xochi.Client do
  @moduledoc """
  Client for the Xochi private execution protocol.

  Talks to the Xochi worker's `/api/intent/*` endpoints. The worker is the sole
  agent surface: it applies trust-tier fees and attestations, is the x402
  boundary, and calls the Riddler solver internally. Do not target
  `riddler.axol.io/xochi/*` directly -- that bypasses Xochi's fee/tier logic and
  returns the raw solver quote (a thinner shape, no `can_solve`/`xochi_fee`).

  ## Endpoints

  - `get_quote/2` -- POST /api/intent/quote
  - `execute/2` -- POST /api/intent/execute
  - `get_status/2` -- GET /api/intent/:id/status
  - `get_history/2` -- GET /api/intent/history?wallet=
  - `prepare_claim/2` -- POST /api/intent/claim/prepare
  - `submit_claim/2` -- POST /api/intent/claim/submit

  Pinned contract: `xochi/docs/contracts/xochi-intent-api.md`. It covers quote,
  execute, and status; the history and claim paths are not in it.

  ## Configuration

      config = %{
        base_url: "https://api.xochi.fi",
        auth_token: "bearer-token"
      }

      {:ok, quote} = Xochi.Client.get_quote(config, %QuoteRequest{...})
  """

  alias Raxol.Payments.Xochi.Schemas.{
    QuoteRequest,
    QuoteResponse,
    ExecuteRequest,
    ExecuteResponse,
    IntentStatus
  }

  @type config :: %{
          :base_url => String.t(),
          :auth_token => String.t(),
          optional(:req_options) => keyword()
        }

  @type error :: {:error, {:http, integer(), term()}} | {:error, term()}

  @doc "Request an intent quote."
  @spec get_quote(config(), QuoteRequest.t()) :: {:ok, QuoteResponse.t()} | error()
  def get_quote(config, %QuoteRequest{} = request) do
    with :ok <- QuoteRequest.validate(request) do
      config
      |> build_req()
      |> Req.post(url: "/api/intent/quote", json: QuoteRequest.to_json(request))
      |> handle_response(&QuoteResponse.from_json/1)
    end
  end

  @doc "Execute a quoted intent with a signed payload."
  @spec execute(config(), ExecuteRequest.t()) :: {:ok, ExecuteResponse.t()} | error()
  def execute(config, %ExecuteRequest{} = request) do
    config
    |> build_req()
    |> Req.post(url: "/api/intent/execute", json: ExecuteRequest.to_json(request))
    |> handle_response(&ExecuteResponse.from_json/1)
  end

  @doc "Get intent status by ID."
  @spec get_status(config(), String.t()) :: {:ok, IntentStatus.t()} | error()
  def get_status(config, intent_id) do
    config
    |> build_req()
    |> Req.get(url: "/api/intent/#{intent_id}/status")
    |> handle_response(&IntentStatus.from_json/1)
  end

  @doc "Get intent history for a wallet."
  @spec get_history(config(), String.t(), keyword()) :: {:ok, [map()]} | error()
  def get_history(config, wallet, opts \\ []) do
    params = [wallet: wallet] ++ opts

    config
    |> build_req()
    |> Req.get(url: "/api/intent/history", params: params)
    |> handle_response(fn body ->
      Map.get(body, "intents", [])
    end)
  end

  @doc """
  Prepare an unsigned claim for client-side signing.

  Returns the UserOp hash for the client to sign with their stealth key.
  No private keys are sent to the server.
  """
  @spec prepare_claim(config(), map()) :: {:ok, map()} | error()
  def prepare_claim(config, %{intent_id: _, recipient_address: _} = params) do
    json = %{
      "intentId" => params.intent_id,
      "recipientAddress" => params.recipient_address
    }

    config
    |> build_req()
    |> Req.post(url: "/api/intent/claim/prepare", json: json)
    |> handle_response(& &1)
  end

  @doc """
  Submit a client-signed claim to the bundler.

  The client signs the hash from `prepare_claim/2` and submits
  the signature here.
  """
  @spec submit_claim(config(), map()) :: {:ok, map()} | error()
  def submit_claim(config, %{intent_id: _, signature: _} = params) do
    json = %{
      "intentId" => params.intent_id,
      "signature" => params.signature
    }

    config
    |> build_req()
    |> Req.post(url: "/api/intent/claim/submit", json: json)
    |> handle_response(& &1)
  end

  # -- Private --

  defp build_req(config) do
    validate_base_url!(config.base_url)

    [
      base_url: config.base_url,
      headers: [{"authorization", "Bearer #{config.auth_token}"}],
      receive_timeout: 30_000
    ]
    |> Keyword.merge(Map.get(config, :req_options, []))
    |> Req.new()
  end

  defp validate_base_url!("https://" <> _), do: :ok
  defp validate_base_url!("http://localhost" <> _), do: :ok
  defp validate_base_url!("http://127.0.0.1" <> _), do: :ok

  defp validate_base_url!(url) do
    raise ArgumentError, "Xochi client requires HTTPS base_url, got: #{inspect(url)}"
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, transform)
       when status in 200..299 do
    {:ok, transform.(body)}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _transform) do
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}, _transform) do
    {:error, reason}
  end
end
