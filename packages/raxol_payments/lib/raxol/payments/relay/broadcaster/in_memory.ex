defmodule Raxol.Payments.Relay.Broadcaster.InMemory do
  @moduledoc """
  Deterministic in-memory `Raxol.Payments.Relay.Broadcaster` for tests.

  Records each broadcast in the process dictionary (keyed by `transfer_id`, so a
  retry returns the same hash) and returns a synthetic tx hash. Set
  `:relay_broadcaster_fail` in the process dictionary to make it return an error.
  """

  @behaviour Raxol.Payments.Relay.Broadcaster

  @impl true
  def send_deposit(%{transfer_id: transfer_id} = params) do
    cond do
      reason = Process.get(:relay_broadcaster_fail) ->
        {:error, reason}

      existing = lookup(transfer_id) ->
        {:ok, existing}

      true ->
        hash = "0xdeposit_" <> transfer_id
        record(transfer_id, Map.put(params, :tx_hash, hash))
        {:ok, hash}
    end
  end

  @doc "All broadcasts recorded this process, newest last."
  @spec sent() :: [map()]
  def sent, do: Process.get(:relay_broadcasts, [])

  defp lookup(transfer_id) do
    Enum.find_value(sent(), fn b -> if b.transfer_id == transfer_id, do: b.tx_hash end)
  end

  defp record(_transfer_id, entry) do
    Process.put(:relay_broadcasts, sent() ++ [entry])
  end
end
