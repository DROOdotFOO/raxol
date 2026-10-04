defmodule Raxol.Agent.Auth.Robinhood do
  @moduledoc """
  Robinhood's agent MCP OAuth: RFC 9728/8414 discovery, RFC 7591 dynamic
  client registration, the PKCE authorization-code grant and refresh.

  Every endpoint is a compile-time constant. Discovery is fetched and
  VERIFIED against these pins -- a mismatch is `{:error, :metadata_mismatch}`
  -- but it never supplies a URL: the authorization and token endpoints are on
  different hosts from the issuer, so "same origin as the issuer" is not a
  check that could stand in for pinning.

  `Raxol.Agent.Auth.Flow.run(:robinhood, opts)` drives the whole sign-in and
  returns a `Raxol.Agent.Auth.Credential`; storing it is the caller's job
  (`raxol_broker` encrypts it at rest). `refresh/2` is the refresh grant.

  ## The `:http_fn` seam

  `(url, body, opts) -> {:ok, %{status: integer, body: term}} | {:error, term}`
  where `body` is `:get`, `{:json, map}` or `{:form, map}`. The default uses
  Req with redirects and retries off: a 3xx must never replay a code, a
  verifier or a refresh token at another URL, and a retried refresh grant
  could present a token the server already rotated.

  ## Errors

  A closed set, none of which carries a response body, a token, or a code:
  `:metadata_mismatch`, `{:discovery_failed, status}`,
  `{:registration_rejected, status}`, `:registration_invalid`,
  `{:token_rejected, status, oauth_error}` (`oauth_error` is one of
  `#{inspect([:invalid_request, :invalid_client, :invalid_grant, :unauthorized_client, :unsupported_grant_type, :invalid_scope, :invalid_target, :other])}`),
  `:token_response_invalid`, `:no_refresh_token`, `{:unreachable, kind}` and
  `:no_http_client`.
  """

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Agent.Auth.Pkce

  @issuer "https://agent.robinhood.com/mcp/trading"
  @resource "https://agent.robinhood.com/mcp/trading"
  @resource_metadata_url "https://agent.robinhood.com/.well-known/oauth-protected-resource/mcp/trading"
  @server_metadata_url "https://agent.robinhood.com/.well-known/oauth-authorization-server"
  @authorization_endpoint "https://robinhood.com/oauth"
  @token_endpoint "https://api.robinhood.com/oauth2/token/"
  @registration_endpoint "https://agent.robinhood.com/oauth/trading/register"
  @scope "internal"
  @client_name "Raxol"

  @oauth_errors %{
    "invalid_request" => :invalid_request,
    "invalid_client" => :invalid_client,
    "invalid_grant" => :invalid_grant,
    "unauthorized_client" => :unauthorized_client,
    "unsupported_grant_type" => :unsupported_grant_type,
    "invalid_scope" => :invalid_scope,
    "invalid_target" => :invalid_target
  }

  # The client id goes into URLs and the encrypted store; bound it.
  @client_id_format ~r/\A[A-Za-z0-9._~-]{1,255}\z/

  @default_timeout 30_000

  @doc "The pinned issuer, also the value the callback's `iss` must equal."
  @spec issuer() :: String.t()
  def issuer, do: @issuer

  @doc "The MCP resource the tokens are for (RFC 8707), also the MCP URL."
  @spec resource() :: String.t()
  def resource, do: @resource

  @doc "A fresh `state` value: 32 random bytes, base64url."
  @spec new_state() :: String.t()
  def new_state, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc """
  Fetch the protected-resource and authorization-server metadata and check
  them against the pins. `:ok` or `{:error, reason}`.
  """
  @spec discover(keyword()) :: :ok | {:error, term()}
  def discover(opts \\ []) do
    with {:ok, prm} <- fetch_metadata(@resource_metadata_url, opts),
         :ok <- verify_resource(prm),
         {:ok, asm} <- fetch_metadata(@server_metadata_url, opts) do
      verify_server(asm)
    end
  end

  defp fetch_metadata(url, opts) do
    case http(opts).(url, :get, opts) do
      {:ok, %{status: status, body: %{} = body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} when status in 200..299 -> {:error, :metadata_mismatch}
      {:ok, %{status: status}} -> {:error, {:discovery_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_resource(%{"resource" => @resource, "authorization_servers" => servers})
       when is_list(servers) do
    if @issuer in servers, do: :ok, else: {:error, :metadata_mismatch}
  end

  defp verify_resource(_other), do: {:error, :metadata_mismatch}

  defp verify_server(%{
         "issuer" => @issuer,
         "authorization_endpoint" => @authorization_endpoint,
         "token_endpoint" => @token_endpoint,
         "registration_endpoint" => @registration_endpoint,
         "code_challenge_methods_supported" => challenge_methods,
         "token_endpoint_auth_methods_supported" => auth_methods,
         "authorization_response_iss_parameter_supported" => true
       })
       when is_list(challenge_methods) and is_list(auth_methods) do
    if "S256" in challenge_methods and "none" in auth_methods,
      do: :ok,
      else: {:error, :metadata_mismatch}
  end

  defp verify_server(_other), do: {:error, :metadata_mismatch}

  @doc """
  Register a public client for `redirect_uri` and return its `client_id`.

  The response must echo exactly `[redirect_uri]` and the `none` auth method;
  anything else is `{:error, :registration_invalid}`.
  """
  @spec register(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register(redirect_uri, opts \\ []) when is_binary(redirect_uri) do
    body = %{
      "client_name" => @client_name,
      "redirect_uris" => [redirect_uri],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }

    case http(opts).(@registration_endpoint, {:json, body}, opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        verify_registration(response, redirect_uri)

      {:ok, %{status: status}} ->
        {:error, {:registration_rejected, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_registration(
         %{
           "client_id" => client_id,
           "redirect_uris" => [redirect_uri],
           "token_endpoint_auth_method" => "none"
         },
         redirect_uri
       )
       when is_binary(client_id) do
    if Regex.match?(@client_id_format, client_id),
      do: {:ok, client_id},
      else: {:error, :registration_invalid}
  end

  defp verify_registration(_response, _redirect_uri), do: {:error, :registration_invalid}

  @doc "The URL to open in the user's browser."
  @spec authorize_url(String.t(), String.t(), Pkce.t(), String.t()) :: String.t()
  def authorize_url(client_id, redirect_uri, %Pkce{} = pkce, state) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_challenge" => pkce.challenge,
        "code_challenge_method" => pkce.method,
        "state" => state,
        "scope" => @scope,
        "resource" => @resource
      })

    @authorization_endpoint <> "?" <> query
  end

  @doc """
  Redeem an authorization code. `redirect_uri` must be the string that was
  registered and authorized. `:now` (a `DateTime`) fixes the clock
  `expires_at` is computed from.
  """
  @spec exchange(String.t(), Pkce.t(), String.t(), String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def exchange(code, %Pkce{} = pkce, client_id, redirect_uri, opts \\ []) when is_binary(code) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id,
      "code_verifier" => pkce.verifier,
      "resource" => @resource
    }

    with {:ok, body} <- token_request(form, opts) do
      credential(body, client_id, nil, opts)
    end
  end

  @doc """
  Run the refresh grant. Robinhood rotates the refresh token, so the returned
  credential carries the NEW one and the old must be treated as consumed:
  persist the result before using it.
  """
  @spec refresh(Credential.t(), keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def refresh(credential, opts \\ [])

  def refresh(%Credential{refresh_token: token}, _opts) when token in [nil, ""],
    do: {:error, :no_refresh_token}

  def refresh(%Credential{} = credential, opts) do
    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => credential.refresh_token,
      "client_id" => credential.client_id
    }

    with {:ok, body} <- token_request(form, opts) do
      credential(body, credential.client_id, credential.refresh_token, opts)
    end
  end

  defp token_request(form, opts) do
    case http(opts).(@token_endpoint, {:form, form}, opts) do
      {:ok, %{status: status, body: %{} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, :token_response_invalid}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_rejected, status, oauth_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp oauth_error(%{"error" => code}) when is_binary(code),
    do: Map.get(@oauth_errors, code, :other)

  defp oauth_error(_body), do: :other

  defp credential(body, client_id, prior, opts) do
    case token_fields(body, prior, opts) do
      {:ok, fields} ->
        {:ok,
         struct!(
           Credential,
           [provider: :robinhood, issuer: @issuer, client_id: client_id] ++ fields
         )}

      _invalid ->
        {:error, :token_response_invalid}
    end
  end

  defp token_fields(%{"access_token" => access} = body, prior, opts)
       when is_binary(access) and access != "" do
    with :ok <- bearer_type(body["token_type"]),
         {:ok, expires_at} <- expires_at(body["expires_in"], opts),
         {:ok, refresh} <- refresh_token(body["refresh_token"], prior),
         {:ok, strings} <- optional_strings(body) do
      {:ok, [access_token: access, refresh_token: refresh, expires_at: expires_at] ++ strings}
    end
  end

  defp token_fields(_body, _prior, _opts), do: :error

  defp bearer_type(type) when is_binary(type) do
    if String.downcase(type) == "bearer", do: :ok, else: :error
  end

  defp bearer_type(_type), do: :error

  defp expires_at(nil, _opts), do: {:ok, nil}

  defp expires_at(seconds, opts) when is_integer(seconds) and seconds > 0 do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    {:ok, DateTime.add(now, seconds, :second)}
  end

  defp expires_at(_invalid, _opts), do: :error

  # A refresh response without a refresh token leaves the current one in
  # force (RFC 6749 section 6); a code exchange has no prior to keep.
  defp refresh_token(token, _prior) when is_binary(token) and token != "", do: {:ok, token}
  defp refresh_token(nil, prior), do: {:ok, prior}
  defp refresh_token(_invalid, _prior), do: :error

  # `scope` and `user_uuid` are optional, but a non-string is a malformed response.
  defp optional_strings(body) do
    fields = [scope: body["scope"], user_uuid: body["user_uuid"]]

    if Enum.all?(fields, fn {_key, value} -> is_nil(value) or is_binary(value) end),
      do: {:ok, fields},
      else: :error
  end

  # -- default transport ------------------------------------------------------

  defp http(opts), do: Keyword.get(opts, :http_fn, &request/3)

  defp request(url, body, opts) do
    if Code.ensure_loaded?(Req) do
      timeout = Keyword.get(opts, :http_timeout, @default_timeout)
      send_request(url, body, timeout)
    else
      {:error, :no_http_client}
    end
  end

  defp send_request(url, body, timeout) do
    base = [url: url, redirect: false, retry: false, receive_timeout: timeout]

    req_opts =
      case body do
        :get -> [method: :get] ++ base
        {:json, map} -> [method: :post, json: map] ++ base
        {:form, map} -> [method: :post, form: map] ++ base
      end

    case Req.request(req_opts) do
      {:ok, %{status: status, body: decoded}} -> {:ok, %{status: status, body: decoded}}
      {:error, reason} -> {:error, {:unreachable, error_kind(reason)}}
    end
  rescue
    error -> {:error, {:unreachable, error_kind(error)}}
  end

  defp error_kind(%{__struct__: module}), do: module
end
