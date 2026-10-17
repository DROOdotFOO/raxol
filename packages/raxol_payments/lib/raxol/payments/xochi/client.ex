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
  - `get_status/3` -- GET /api/intent/:id/status
  - `get_intent/3` -- GET /api/intent/:id
  - `get_history/2` -- GET /api/intent/history?wallet=
  - `claim/2` -- POST /api/stealth/claim

  Pinned contract: `xochi/docs/contracts/xochi-intent-api.md`. It covers quote,
  execute, and status; the history and stealth claim paths live in the worker's
  OpenAPI spec.

  ## Authentication

  An autonomous agent cannot mint a passkey-issued Member JWT the way a browser
  can, so the client supports the worker's three auth modes via `:auth`:

  - `{:mandate, agent_wallet}` -- a Member signs an EIP-712 delegation envelope
    once; the agent presents `X-Xochi-Delegation` per call. Best fit for an
    agent acting for a Member. Wires `Raxol.Payments.Req.Mandate`, which looks
    up the soonest-expiring active mandate for the wallet. Pass plugin overrides
    with `{:mandate, agent_wallet, opts}`.
  - `{:x402, wallet: MyWallet}` -- Guest mode. The agent signs an EIP-3009 USDC
    micropayment per call and sends `X-PAYMENT`. Wires `Raxol.Payments.Req.AutoPay`
    (restricted to `:x402`), which regenerates the payment from each 402 challenge.
  - `{:member, jwt}` -- only if a passkey-issued JWT is provisioned out of band.

  ## Read capability

  For a non-`public` (stealth/shielded) intent the worker withholds the
  on-chain legs (`tx_hash`, `receiving_tx_hash`, ...) on `get_status/3` and
  `get_intent/3` unless the caller proves ownership (xochi#563). `execute/2`
  returns a one-time `read_token` (`ExecuteResponse.read_token`; nil from an
  older worker); pass it back as `read_token:` and it travels only in the
  `X-Xochi-Read-Token` request header, never in a URL. It is a bearer secret
  for privacy, not funds: keep it with the intent record, out of logs, and away
  from any other host. A missing or invalid token yields the anonymous view
  (same shape, legs absent), not an error. A `read_token:` that is not 43
  unpadded base64url characters is refused with `{:error, :invalid_read_token}`
  before any request.

  The worker also serves the token on an execute 502 when funds may have
  moved. `execute/2` then returns `{:error, {:execute_in_doubt, status,
  %ExecuteResponse{}}}` carrying it: poll that intent with it, never
  re-execute. Every other non-2xx body has any `read_token` replaced by
  `"[redacted]"` before it is returned, so an error term can be logged.

  ## Configuration

      # Mandate (recommended for agents)
      config = %{base_url: "https://api.xochi.fi", auth: {:mandate, "0xAgent..."}}

      # Guest / x402
      config = %{base_url: "https://api.xochi.fi", auth: {:x402, wallet: MyWallet}}

      # Member JWT (legacy `:auth_token` is equivalent to `{:member, token}`)
      config = %{base_url: "https://api.xochi.fi", auth_token: "bearer-token"}

      {:ok, quote} = Xochi.Client.get_quote(config, %QuoteRequest{...})
  """

  alias Raxol.Payments.Xochi.Schemas.{
    DepositRouteRequest,
    QuoteRequest,
    QuoteResponse,
    ExecuteRequest,
    ExecuteResponse,
    Intent,
    IntentStatus
  }

  @type auth ::
          {:member, String.t()}
          | {:mandate, String.t()}
          | {:mandate, String.t(), keyword()}
          | {:x402, keyword()}
          | :none

  @type config :: %{
          :base_url => String.t(),
          optional(:auth) => auth(),
          optional(:auth_token) => String.t() | Raxol.Payments.Secret.t(),
          optional(:req_options) => keyword()
        }

  @type error ::
          {:error, {:http, integer(), term()}}
          | {:error, {:execute_in_doubt, integer(), ExecuteResponse.t()}}
          | {:error, term()}

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

  @doc """
  Request a deposit-route quote for a non-EVM (Tron) origin.

  Same `/api/intent/quote` endpoint as `get_quote/2`, but the request allows a
  base58 origin and the response carries a `deposit_address` + `deposit_attestation`
  (verify it before sending funds) instead of EIP-712 typed data to sign.
  """
  @spec get_deposit_route_quote(config(), DepositRouteRequest.t()) ::
          {:ok, QuoteResponse.t()} | error()
  def get_deposit_route_quote(config, %DepositRouteRequest{} = request) do
    with :ok <- DepositRouteRequest.validate(request) do
      config
      |> build_req()
      |> Req.post(url: "/api/intent/quote", json: DepositRouteRequest.to_json(request))
      |> handle_response(&QuoteResponse.from_json/1)
    end
  end

  @doc """
  Execute a quoted intent with a signed payload.

  A non-2xx whose body carries a well-formed `read_token` is the worker saying
  funds may have moved (xochi#563): it returns `{:error, {:execute_in_doubt,
  status, %ExecuteResponse{}}}`, whose `read_token` (hidden from `inspect`)
  polls the intent. Treat it as dispatched and in doubt, never as a clean
  failure to retry.
  """
  @spec execute(config(), ExecuteRequest.t()) :: {:ok, ExecuteResponse.t()} | error()
  def execute(config, %ExecuteRequest{} = request) do
    config
    |> build_req()
    |> Req.post(url: "/api/intent/execute", json: ExecuteRequest.to_json(request))
    |> handle_execute_response()
  end

  @doc """
  Get intent status by ID.

  Options: `:read_token` -- the `ExecuteResponse.read_token` for this intent,
  sent as `X-Xochi-Read-Token` so a stealth/shielded intent's tx hashes are
  returned (see "Read capability"). Without it they are absent.
  """
  @spec get_status(config(), String.t(), keyword()) :: {:ok, IntentStatus.t()} | error()
  def get_status(config, intent_id, opts \\ []) do
    with {:ok, req} <- put_read_token(build_req(config), Keyword.get(opts, :read_token)) do
      req
      |> Req.get(url: "/api/intent/#{intent_id}/status")
      |> handle_response(&IntentStatus.from_json/1)
    end
  end

  @doc """
  Get the persisted intent by ID (`GET /api/intent/:id`).

  Returns the authoritative corridor and amounts written at quote time, so a
  relayer can read what the buyer signed BEFORE settlement (`IntentStatus` from
  `get_status/3` carries only tx/settlement state, no amounts). A not-yet-created
  or unknown id yields `{:error, {:http, 404, _}}`. Takes the same `:read_token`
  option as `get_status/3`; the corridor and amounts are returned either way.
  """
  @spec get_intent(config(), String.t(), keyword()) :: {:ok, Intent.t()} | error()
  def get_intent(config, intent_id, opts \\ []) do
    with {:ok, req} <- put_read_token(build_req(config), Keyword.get(opts, :read_token)) do
      req
      |> Req.get(url: "/api/intent/#{intent_id}")
      |> handle_response(&Intent.from_json/1)
    end
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
  Submit a gasless stealth settlement claim.

  Posts the signed claim to the worker's single stealth claim endpoint
  (`POST /api/stealth/claim`), which sponsors it via Pimlico/ERC-4337 and
  proxies to the Riddler solver. The agent derives stealth keys from an
  ERC-5564 announcement and signs the claim message before calling this.

  Required params (snake_case, per the pinned contract): `:stealth_address`,
  `:recipient`, `:ephemeral_pub_key`, `:signature`. Optional: `:view_tag`.
  Returns `{:ok, %{"tx_hash" => ..., "status" => ...}}`.
  """
  @spec claim(config(), map()) :: {:ok, map()} | error()
  def claim(
        config,
        %{
          stealth_address: _,
          recipient: _,
          ephemeral_pub_key: _,
          signature: _
        } = params
      ) do
    json =
      %{
        "stealth_address" => params.stealth_address,
        "recipient" => params.recipient,
        "ephemeral_pub_key" => params.ephemeral_pub_key,
        "signature" => params.signature
      }
      |> maybe_put("view_tag", Map.get(params, :view_tag))

    config
    |> build_req()
    |> Req.post(url: "/api/stealth/claim", json: json)
    |> handle_response(& &1)
  end

  # -- Private --

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_req(config) do
    validate_base_url!(config.base_url)

    [base_url: config.base_url, receive_timeout: 30_000]
    |> Keyword.merge(Map.get(config, :req_options, []))
    |> Req.new()
    |> apply_auth(auth_mode(config))
  end

  # Explicit `:auth` wins; a bare legacy `:auth_token` maps to Member Bearer;
  # otherwise the request is anonymous (the worker answers 402 with a Guest
  # invite). A `Raxol.Payments.Secret`-wrapped token is revealed only here, so
  # the token stays redacted in any config/state that a crash report might dump.
  defp auth_mode(%{auth: auth}), do: auth

  defp auth_mode(%{auth_token: %Raxol.Payments.Secret{} = token}),
    do: {:member, Raxol.Payments.Secret.reveal(token)}

  defp auth_mode(%{auth_token: token}) when is_binary(token), do: {:member, token}
  defp auth_mode(_), do: :none

  defp apply_auth(req, {:member, token}) do
    Req.Request.put_header(req, "authorization", "Bearer #{token}")
  end

  defp apply_auth(req, {:mandate, agent_wallet}) do
    apply_auth(req, {:mandate, agent_wallet, []})
  end

  defp apply_auth(req, {:mandate, agent_wallet, opts}) do
    Raxol.Payments.Req.Mandate.attach(req, [agent_wallet: agent_wallet] ++ opts)
  end

  defp apply_auth(req, {:x402, opts}) do
    Raxol.Payments.Req.AutoPay.attach(req, Keyword.put(opts, :protocols, [:x402]))
  end

  defp apply_auth(req, :none), do: req

  # The read capability rides a header only: a URL lands in proxy and access
  # logs. It is set here, not by the Mandate plugin, which maps no read path.
  # A malformed token is the caller's bug: refused without echoing it.
  defp put_read_token(req, nil), do: {:ok, req}

  defp put_read_token(req, token) do
    if ExecuteResponse.read_token?(token),
      do: {:ok, Req.Request.put_header(req, "x-xochi-read-token", token)},
      else: {:error, :invalid_read_token}
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
    {:error, {:http, status, redact_read_token(body)}}
  end

  defp handle_response({:error, reason}, _transform) do
    {:error, reason}
  end

  defp handle_execute_response(
         {:ok, %Req.Response{status: status, body: %{"read_token" => token} = body}}
       )
       when status not in 200..299 do
    if ExecuteResponse.read_token?(token),
      do: {:error, {:execute_in_doubt, status, ExecuteResponse.from_json(body)}},
      else: {:error, {:http, status, redact_read_token(body)}}
  end

  defp handle_execute_response(response),
    do: handle_response(response, &ExecuteResponse.from_json/1)

  # An error term is logged and returned to callers that `inspect` it; the
  # token is a bearer secret, so it never rides one. A non-JSON body is text.
  defp redact_read_token(%{"read_token" => _} = body), do: %{body | "read_token" => "[redacted]"}

  defp redact_read_token(body) when is_binary(body),
    do: Regex.replace(~r/("read_token"\s*:\s*")[^"]*"/, body, ~S(\1[redacted]"))

  defp redact_read_token(body), do: body
end
