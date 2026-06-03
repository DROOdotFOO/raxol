defmodule Raxol.Payments.Protocol do
  @moduledoc """
  Behaviour for payment protocol implementations.

  Each protocol handles a specific 402 payment flow. The auto-pay plugin
  tries each configured protocol's `detect?/2` to find one that matches
  the server's 402 response, then delegates signing to that protocol.

  ## Implementations

  - `Raxol.Payments.Protocols.X402` -- Coinbase x402 (ERC-3009)
  - `Raxol.Payments.Protocols.MPP` -- Stripe/Tempo Machine Payments Protocol
  - `Raxol.Payments.Protocols.Riddler` -- cross-chain intents (deprecated, delegates to Xochi)
  - `Raxol.Payments.Protocols.Xochi` -- cross-chain private payments (agent-facing)
  """

  @type headers :: [{String.t(), String.t()}]
  @type challenge :: map()
  @type receipt :: map()

  @doc """
  Check if this protocol can handle the given 402 response.

  Inspects the response status and headers to determine if this
  protocol's payment flow applies.
  """
  @callback detect?(status :: integer(), headers :: headers()) :: boolean()

  @doc """
  Parse the 402 response headers into a challenge map.

  Extracts payment requirements (price, currency, recipient, network)
  from the protocol-specific headers.
  """
  @callback parse_challenge(headers :: headers()) ::
              {:ok, challenge()} | {:error, term()}

  @doc """
  Build authorization headers for the payment.

  Signs the challenge using the provided wallet module and returns
  headers to attach to the retry request.
  """
  @callback build_payment(challenge :: challenge(), wallet :: module()) ::
              {:ok, headers()} | {:error, term()}

  @doc """
  Parse the payment receipt from a successful response.

  Extracts confirmation details (tx hash, amount settled, etc.)
  from the response headers after a successful paid request.
  """
  @callback parse_receipt(headers :: headers()) ::
              {:ok, receipt()} | {:error, term()}

  @doc """
  Extract the payment amount from a parsed challenge.

  Returns the amount in **human-decimal units** (e.g. `1.00` means
  $1.00 USDC, not `1_000_000` atomic units). Implementations are
  expected to normalize via `Raxol.Payments.Assets.to_human/2` using
  the challenge's asset metadata. The `SpendingPolicy` caps are
  written in the same units.
  """
  @callback amount(challenge :: challenge()) :: Decimal.t()

  @doc "Human-readable protocol name."
  @callback name() :: String.t()

  @doc """
  Resolve a protocol atom to its implementation module.
  """
  @spec resolve(atom()) :: module()
  def resolve(:x402), do: Raxol.Payments.Protocols.X402
  def resolve(:mpp), do: Raxol.Payments.Protocols.MPP
  def resolve(:riddler), do: Raxol.Payments.Protocols.Riddler
  def resolve(:xochi), do: Raxol.Payments.Protocols.Xochi

  def resolve(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :detect?, 2) do
      module
    else
      raise ArgumentError, "unknown payment protocol: #{inspect(module)}"
    end
  end
end
