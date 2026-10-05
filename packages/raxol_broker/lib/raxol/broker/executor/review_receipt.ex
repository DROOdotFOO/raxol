defmodule Raxol.Broker.Executor.ReviewReceipt do
  @moduledoc """
  Proof that an order's review stage ran, bound to one whole intent and one
  journal group.

  The struct is opaque and carries an HMAC-SHA256 over a fingerprint of the
  intent (SHA-256 of its deterministic external term form, so every field
  counts, not only the id), the intent id, the group id and a random nonce,
  under a key the executor generates at start. Building the struct by hand,
  using one for a different intent (even one with the same id and a
  different quantity) or group, or keeping one across an executor restart
  (the key rotates) all fail `verify/4`.

  `verify/4` takes the key as an argument, so on its own it proves only that
  whoever holds the key issued the receipt. Anyone can mint a receipt under
  a key of their own. What makes a receipt mean "the executor reviewed
  this" is the caller: `Raxol.Broker.Executor.Place.run/4` never takes a key
  from its arguments; it verifies under `Raxol.Broker.Executor.receipt_key/0`,
  which reads the calling process's dictionary and is nil anywhere except
  the executor process, which puts its key there in `init/1`.

  Single use is not this module's job: the journal takes one `placing`
  record per group and refuses a second live `placing` for an intent id.

  ## Threat model

  The guarantee is that no path through public APIs places an order without
  the executor's review pipeline. The BEAM cannot stop code that
  deliberately writes into another module's private state: a process that
  puts a key into the executor's process-dictionary slot (and its
  `:"$initial_call"`, to take the journal claim), or reads the key out of
  the executor with `:sys` or `Process.info/2`, can mint and spend receipts.
  Every such bypass requires impersonating the executor's private slots on
  purpose; `Raxol.Broker.Test.ExecutorIdentity` does exactly that, and only
  in tests.
  """

  alias Raxol.Broker.Intent

  @enforce_keys [:intent_id, :group_id, :nonce, :mac]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            intent_id: String.t(),
            group_id: String.t(),
            nonce: binary(),
            mac: binary()
          }

  @doc false
  # Called only by `Raxol.Broker.Executor`'s review stage, with its key.
  @spec issue(binary(), Intent.t(), String.t()) :: t()
  def issue(key, %Intent{id: intent_id} = intent, group_id)
      when is_binary(key) and is_binary(group_id) do
    nonce = :crypto.strong_rand_bytes(16)

    %__MODULE__{
      intent_id: intent_id,
      group_id: group_id,
      nonce: nonce,
      mac: mac(key, intent, group_id, nonce)
    }
  end

  @doc """
  `:ok` when `receipt` was issued under `key` for exactly this intent (every
  field) and group id; `{:error, :invalid_receipt}` otherwise.
  """
  @spec verify(term(), binary(), Intent.t(), String.t()) :: :ok | {:error, :invalid_receipt}
  def verify(
        %__MODULE__{intent_id: intent_id, group_id: group_id, nonce: nonce, mac: given},
        key,
        %Intent{id: intent_id} = intent,
        group_id
      )
      when is_binary(key) and is_binary(nonce) and is_binary(given) do
    if :crypto.hash_equals(mac(key, intent, group_id, nonce), given),
      do: :ok,
      else: {:error, :invalid_receipt}
  rescue
    ArgumentError -> {:error, :invalid_receipt}
  end

  def verify(_receipt, _key, _intent, _group_id), do: {:error, :invalid_receipt}

  defp mac(key, %Intent{id: intent_id} = intent, group_id, nonce) do
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(intent, [:deterministic]))
    message = :erlang.term_to_binary({fingerprint, intent_id, group_id, nonce}, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, message)
  end

  defimpl Inspect do
    def inspect(receipt, _opts) do
      "#Raxol.Broker.Executor.ReviewReceipt<intent: #{inspect(receipt.intent_id)}, " <>
        "group: #{inspect(receipt.group_id)}>"
    end
  end
end
