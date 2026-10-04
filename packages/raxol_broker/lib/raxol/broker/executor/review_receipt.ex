defmodule Raxol.Broker.Executor.ReviewReceipt do
  @moduledoc """
  Proof that an order's `review_*` call ran and was journaled, bound to one
  intent id and one journal group.

  The struct is opaque and carries an HMAC-SHA256 over the intent id, group
  id, a digest of the review response and a random nonce, under a key the
  executor generates at start and keeps only in its state. Building the
  struct by hand, copying one to another intent or group, or keeping one
  across an executor restart (the key rotates) all fail `verify/4`. The
  executor also records each nonce it spends, so a receipt is good for one
  order call.

  The key is not secret from code running in the same VM with `:sys`
  access; it stops a module from minting a receipt by construction, not an
  attacker who already owns the node.
  """

  @enforce_keys [:intent_id, :group_id, :digest, :nonce, :mac]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            intent_id: String.t(),
            group_id: String.t(),
            digest: binary(),
            nonce: binary(),
            mac: binary()
          }

  @doc false
  # Called only by `Raxol.Broker.Executor`'s review stage, with its key.
  @spec issue(binary(), String.t(), String.t(), map()) :: t()
  def issue(key, intent_id, group_id, review) when is_binary(key) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(review, [:deterministic]))
    nonce = :crypto.strong_rand_bytes(16)

    %__MODULE__{
      intent_id: intent_id,
      group_id: group_id,
      digest: digest,
      nonce: nonce,
      mac: mac(key, intent_id, group_id, digest, nonce)
    }
  end

  @doc """
  `{:ok, nonce}` when `receipt` was issued under `key` for exactly this
  intent id and group id; `{:error, :invalid_receipt}` otherwise.
  """
  @spec verify(term(), binary(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :invalid_receipt}
  def verify(
        %__MODULE__{intent_id: intent_id, group_id: group_id} = receipt,
        key,
        intent_id,
        group_id
      )
      when is_binary(key) and is_binary(receipt.digest) and is_binary(receipt.nonce) and
             is_binary(receipt.mac) do
    expected = mac(key, intent_id, group_id, receipt.digest, receipt.nonce)

    if :crypto.hash_equals(expected, receipt.mac),
      do: {:ok, receipt.nonce},
      else: {:error, :invalid_receipt}
  rescue
    ArgumentError -> {:error, :invalid_receipt}
  end

  def verify(_receipt, _key, _intent_id, _group_id), do: {:error, :invalid_receipt}

  defp mac(key, intent_id, group_id, digest, nonce) do
    message = :erlang.term_to_binary({intent_id, group_id, digest, nonce}, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, message)
  end

  defimpl Inspect do
    def inspect(receipt, _opts) do
      "#Raxol.Broker.Executor.ReviewReceipt<intent: #{inspect(receipt.intent_id)}, " <>
        "group: #{inspect(receipt.group_id)}>"
    end
  end
end
