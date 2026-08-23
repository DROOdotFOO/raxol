defmodule Raxol.Payments.Protocols.Permit2 do
  @moduledoc """
  Permit2 `PermitWitnessTransferFrom` signing for Riddler's `/order`
  endpoint.

  Like Xochi, Permit2 is direct-API (not HTTP 402). Riddler returns a
  quote with `gasless.orderId`; the client signs a
  `PermitWitnessTransferFrom` whose `OriginPullWitness` binds that
  orderId into the digest. The Permit2 contract verifies the signature
  on-chain when the solver calls `permitWitnessTransferFrom`.

  Mirrors `riddler-client/src/signing.js#signPermit2`. The EIP-712
  domain has no `version` field (Permit2 deployed without versioning); the
  `verifyingContract` is the same universal Permit2 address on every EVM
  chain.

  ## Signed-object encoding

  `signed_object` is the ABI-encoded tuple
  `tuple(tuple(address,uint256),address,uint256,uint256)` that Riddler's
  `/order` endpoint consumes. Because every field is static, the encoding
  is just the concatenation of left-padded 32-byte values for
  `token`, `amount`, `spender`, `nonce`, and `deadline`.

  The Node CLI calls `abiCoder.encode(['tuple(...)'], [[...]])` which wraps
  the result in a 32-byte offset (always `0x20`) and then strips it via a
  heuristic. We produce the stripped form directly: the output bytes are
  identical to the CLI's stripped output.
  """

  @behaviour Raxol.Payments.Protocol

  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  @types %{
    "PermitWitnessTransferFrom" => [
      {"permitted", "TokenPermissions"},
      {"spender", "address"},
      {"nonce", "uint256"},
      {"deadline", "uint256"},
      {"witness", "OriginPullWitness"}
    ],
    "TokenPermissions" => [
      {"token", "address"},
      {"amount", "uint256"}
    ],
    "OriginPullWitness" => [
      {"orderId", "bytes32"}
    ]
  }

  # -- Protocol behaviour stubs (Permit2 is not a 402 protocol) --

  @impl true
  @spec name() :: String.t()
  def name, do: "Permit2"

  @impl true
  @spec detect?(integer(), [{String.t(), String.t()}]) :: boolean()
  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_challenge(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec build_payment(map(), module()) :: {:error, :not_a_402_protocol}
  def build_payment(_challenge, _wallet), do: {:error, :not_a_402_protocol}

  @impl true
  @spec parse_receipt([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_receipt(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(%{input_amount: amt}) when is_binary(amt), do: Decimal.new(amt)
  def amount(%{input_amount: amt}) when is_integer(amt), do: Decimal.new(amt)
  def amount(_), do: Decimal.new(0)

  # -- Direct API --

  @doc """
  Sign a Permit2 `PermitWitnessTransferFrom` from a Riddler `/quote`
  response.

  `quote` shape mirrors `signing.js#signPermit2`:

      %{
        "request" => %{"inputAmount" => "1000000", "inputToken" => "0x..."},
        "quoteExpires" => 1_900_000_000,
        "gasless" => %{
          "to" => "0x<solver>",
          "nonce" => "0x...",
          "orderId" => "0x<32 bytes>"
        }
      }

  Atoms keys are also accepted. Returns
  `{:ok, %{signature: hex, signed_object: hex, digest: hex, domain: map, message: map}}`.
  """
  @spec sign_quote(map(), pos_integer(), module()) ::
          {:ok,
           %{
             signature: String.t(),
             signed_object: String.t(),
             digest: String.t(),
             domain: map(),
             message: map()
           }}
          | {:error, term()}
  def sign_quote(quote, chain_id, wallet)
      when is_map(quote) and is_integer(chain_id) and is_atom(wallet) do
    with {:ok, parsed} <- parse_quote(quote) do
      message = build_message(parsed)
      domain = build_domain(chain_id)

      with {:ok, digest} <- Raxol.Payments.EIP712.hash(domain, @types, message),
           {:ok, sig_bytes} <- wallet.sign_typed_data(domain, @types, message) do
        {:ok,
         %{
           signature: "0x" <> Base.encode16(sig_bytes, case: :lower),
           signed_object: "0x" <> Base.encode16(encode_signed_object(message), case: :lower),
           digest: "0x" <> Base.encode16(digest, case: :lower),
           domain: domain,
           message: message
         }}
      end
    end
  end

  @doc """
  Return the universal Permit2 contract address.

  One address on every chain, because Permit2 ships through the deterministic
  CREATE2 deployer. That holds across every corridor raxol settles on, and it is
  what lets three separate decisions share this constant: the spender an approve
  grants to (`Raxol.Earn.Onchain.Permit2Approver`), the `verifyingContract` a
  served pull must declare (`Raxol.Payments.Protocols.Xochi`), and the contract
  `Raxol.Earn.Xochi.PullPreflight` reads `DOMAIN_SEPARATOR()` from.

  It is not universal in the arithmetic sense. A chain whose CREATE2 derivation
  differs -- zkSync Era is the one in production, at
  `0x0000000000225e31d15943971f47ad3022f714fa` -- hosts Permit2 somewhere else.
  Adding such a corridor turns this into a per-chain lookup; until then a single
  constant is the honest shape, and the failure it produces is a refusal to
  sign (`{:authorization_mismatch, :pull_verifier}`) rather than a bad signature.
  """
  @spec verifying_contract() :: String.t()
  def verifying_contract, do: @permit2_address

  @doc "Return the EIP-712 types map this module signs against."
  @spec types() :: map()
  def types, do: @types

  # -- Internals --

  defp build_domain(chain_id) do
    %{
      name: "Permit2",
      chainId: chain_id,
      verifyingContract: @permit2_address
    }
  end

  defp parse_quote(quote) do
    with {:ok, request} <- fetch(quote, :request, "request"),
         {:ok, gasless} <- fetch(quote, :gasless, "gasless"),
         {:ok, expires} <- fetch(quote, :quoteExpires, "quoteExpires"),
         {:ok, input_amount} <- fetch(request, :inputAmount, "inputAmount"),
         {:ok, input_token} <- fetch(request, :inputToken, "inputToken"),
         {:ok, spender} <- fetch(gasless, :to, "to"),
         {:ok, nonce} <- fetch(gasless, :nonce, "nonce"),
         {:ok, order_id} <- fetch(gasless, :orderId, "orderId") do
      {:ok,
       %{
         input_amount: input_amount,
         input_token: input_token,
         spender: spender,
         nonce: nonce,
         deadline: expires,
         order_id: order_id
       }}
    end
  end

  defp fetch(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      nil -> {:error, {:missing_quote_field, atom_key}}
      value -> {:ok, value}
    end
  end

  defp build_message(parsed) do
    %{
      "permitted" => %{
        "token" => parsed.input_token,
        "amount" => normalize_uint(parsed.input_amount)
      },
      "spender" => parsed.spender,
      "nonce" => normalize_uint(parsed.nonce),
      "deadline" => normalize_uint(parsed.deadline),
      "witness" => %{
        "orderId" => normalize_bytes32(parsed.order_id)
      }
    }
  end

  defp normalize_uint(value) when is_integer(value), do: value

  defp normalize_uint(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> raise ArgumentError, "permit2: cannot parse uint from #{inspect(value)}"
    end
  end

  defp normalize_bytes32("0x" <> hex) when byte_size(hex) == 64, do: "0x" <> String.downcase(hex)

  defp normalize_bytes32("0x" <> hex) do
    padded = String.pad_leading(hex, 64, "0") |> String.slice(0, 64) |> String.downcase()
    "0x" <> padded
  end

  defp normalize_bytes32(value) when is_binary(value) do
    normalize_bytes32("0x" <> value)
  end

  # Encode `tuple(tuple(address,uint256),address,uint256,uint256)` as the
  # plain concatenation of the static fields. This matches what the CLI
  # produces after it strips the ABI offset pointer (`signing.js:291-304`).
  defp encode_signed_object(message) do
    permitted = Map.fetch!(message, "permitted")

    pad_address(Map.fetch!(permitted, "token")) <>
      pad_uint(Map.fetch!(permitted, "amount")) <>
      pad_address(Map.fetch!(message, "spender")) <>
      pad_uint(Map.fetch!(message, "nonce")) <>
      pad_uint(Map.fetch!(message, "deadline"))
  end

  defp pad_address("0x" <> hex) when byte_size(hex) == 40 do
    bytes = Base.decode16!(hex, case: :mixed)
    <<0::96, bytes::binary>>
  end

  defp pad_uint(value) when is_integer(value) do
    <<value::unsigned-big-256>>
  end
end
