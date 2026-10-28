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

  Any transport failure, 5xx, or malformed response after the execute request
  starts is returned as a reconciling `ExecuteResponse`: the worker may have
  accepted the intent even when the client could not read a valid answer. So
  is a refusal because the intent already left `quoted` (409 another writer is
  executing it, or 400 naming any status but `expired`): this request did not
  execute it, but another may have. Any other structurally valid 4xx remains a
  clean rejection. Error bodies always redact `read_token`.

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
    ExecuteRequest,
    ExecuteResponse,
    Intent,
    IntentStatus,
    QuoteRequest,
    QuoteResponse
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
          | {:error, term()}

  # Worker `error_category` values for a 409 refused before the execution claim:
  # nothing can be in flight, so the rejection is clean.
  @clean_conflict_categories ["promo_unavailable"]

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

  Once the POST starts it is never retried by the transport. A reset, 5xx, or
  malformed response has an unknown outcome: the worker may have accepted the
  intent. Failures proven to occur before a connection was established are
  returned as definite errors. A refusal because another writer claimed the
  intent is also definite for this request. Error bodies always redact read
  tokens.
  """
  @spec execute(config(), ExecuteRequest.t()) :: {:ok, ExecuteResponse.t()} | error()
  def execute(config, %ExecuteRequest{} = request) do
    with {:ok, req, json} <- prepare_execute(config, request) do
      try do
        req
        |> Req.post(url: "/api/intent/execute", json: json, retry: false)
        |> handle_execute_response(request.intent_id)
      rescue
        exception in Req.TransportError ->
          classify_execute_exception(exception.reason, request.intent_id)

        _exception ->
          {:ok, in_doubt(request.intent_id, :response_exception)}
      catch
        _kind, reason -> classify_execute_exception(reason, request.intent_id)
      end
    end
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
      |> Req.get(url: "/api/intent/#{intent_id}/status", redirect: false)
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
      |> Req.get(url: "/api/intent/#{intent_id}", redirect: false)
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

  @doc "Validate the endpoint before callers persist a dispatched checkpoint."
  @spec validate_config(config()) :: :ok | {:error, :invalid_base_url}
  def validate_config(%{base_url: base_url}) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] -> :ok
      _ -> {:error, :invalid_base_url}
    end
  end

  def validate_config(_config), do: {:error, :invalid_base_url}

  # -- Private --

  defp prepare_execute(config, request) do
    with :ok <- validate_config(config) do
      {:ok, build_req(config), ExecuteRequest.to_json(request)}
    end
  rescue
    _exception -> {:error, :execute_preparation_failed}
  catch
    _kind, _reason -> {:error, :execute_preparation_failed}
  end

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

  defp validate_base_url!(base_url) do
    case validate_config(%{base_url: base_url}) do
      :ok -> :ok
      {:error, :invalid_base_url} -> raise ArgumentError, "Xochi client requires HTTPS base_url"
    end
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
         {:ok, %Req.Response{status: status, body: body}},
         intent_id
       )
       when status in 200..299 do
    {:ok, parse_execute(body, intent_id)}
  end

  defp handle_execute_response(
         {:ok, %Req.Response{status: status, body: body}},
         intent_id
       )
       when status >= 500 do
    {:ok, parse_in_doubt(body, intent_id, {:http, status})}
  end

  defp handle_execute_response(
         {:ok, %Req.Response{status: status, body: body}},
         intent_id
       )
       when status in 400..499 and is_map(body) do
    cond do
      past_quoted?(status, body) ->
        {:error, {:http, status, redact_read_token(body)}}

      valid_read_token?(body) ->
        {:ok, parse_in_doubt(body, intent_id, {:http, status})}

      clean_rejection?(body) ->
        {:error, {:http, status, redact_read_token(body)}}

      true ->
        {:ok, in_doubt(intent_id, {:invalid_rejection, status})}
    end
  end

  defp handle_execute_response({:ok, %Req.Response{status: status}}, intent_id),
    do: {:ok, in_doubt(intent_id, {:invalid_response, status})}

  defp handle_execute_response({:error, reason}, intent_id) do
    if definite_connect_failure?(reason),
      do: {:error, {:transport, :not_sent}},
      else: {:ok, in_doubt(intent_id, :transport_error)}
  end

  defp parse_execute(body, intent_id) do
    case read_token_value(body) do
      {:error, :malformed_read_token} ->
        in_doubt(intent_id, :malformed_read_token)

      _ ->
        exec = ExecuteResponse.from_json(body)

        if valid_execute_response?(exec, intent_id),
          do: sanitize_execute(exec, intent_id),
          else: sanitize_in_doubt(exec, intent_id, :invalid_response)
    end
  end

  defp parse_in_doubt(body, intent_id, reason) when is_map(body) do
    case read_token_value(body) do
      {:error, :malformed_read_token} ->
        in_doubt(intent_id, :malformed_read_token)

      _ ->
        body
        |> ExecuteResponse.from_json()
        |> sanitize_in_doubt(intent_id, reason)
    end
  rescue
    _exception -> in_doubt(intent_id, reason)
  end

  defp parse_in_doubt(_body, intent_id, reason), do: in_doubt(intent_id, reason)

  defp valid_execute_response?(%ExecuteResponse{} = exec, intent_id) do
    exec.intent_id in [nil, intent_id] and exec.status != :unknown and
      is_boolean(exec.reconciling) and optional_binary?(exec.tx_hash) and
      optional_binary?(exec.note_commitment) and optional_binary?(exec.stealth_address) and
      optional_binary?(exec.ephemeral_pub_key) and optional_integer?(exec.view_tag) and
      optional_binary?(exec.error)
  end

  defp sanitize_execute(%ExecuteResponse{} = exec, intent_id) do
    token = exec.read_token

    %{
      exec
      | intent_id: intent_id,
        tx_hash: public_binary(exec.tx_hash, token),
        note_commitment: public_binary(exec.note_commitment, token),
        stealth_address: public_binary(exec.stealth_address, token),
        ephemeral_pub_key: public_binary(exec.ephemeral_pub_key, token),
        error: redact_execute_error(exec.error, token)
    }
  end

  defp sanitize_in_doubt(%ExecuteResponse{} = exec, intent_id, reason) do
    %ExecuteResponse{
      intent_id: intent_id,
      status: if(exec.status == :unknown, do: :unknown, else: exec.status),
      read_token: exec.read_token,
      tx_hash: public_binary(exec.tx_hash, exec.read_token),
      note_commitment: public_binary(exec.note_commitment, exec.read_token),
      stealth_address: public_binary(exec.stealth_address, exec.read_token),
      ephemeral_pub_key: public_binary(exec.ephemeral_pub_key, exec.read_token),
      view_tag: optional_integer(exec.view_tag),
      error: inspect(reason),
      reconciling: true
    }
  end

  defp in_doubt(intent_id, reason) do
    %ExecuteResponse{
      intent_id: intent_id,
      status: :unknown,
      error: inspect(reason),
      reconciling: true
    }
  end

  defp optional_binary?(value), do: is_nil(value) or is_binary(value)
  defp optional_integer?(value), do: is_nil(value) or is_integer(value)
  defp optional_integer(value) when is_integer(value), do: value
  defp optional_integer(_value), do: nil

  defp redact_execute_error(error, token) when is_binary(error) and is_binary(token),
    do: String.replace(error, token, "[redacted]")

  defp redact_execute_error(error, _token), do: error

  defp public_binary(value, token) when is_binary(value) and value != token, do: value
  defp public_binary(_value, _token), do: nil

  defp clean_rejection?(body) do
    Enum.any?(["error", "reason", "message"], fn key ->
      value = body[key]
      is_binary(value) and value != ""
    end)
  end

  # A refusal means this request did not dispatch. The caller may retain state
  # owned by the writer that won, but must never poll or reuse that writer's
  # capability as evidence for this request.
  defp past_quoted?(409, body),
    do: body["error_category"] not in @clean_conflict_categories and not quote_gone?(body)

  defp past_quoted?(400, %{"error" => error}) when is_binary(error) do
    match?([_, _status], Regex.run(~r/\ACannot execute intent in (\S+) status\z/, error))
  end

  defp past_quoted?(_status, _body), do: false

  # Mirrors the execute Action's re-quote trigger, so an expiry it re-quotes is
  # never turned into an in-doubt outcome here.
  defp quote_gone?(body) do
    code = body["error"] || body["reason"]
    message = body["message"]

    (is_binary(code) and (String.contains?(code, "quote_expired") or code == "not_found")) or
      (is_binary(message) and String.contains?(String.downcase(message), "expired"))
  end

  # Error terms can be logged or persisted. Recursively redact the bearer
  # capability rather than assuming it appears only at the response root.
  defp redact_read_token(body) when is_map(body) do
    Map.new(body, fn
      {key, _value} when key in ["read_token", "readToken"] -> {key, "[redacted]"}
      {key, value} -> {key, redact_read_token(value)}
    end)
  end

  defp redact_read_token(body) when is_list(body), do: Enum.map(body, &redact_read_token/1)

  defp redact_read_token(body) when is_binary(body) do
    Regex.replace(~r/("(?:read_token|readToken)"\s*:\s*")[^"]*"/, body, ~S(\1[redacted]"))
  end

  defp redact_read_token(body), do: body

  defp valid_read_token?(body), do: match?({:ok, _token}, read_token_value(body))

  defp read_token_value(body) when is_map(body) do
    case Map.fetch(body, "read_token") do
      {:ok, value} -> validate_read_token_value(value)
      :error -> body |> Map.fetch("readToken") |> read_token_from_fetch()
    end
  end

  defp read_token_value(_body), do: :missing
  defp read_token_from_fetch(:error), do: :missing
  defp read_token_from_fetch({:ok, value}), do: validate_read_token_value(value)
  defp validate_read_token_value(nil), do: :missing

  defp validate_read_token_value(value) do
    if ExecuteResponse.read_token?(value),
      do: {:ok, value},
      else: {:error, :malformed_read_token}
  end

  @definite_connect_reasons [
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :connect_timeout
  ]

  defp classify_execute_exception(reason, intent_id) do
    if definite_connect_failure?(reason),
      do: {:error, {:transport, :not_sent}},
      else: {:ok, in_doubt(intent_id, :response_exception)}
  end

  defp definite_connect_failure?(reason) when reason in @definite_connect_reasons, do: true
  defp definite_connect_failure?({:tls_alert, _detail}), do: true

  defp definite_connect_failure?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&definite_connect_failure?/1)

  defp definite_connect_failure?(reason) when is_map(reason),
    do: reason |> Map.values() |> Enum.any?(&definite_connect_failure?/1)

  defp definite_connect_failure?(_reason), do: false
end
