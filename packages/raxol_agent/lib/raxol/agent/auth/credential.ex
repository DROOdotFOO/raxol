defmodule Raxol.Agent.Auth.Credential do
  @moduledoc """
  An OAuth bearer credential minted by a browser sign-in that issues expiring
  tokens rather than an API key (today: `Raxol.Agent.Auth.Robinhood`).

  The struct holds live secrets, so it is deliberately hard to leak:

    * `Inspect` prints only the provider, client id, expiry and scope;
      the access token, the refresh token and `user_uuid` (an account
      identifier) are always `"[REDACTED]"`.
    * There is no `Jason.Encoder`. `dump/1` and `load/1` are the only
      serialization, and they exist for the encrypted store that persists
      this struct; nothing else should call them.

  `expires_at` is computed from the token response's `expires_in` at the
  moment the response is parsed, and is `nil` when the server sent none: an
  absent expiry is represented, never guessed.
  """

  @enforce_keys [:provider, :client_id, :access_token]
  defstruct [
    :provider,
    :issuer,
    :client_id,
    :access_token,
    :refresh_token,
    :expires_at,
    :scope,
    :user_uuid
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          issuer: String.t() | nil,
          client_id: String.t(),
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          scope: String.t() | nil,
          user_uuid: String.t() | nil
        }

  @providers %{"robinhood" => :robinhood}

  @doc """
  Whether the access token is past (or within `skew_seconds` of) its expiry.
  A credential without an expiry never reports itself expired.
  """
  @spec expired?(t(), DateTime.t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now, _skew), do: false

  def expired?(%__MODULE__{expires_at: %DateTime{} = at}, %DateTime{} = now, skew) do
    DateTime.compare(DateTime.add(now, skew, :second), at) != :lt
  end

  @doc "The `Authorization` header value for this credential."
  @spec bearer(t()) :: String.t()
  def bearer(%__MODULE__{access_token: token}), do: "Bearer " <> token

  @doc """
  The plain map the encrypted store serializes. Secrets included: callers
  must encrypt it before it leaves memory.
  """
  @spec dump(t()) :: %{String.t() => term()}
  def dump(%__MODULE__{} = c) do
    %{
      "provider" => Atom.to_string(c.provider),
      "issuer" => c.issuer,
      "client_id" => c.client_id,
      "access_token" => c.access_token,
      "refresh_token" => c.refresh_token,
      "expires_at" => c.expires_at && DateTime.to_iso8601(c.expires_at),
      "scope" => c.scope,
      "user_uuid" => c.user_uuid
    }
  end

  @doc """
  Rebuild a credential from `dump/1`'s map. `{:error, :malformed_credential}`
  for any other shape; the error never carries the input.
  """
  @spec load(term()) :: {:ok, t()} | {:error, :malformed_credential}
  def load(%{"provider" => provider, "client_id" => client_id, "access_token" => token} = map)
      when is_binary(client_id) and client_id != "" and is_binary(token) and token != "" do
    with {:ok, provider} <- Map.fetch(@providers, provider),
         {:ok, expires_at} <- load_time(map["expires_at"]),
         true <- optional_strings?(map, ["issuer", "refresh_token", "scope", "user_uuid"]) do
      {:ok,
       %__MODULE__{
         provider: provider,
         issuer: map["issuer"],
         client_id: client_id,
         access_token: token,
         refresh_token: map["refresh_token"],
         expires_at: expires_at,
         scope: map["scope"],
         user_uuid: map["user_uuid"]
       }}
    else
      _invalid -> {:error, :malformed_credential}
    end
  end

  def load(_other), do: {:error, :malformed_credential}

  defp load_time(nil), do: {:ok, nil}

  defp load_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp load_time(_other), do: :error

  defp optional_strings?(map, keys) do
    Enum.all?(keys, fn key -> is_nil(map[key]) or is_binary(map[key]) end)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(credential, opts) do
      fields = [
        provider: credential.provider,
        client_id: credential.client_id,
        access_token: "[REDACTED]",
        refresh_token: "[REDACTED]",
        user_uuid: "[REDACTED]",
        expires_at: credential.expires_at,
        scope: credential.scope
      ]

      concat(["#Raxol.Agent.Auth.Credential<", to_doc(fields, opts), ">"])
    end
  end
end
