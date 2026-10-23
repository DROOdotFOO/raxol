defmodule Raxol.Payments.Xochi.ReadTokenStore do
  @moduledoc false

  # A read token is a bearer capability for one intent on one Xochi API. It is
  # keyed by the canonical API origin (scheme://host[:port], lowercased, default
  # port elided) as well as the intent id, so a checkpoint reused under another
  # `base_url` neither presents nor deletes the first origin's token.

  alias Raxol.Payments.{Checkpoint, Secret}
  alias Raxol.Payments.Xochi.Schemas.ExecuteResponse

  @spec put(Checkpoint.store() | nil, String.t(), String.t() | nil, term()) :: :ok
  def put(store, base_url, intent_id, token)
      when is_binary(intent_id) and intent_id != "" do
    if ExecuteResponse.read_token?(token) do
      Checkpoint.put(store, key(base_url, intent_id), %{secret: Secret.new(token)})
    else
      :ok
    end
  end

  def put(_store, _base_url, _intent_id, _token), do: :ok

  @spec fetch(Checkpoint.store() | nil, String.t(), String.t()) :: String.t() | nil
  def fetch(store, base_url, intent_id) when is_binary(intent_id) do
    case Checkpoint.fetch(store, key(base_url, intent_id)) do
      {:ok, %{secret: %Secret{} = secret}} -> Secret.reveal(secret)
      _ -> nil
    end
  end

  @spec delete(Checkpoint.store() | nil, String.t(), String.t()) :: :ok
  def delete(store, base_url, intent_id) when is_binary(intent_id),
    do: Checkpoint.delete(store, key(base_url, intent_id))

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

  defp key(base_url, intent_id),
    do: Checkpoint.derive_key([:xochi_read_token, origin(base_url), intent_id])
end
