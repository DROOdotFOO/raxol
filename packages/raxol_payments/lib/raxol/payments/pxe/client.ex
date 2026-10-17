defmodule Raxol.Payments.Pxe.Client do
  @moduledoc """
  JSON-RPC 2.0 client for the pxe-bridge.

  pxe-bridge embeds an Aztec PXE and exposes it via HTTP. This client
  wraps the two RPC methods (`aztec_createNote`, `aztec_getVersion`)
  and the `/status` health endpoint.

  ## Configuration

      config = %{
        url: "http://127.0.0.1:8547",
        api_key: "optional-bearer-token",
        # optional; defaults shown
        create_note_timeout_ms: 180_000,
        request_timeout_ms: 10_000
      }

      {:ok, result} =
        Pxe.Client.create_note(config, %CreateNoteParams{...}, settlement_id)

  `:req_options` is merged into the request last and is the seam a test or an
  example drives the bridge through without one running:

      config = %{url: "http://pxe.sim", req_options: [plug: fn conn -> ... end]}

  ## Creating a note moves money

  `create_note/3` takes an idempotency key, sent as `Idempotency-Key`. The
  bridge records the outcome under it for 24 hours and answers every later
  request with that key from the record, whatever its params, so one key
  names one transfer: derive it from your own settlement id and never reuse
  it for another.

  The call waits up to `:create_note_timeout_ms` (default 180s). The bridge
  bounds proving and sending at 120s and answers within 150s, so the default
  lets the bridge, not this client, decide the outcome. It is retried only when
  the connection was refused or closed, once, and never after a timeout.

  What to do with each failure:

    * `{:error, :request_in_flight}`, `{:error, {:http, 504, _}}` or a
      `Req.TransportError` with `reason: :timeout` -- the outcome is not known
      to this call. Send the same params with the same key again: the bridge
      replays the recorded outcome, or answers `:request_in_flight` while the
      first attempt is still running.
    * `{:error, {:submitted_unknown, tx_hash}}` -- the transfer may have
      landed (`tx_hash` is `nil` when the bridge's deadline expired before it
      had one). The key is settled and every replay returns this same error.
      Do not send the transfer again; reconcile against Aztec first.
    * `{:error, {:rpc, -32_602, reason}}` -- refused before anything moved
      (invalid params, or a volume limit or pause). The key is released.
    * `{:error, {:rpc, -32_603, _}}` -- failed before submission; nothing
      moved and the key is released, so resending is safe.
    * any other `{:error, {:http, status, _}}` -- a 4xx (401, 413, 415, 429,
      or 400 for a malformed body) was refused before the RPC ran, so nothing
      moved. The bridge does not classify a 5xx other than 504; treat it as
      outcome unknown.
  """

  alias Raxol.Payments.Pxe.Schemas.{CreateNoteParams, CreateNoteResult, HealthStatus}

  @type config :: %{
          optional(:url) => String.t(),
          optional(:api_key) => String.t() | nil,
          optional(:create_note_timeout_ms) => pos_integer(),
          optional(:request_timeout_ms) => pos_integer(),
          optional(:req_options) => keyword()
        }

  @type error ::
          {:error, :request_in_flight}
          | {:error, {:submitted_unknown, String.t() | nil}}
          | {:error, {:rpc, integer(), String.t()}}
          | {:error, {:http, integer(), term()}}
          | {:error, {:invalid_idempotency_key, String.t()}}
          | {:error, {:unexpected_result, term()}}
          | {:error, Exception.t()}
          | {:error, term()}

  @default_url "http://127.0.0.1:8547"
  @create_note_timeout_ms 180_000
  @request_timeout_ms 10_000

  @request_in_flight -32_001
  @submitted_unknown -32_002

  @doc """
  Create a shielded note on Aztec L2 for a recipient, under `idempotency_key`.

  See the module doc for what each error means and when resending is safe.
  """
  @spec create_note(config(), CreateNoteParams.t(), String.t()) ::
          {:ok, CreateNoteResult.t()} | error()
  def create_note(config, %CreateNoteParams{} = params, idempotency_key) do
    with :ok <- CreateNoteParams.validate(params),
         :ok <- validate_idempotency_key(idempotency_key) do
      config
      |> build_req(
        receive_timeout: Map.get(config, :create_note_timeout_ms, @create_note_timeout_ms),
        headers: [{"idempotency-key", idempotency_key}],
        retry: &transport_transient?/2,
        max_retries: 1
      )
      |> rpc_call("aztec_createNote", [CreateNoteParams.to_json(params)])
      |> handle_rpc_result(&CreateNoteResult.from_json/1)
    end
  end

  @doc "Get the connected Aztec node version."
  @spec get_version(config()) :: {:ok, String.t()} | error()
  def get_version(config) do
    config
    |> build_req(
      receive_timeout: Map.get(config, :request_timeout_ms, @request_timeout_ms),
      retry: &transient?/2,
      max_retries: 2
    )
    |> rpc_call("aztec_getVersion", [])
    |> handle_rpc_result(&decode_version/1)
  end

  @doc """
  Check bridge health via GET /status.

  A bridge that is still syncing answers 503 with `{"status": "starting"}`;
  that is a health report, returned as `{:ok, %HealthStatus{status: :starting}}`.
  """
  @spec health(config()) :: {:ok, HealthStatus.t()} | error()
  def health(config) do
    config
    |> build_req(
      receive_timeout: Map.get(config, :request_timeout_ms, @request_timeout_ms),
      retry: &transport_transient?/2,
      max_retries: 2
    )
    |> Req.get(url: "/status")
    |> handle_health_response()
  end

  # -- Private --

  defp rpc_call(req, method, params) do
    Req.post(req,
      url: "/",
      json: %{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => System.unique_integer([:positive])
      }
    )
  end

  defp handle_rpc_result({:ok, %Req.Response{status: status, body: body}}, decode)
       when status in 200..299 do
    case body do
      %{"result" => result} -> decode.(result)
      %{"error" => error} when is_map(error) -> rpc_error(error)
      _ -> {:error, {:unexpected_response, body}}
    end
  end

  defp handle_rpc_result({:ok, %Req.Response{status: status, body: body}}, _decode),
    do: {:error, {:http, status, body}}

  defp handle_rpc_result({:error, reason}, _decode), do: {:error, reason}

  defp rpc_error(%{"code" => @request_in_flight}), do: {:error, :request_in_flight}

  defp rpc_error(%{"code" => @submitted_unknown} = error),
    do: {:error, {:submitted_unknown, get_in(error, ["data", "txHash"])}}

  defp rpc_error(%{"code" => code} = error),
    do: {:error, {:rpc, code, Map.get(error, "message", "unknown error")}}

  defp rpc_error(error), do: {:error, {:unexpected_response, error}}

  defp decode_version(version) when is_binary(version), do: {:ok, version}
  defp decode_version(other), do: {:error, {:unexpected_result, other}}

  defp handle_health_response({:ok, %Req.Response{status: status, body: body}})
       when (status in 200..299 or status == 503) and is_map(body),
       do: {:ok, HealthStatus.from_json(body)}

  defp handle_health_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, body}}

  defp handle_health_response({:error, reason}), do: {:error, reason}

  # The bridge's own limit: 1-128 printable ASCII characters, checked after
  # trimming. Refused here so a bad key never reaches a request that moves money.
  defp validate_idempotency_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[\x20-\x7e]{1,128}\z/, key) and String.trim(key) != "" do
      :ok
    else
      {:error, {:invalid_idempotency_key, "must be 1-128 printable ASCII characters"}}
    end
  end

  defp validate_idempotency_key(_),
    do: {:error, {:invalid_idempotency_key, "must be 1-128 printable ASCII characters"}}

  # Reads: a transient gateway status (502/503/504), as `@xochi/client` retries
  # its idempotent requests, or a refused or closed connection.
  defp transient?(_request, %Req.Response{status: status}), do: status in [502, 503, 504]
  defp transient?(request, exception), do: transport_transient?(request, exception)

  # A refused or closed connection, and never a timeout. create_note retries
  # only this: the idempotency key makes a resend after a close safe (it replays,
  # or answers in-flight). Health retries only this because its 503 is the
  # bridge reporting `starting`, not a fault.
  defp transport_transient?(_request, %Req.TransportError{reason: reason}),
    do: reason in [:econnrefused, :closed]

  defp transport_transient?(_request, _response_or_exception), do: false

  defp build_req(config, opts) do
    {headers, opts} = Keyword.pop(opts, :headers, [])

    opts =
      Keyword.merge(opts,
        base_url: Map.get(config, :url, @default_url),
        headers: auth_headers(config) ++ headers
      )

    # The transport seam, named the same as `Xochi.Client`'s so a caller that
    # already sims one bridge does not have to learn a second key. Merged last
    # and on top, so a test or an example can override `base_url` too; without
    # it this client could only ever be exercised against a dead port, which is
    # why nothing here had a success-path test.
    Req.new(Keyword.merge(opts, Map.get(config, :req_options, [])))
  end

  defp auth_headers(%{api_key: key}) when is_binary(key) and key != "" do
    [{"authorization", "Bearer #{key}"}]
  end

  defp auth_headers(_), do: []
end
