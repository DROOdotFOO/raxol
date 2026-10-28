defmodule Raxol.Payments.Xochi.ReadTokenStore do
  @moduledoc false

  # A read token is a bearer capability for one intent, principal and Xochi API.
  # The principal binding prevents a model turn or another agent sharing the
  # checkpoint store from presenting someone else's capability.

  alias Raxol.Payments.{Checkpoint, Secret}
  alias Raxol.Payments.Xochi.Schemas.ExecuteResponse

  @token_ttl_seconds 3_600

  @spec put(
          Checkpoint.store() | nil,
          String.t(),
          String.t(),
          String.t() | nil,
          term(),
          integer()
        ) :: :ok
  def put(store, base_url, principal, intent_id, token, now)
      when is_binary(principal) and is_binary(intent_id) and intent_id != "" do
    if ExecuteResponse.read_token?(token) do
      Checkpoint.put(store, key(base_url, principal, intent_id), %{
        kind: :xochi_read_token,
        principal: principal,
        intent_id: intent_id,
        secret: Secret.new(token),
        expires_at: now + @token_ttl_seconds
      })
    else
      :ok
    end
  end

  def put(_store, _base_url, _principal, _intent_id, _token, _now), do: :ok

  @spec fetch(Checkpoint.store() | nil, String.t(), String.t() | nil, String.t(), integer()) ::
          String.t() | nil
  def fetch(_store, _base_url, nil, _intent_id, _now), do: nil

  def fetch(store, base_url, principal, intent_id, now) when is_binary(intent_id) do
    Checkpoint.sweep_expired(store, now)

    case Checkpoint.fetch(store, key(base_url, principal, intent_id)) do
      {:ok, %{principal: ^principal, secret: %Secret{} = secret}} -> Secret.reveal(secret)
      _ -> nil
    end
  end

  @spec delete(Checkpoint.store() | nil, String.t(), String.t(), String.t()) :: :ok
  def delete(store, base_url, principal, intent_id) when is_binary(intent_id),
    do: Checkpoint.delete(store, key(base_url, principal, intent_id))

  @doc false
  @spec origin(String.t()) :: String.t()
  def origin(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)
        host = String.downcase(host)

        if port in [nil, URI.default_port(scheme)],
          do: "#{scheme}://#{host}",
          else: "#{scheme}://#{host}:#{port}"

      _ ->
        raise ArgumentError, "Xochi read token store requires an absolute base_url"
    end
  end

  defp key(base_url, principal, intent_id),
    do: Checkpoint.derive_key([:xochi_read_token, origin(base_url), principal, intent_id])
end
