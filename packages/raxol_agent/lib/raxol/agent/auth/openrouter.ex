defmodule Raxol.Agent.Auth.OpenRouter do
  @moduledoc """
  OpenRouter's OAuth PKCE flow: the one browser sign-in raxol can honestly run
  for a user.

  It is the only provider among the supported backends whose OAuth is built for
  third-party local applications -- no client registration, no client secret,
  the loopback callback URL is the whole identity of the app. Anthropic and
  OpenAI have no public equivalent; their sign-in flows belong to their own
  first-party clients, and driving one with a borrowed client id would be
  impersonation that breaks the moment they rotate it. So this is the provider
  Agent Auth advertises, and everything else stays on Terminal Auth.

  What comes back is a user-controlled **API key**, not a bearer token with an
  expiry. That is why this needed no new secret storage: the key goes straight
  through `Raxol.Agent.Setup.connect_key/3` into a 1Password item, exactly like
  a pasted one, and only the `op://` reference reaches
  `~/.raxol/providers.json`. No refresh loop, no token at rest.

  The `:http_fn` seam is injectable so the exchange is testable without a
  network call.
  """

  alias Raxol.Agent.Auth.Pkce

  @authorize_url "https://openrouter.ai/auth"
  @keys_url "https://openrouter.ai/api/v1/auth/keys"

  @default_timeout 30_000

  @doc "The URL to open in the user's browser."
  @spec authorize_url(Pkce.t(), String.t()) :: String.t()
  def authorize_url(%Pkce{} = pkce, redirect_uri)
      when is_binary(redirect_uri) do
    query =
      URI.encode_query(%{
        "callback_url" => redirect_uri,
        "code_challenge" => pkce.challenge,
        "code_challenge_method" => pkce.method
      })

    @authorize_url <> "?" <> query
  end

  @doc """
  Exchange an authorization code for a user-controlled API key.

  Returns `{:ok, key}` or `{:error, reason}`. No reason this returns carries
  the key or the verifier -- they must not reach a log or an ACP error
  message.
  """
  @spec exchange(String.t(), Pkce.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def exchange(code, %Pkce{} = pkce, opts \\ []) when is_binary(code) do
    http_fn = Keyword.get(opts, :http_fn, &post_json/3)

    body = %{
      "code" => code,
      "code_verifier" => pkce.verifier,
      "code_challenge_method" => pkce.method
    }

    case http_fn.(@keys_url, body, opts) do
      {:ok, %{"key" => key}} when is_binary(key) and key != "" ->
        {:ok, key}

      {:ok, decoded} when is_map(decoded) ->
        {:error, {:no_key_in_response, Map.keys(decoded)}}

      {:ok, _other} ->
        {:error, :no_key_in_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The endpoint the code is exchanged at, for tests and diagnostics."
  @spec keys_url() :: String.t()
  def keys_url, do: @keys_url

  # -- default transport ------------------------------------------------------

  defp post_json(url, body, opts) do
    if Code.ensure_loaded?(Req) do
      timeout = Keyword.get(opts, :http_timeout, @default_timeout)
      request(url, body, timeout)
    else
      {:error, :no_http_client}
    end
  end

  defp request(url, body, timeout) do
    req = Req.new(url: url, json: body, receive_timeout: timeout)

    case Req.post(req) do
      {:ok, %{status: status, body: decoded}} when status in 200..299 ->
        {:ok, decoded}

      # Deliberately status-only: an error body is provider-controlled and
      # this reason ends up in an ACP error message.
      {:ok, %{status: status}} ->
        {:error, {:exchange_rejected, status}}

      {:error, reason} ->
        {:error, {:exchange_unreachable, error_kind(reason)}}
    end
  rescue
    error -> {:error, {:exchange_unreachable, error_kind(error)}}
  end

  defp error_kind(%{__struct__: module}), do: module
  defp error_kind(other), do: other
end
