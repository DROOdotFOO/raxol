defmodule Raxol.Broker.KeyProvider.OnePassword do
  @moduledoc """
  The credential-wrapping key as a 1Password item, through the same `op://`
  path model-provider keys use (`Raxol.Agent.Backend.Credentials`).

  Only the KEY lives in 1Password. The rotating tokens stay in the encrypted
  file, so a refresh (which rotates the refresh token) never needs an
  `op item edit` and never raises a desktop approval prompt; reading the key
  may.

  The key is created as an item via `Credentials.create_item/3` (a 0600
  template file, never argv) and its `op://` reference is recorded under
  `robinhood_broker_key` in `~/.raxol/providers.json`. Options:
  `:timeout_ms`, `:vault`.
  """

  @behaviour Raxol.Broker.KeyProvider

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Broker.KeyProvider

  @entry "robinhood_broker_key"

  @impl true
  def load_key(opts) do
    case Credentials.fetch(@entry) do
      {:ok, %{op_ref: ref}} -> read(ref, opts)
      _none -> :none
    end
  end

  @impl true
  def create_key(opts) do
    case load_key(opts) do
      :none -> create(opts)
      other -> other
    end
  end

  defp create(opts) do
    key = :crypto.strong_rand_bytes(32)
    item_opts = Keyword.take(opts, [:timeout_ms, :vault])

    with {:ok, ref} <-
           Credentials.create_item(@entry, Base.encode16(key, case: :lower), item_opts),
         :ok <- Credentials.put(@entry, op_ref: ref) do
      {:ok, key}
    else
      {:error, reason} -> {:error, {:key_unavailable, op_reason(reason)}}
    end
  end

  defp read(ref, opts) do
    case Credentials.read_ref(ref, Keyword.take(opts, [:timeout_ms])) do
      {:ok, hex} ->
        case KeyProvider.decode_hex(hex) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, {:key_unavailable, :malformed_key}}
        end

      {:error, reason} ->
        {:error, {:key_unavailable, op_reason(reason)}}
    end
  end

  # `op` failures carry its stderr; keep the exit code only.
  defp op_reason({:op_failed, code, _output}), do: {:op_failed, code}
  defp op_reason({:op_create_failed, code, _output}), do: {:op_create_failed, code}
  defp op_reason(reason), do: reason
end
