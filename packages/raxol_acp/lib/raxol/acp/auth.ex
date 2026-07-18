defmodule Raxol.ACP.Auth do
  @moduledoc """
  EIP-712 → bearer JWT auth flow for the Virtuals ACP API
  (`api.acp.virtuals.io`).

  ## Protocol

  1. Build EIP-712 typed data:

         domain  = {name: "ACP", version: "1", chainId: <chain_id>}
         types   = {AgentAuth: [{wallet,address}, {chainId,uint256}, {issuedAt,uint256}]}
         message = {wallet: <our_address>, chainId, issuedAt: <ms_now>}

  2. Sign via the configured `Raxol.ACP.ProviderAdapter`.
  3. POST `/auth/agent` with JSON body:

         {walletAddress, signature, issuedAt, chainId}

  4. Response: `{"data": {"token": "<jwt>"}}`.
  5. Use `Authorization: Bearer <jwt>` on subsequent HTTP and SSE
     requests.
  6. Refresh when the JWT's `exp` claim is within 60s of now, or on a
     401 from any authed request.

  ## Usage

      {:ok, auth} =
        Raxol.ACP.Auth.start_link(
          provider: my_provider,
          server_url: "https://api-dev.acp.virtuals.io",
          chain_id: 8453
        )

      {:ok, token} = Raxol.ACP.Auth.token(auth)
      # ... use token in Authorization: Bearer ...

      :ok = Raxol.ACP.Auth.invalidate(auth)
      # ... next token/1 will re-authenticate ...

  ## State machine

      :idle -> :refreshing -> :valid -> :refreshing -> :valid -> ...

  Token refresh is serialized through the GenServer's call queue so
  concurrent `token/1` callers share one network round-trip.
  """

  use GenServer

  alias Raxol.ACP.Onchain.Hex
  alias Raxol.ACP.ProviderAdapter

  @type t :: %__MODULE__{
          provider: ProviderAdapter.adapter(),
          server_url: String.t(),
          chain_id: pos_integer(),
          token: String.t() | nil,
          expires_at_ms: integer() | nil,
          req_options: keyword()
        }

  defstruct [:provider, :server_url, :chain_id, :req_options, token: nil, expires_at_ms: nil]

  # Refresh ~60s before the JWT expires.
  @refresh_buffer_ms 60_000

  # -- Public API --

  @doc """
  Start an Auth process.

  ## Required options

  - `:provider` -- a `Raxol.ACP.ProviderAdapter.adapter()` used for
    `sign_typed_data/3`. Must be able to sign for the configured
    chain_id and the address you want to authenticate as.
  - `:server_url` -- e.g. `"https://api-dev.acp.virtuals.io"`.
  - `:chain_id` -- e.g. `8453`.

  ## Optional

  - `:req_options` -- extra options threaded into `Req.post/1` (e.g.
    `:plug` for stubbing).
  - `:name` -- if set, registers the GenServer under that name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Return a valid bearer JWT, refreshing if needed.

  Calls are serialized through the GenServer so concurrent callers
  share one network round-trip per refresh.
  """
  @spec token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def token(server), do: GenServer.call(server, :token, 30_000)

  @doc "Forget the current token so the next `token/1` re-authenticates."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server), do: GenServer.call(server, :invalidate)

  @doc "Inspect the current state (testing aid)."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server), do: GenServer.call(server, :get_state)

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      provider: Keyword.fetch!(opts, :provider),
      server_url: normalize_url(Keyword.fetch!(opts, :server_url)),
      chain_id: Keyword.fetch!(opts, :chain_id),
      req_options: Keyword.get(opts, :req_options, [])
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:token, _from, state) do
    case ensure_valid(state) do
      {:ok, %__MODULE__{token: t} = new_state} -> {:reply, {:ok, t}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:invalidate, _from, state) do
    {:reply, :ok, %{state | token: nil, expires_at_ms: nil}}
  end

  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  # -- Internals --

  defp ensure_valid(state) do
    if token_still_valid?(state) do
      {:ok, state}
    else
      authenticate(state)
    end
  end

  defp token_still_valid?(%__MODULE__{token: nil}), do: false
  defp token_still_valid?(%__MODULE__{expires_at_ms: nil}), do: false

  defp token_still_valid?(%__MODULE__{expires_at_ms: exp}) do
    System.system_time(:millisecond) + @refresh_buffer_ms < exp
  end

  defp authenticate(state) do
    issued_at = System.system_time(:millisecond)

    typed_data = build_auth_typed_data(state, issued_at)

    with {:ok, sig_bytes} <-
           ProviderAdapter.sign_typed_data(state.provider, state.chain_id, typed_data),
         signature_hex <- Hex.encode(sig_bytes),
         {:ok, %{"data" => %{"token" => token}}} <- post_auth(state, signature_hex, issued_at),
         {:ok, exp_ms} <- decode_jwt_exp_ms(token) do
      {:ok, %{state | token: token, expires_at_ms: exp_ms}}
    else
      {:error, reason} -> {:error, reason, %{state | token: nil, expires_at_ms: nil}}
      err -> {:error, {:auth_failed, err}, %{state | token: nil, expires_at_ms: nil}}
    end
  end

  defp build_auth_typed_data(state, issued_at_ms) do
    %{
      domain: %{
        name: "ACP",
        version: "1",
        chainId: state.chain_id
      },
      types: %{
        "AgentAuth" => [
          {"wallet", "address"},
          {"chainId", "uint256"},
          {"issuedAt", "uint256"}
        ]
      },
      message: %{
        "wallet" => ProviderAdapter.get_address(state.provider),
        "chainId" => state.chain_id,
        "issuedAt" => issued_at_ms
      }
    }
  end

  defp post_auth(state, signature_hex, issued_at_ms) do
    body = %{
      "walletAddress" => ProviderAdapter.get_address(state.provider),
      "signature" => signature_hex,
      "issuedAt" => issued_at_ms,
      "chainId" => state.chain_id
    }

    url = state.server_url <> "/auth/agent"
    opts = [url: url, json: body] ++ state.req_options

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp decode_jwt_exp_ms(jwt) do
    with [_, payload_b64, _] <- String.split(jwt, "."),
         {:ok, payload_json} <- decode_base64url(payload_b64),
         {:ok, %{"exp" => exp_seconds}} <- Jason.decode(payload_json) do
      {:ok, exp_seconds * 1000}
    else
      _ -> {:error, :invalid_jwt}
    end
  end

  defp decode_base64url(str) do
    padded =
      str
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      |> pad_base64()

    Base.decode64(padded)
  end

  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      n -> str <> String.duplicate("=", 4 - n)
    end
  end

  defp normalize_url(url), do: String.trim_trailing(url, "/")
end
