defmodule Raxol.Payments.Xochi.ReadTokenStore do
  @moduledoc false

  alias Raxol.Payments.{Checkpoint, Secret}
  alias Raxol.Payments.Xochi.Schemas.ExecuteResponse

  @spec put(Checkpoint.store() | nil, String.t() | nil, term()) :: :ok
  def put(store, intent_id, token)
      when is_binary(intent_id) and intent_id != "" do
    if ExecuteResponse.read_token?(token) do
      Checkpoint.put(store, key(intent_id), %{secret: Secret.new(token)})
    else
      :ok
    end
  end

  def put(_store, _intent_id, _token), do: :ok

  @spec fetch(Checkpoint.store() | nil, String.t()) :: String.t() | nil
  def fetch(store, intent_id) when is_binary(intent_id) do
    case Checkpoint.fetch(store, key(intent_id)) do
      {:ok, %{secret: %Secret{} = secret}} -> Secret.reveal(secret)
      _ -> nil
    end
  end

  @spec delete(Checkpoint.store() | nil, String.t()) :: :ok
  def delete(store, intent_id) when is_binary(intent_id),
    do: Checkpoint.delete(store, key(intent_id))

  defp key(intent_id), do: Checkpoint.derive_key([:xochi_read_token, intent_id])
end
