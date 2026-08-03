defmodule Raxol.Payments.Relay.Broadcaster do
  @moduledoc """
  Behaviour for funding a Relay deposit by broadcasting an on-chain token
  transfer to the Riddler-managed deposit address (the "B" backstop, used when
  the gasless pull is unavailable; see axol-io/Riddler#120).

  raxol's `Wallet` signs but does not broadcast, and the proven EVM transaction
  stack (EIP-1559 signing, RLP, nonce, JSON-RPC submit) lives in `raxol_earn`,
  which depends on this package. So rather than duplicate fund-moving transaction
  code here, the deposit broadcast is injected: a caller that can see that stack
  supplies a module implementing this behaviour, and `ExecuteRelayTransfer` uses
  it when present.

  Implementations must be **idempotent on `transfer_id`**: a retried call for the
  same logical transfer must not double-send.
  """

  @type params :: %{
          required(:transfer_id) => String.t(),
          required(:chain_id) => pos_integer(),
          required(:token) => String.t(),
          required(:to) => String.t(),
          required(:amount_atomic) => String.t(),
          optional(:wallet) => module(),
          optional(atom()) => term()
        }

  @doc """
  Broadcast a token transfer of `amount_atomic` of `token` to the deposit address
  `to` on `chain_id`. Returns the source-chain transaction hash.
  """
  @callback send_deposit(params()) :: {:ok, String.t()} | {:error, term()}
end
