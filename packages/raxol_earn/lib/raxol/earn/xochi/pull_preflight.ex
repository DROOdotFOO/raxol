defmodule Raxol.Earn.Xochi.PullPreflight do
  @moduledoc """
  Read-only check that the origin pull a buyer just signed will actually be
  accepted on chain, before anything is escrowed or funded.

  The pull is the step that has failed every funded attempt on GitHub #772. It
  fails at the far end of a long sequence -- quote, sign, `createJob`, fund,
  provider `setBudget`, solver relay -- and reports back as a status string with
  no detail (`validation_failed`, or a bare `pull_failed`), so each attempt cost
  a job, an escrow, and a round trip through two other repositories to learn one
  bit. This asks the two contracts involved the same question directly, for the
  price of two `eth_call`s.

  ## What it proves

      separator  = VerifyingContract.DOMAIN_SEPARATOR()      -- read from chain
      structHash = hashStruct(served types, served message)
      digest     = keccak256(0x1901 || separator || structHash)
      magic      = Account.isValidSignature(digest, pull_signature)

  A `0x1626ba7e` means the account vouches for that signature over that digest,
  and the digest was built on the separator the verifier itself will rebuild. So
  the pull's signature check passes.

  The separator being READ rather than computed is the whole point. Checking our
  own signature against a digest from our own `domain` projection is circular:
  both sides of the comparison carry the same mistake and agree. #772 was exactly
  that -- a `version` field we inserted and Permit2 never declared, which every
  test agreed with because every test rebuilt the domain the same way we did.
  Sourcing the domain half from the contract breaks the loop.

  The struct half is still encoded by `Raxol.Payments.EIP712`, which the Permit2
  and ERC-3009 conformance suites pin against ethers-generated vectors.

  ## What it does not prove

  Only the signature check. A pull can still revert on allowance, balance,
  an expired deadline, or a spent nonce, and this deliberately does not read
  those: they are properties of funding time, not signing time, and the order
  task reports the allowance separately. A pass here means the signature is not
  the reason the next attempt fails.

  It also needs a `verifyingContract` to ask, so it covers the pull (Permit2 or
  the ERC-3009 token) and not the Xochi intent signature, whose domain is keyed
  by `salt` with no contract behind it.

  One blind spot is worth naming, because it is the same shape as the bug this
  exists to catch. Permit2 builds its `PermitWitnessTransferFrom` typehash by
  concatenating a fixed stub with the caller's witness type string, where EIP-712
  sorts referenced types alphabetically. For `OriginPullWitness` the two agree --
  `OriginPullWitness` sorts before `TokenPermissions` -- so the struct hash here
  matches Permit2's. A witness type renamed to sort after `TokenPermissions`
  would diverge, and this check would not see it: it would encode the struct the
  same wrong way the signer did, and both would agree. Only the domain half is
  sourced from the chain. Pinning the witness type string is the guard for that,
  not this.
  """

  alias Raxol.Earn.ABI
  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Payments.EIP712

  # ERC-1271: bytes4(keccak256("isValidSignature(bytes32,bytes)"))
  @erc1271_magic <<0x16, 0x26, 0xBA, 0x7E>>

  @type outcome ::
          {:ok,
           %{
             digest: binary(),
             separator: binary(),
             verifying_contract: String.t(),
             signer_kind: :contract | :eoa
           }}
          | {:error, term()}

  @doc """
  Verify `signature` against `account` over the digest the pull's verifying
  contract will build from `served`.

  `served` is the quote's `pull_authorization` verbatim -- its `"domain"`,
  `"types"` and `"message"` as the worker sent them.

  ## Options

  - `:rpc` -- an `Raxol.Earn.Onchain.RPC` client. Built from application config
    when absent.

  Returns `{:ok, details}` when the account answers with the ERC-1271 magic
  value, `{:error, {:signature_rejected, details}}` when it answers anything
  else, and `{:error, reason}` when the check could not be completed -- which is
  NOT a verdict on the signature and must not be reported as one.
  """
  @spec verify(map(), String.t(), String.t(), keyword()) :: outcome()
  def verify(served, signature, account, opts \\ []) when is_map(served) do
    client = Keyword.get_lazy(opts, :rpc, fn -> RPC.client() end)

    with {:ok, sig_bytes} <- decode_hex(signature, :signature),
         {:ok, details} <- describe_target(client, served, account) do
      details.signer_kind
      |> check(client, account, details.digest, sig_bytes)
      |> verdict(details)
    end
  end

  # Everything the verdict is about, resolved before the signature is looked at:
  # which contract verifies, the separator it rebuilds, the digest that yields,
  # and whether the buyer is asked by ERC-1271 or by recovery.
  defp describe_target(client, served, account) do
    with {:ok, verifying_contract} <- verifying_contract(served),
         {:ok, separator} <- domain_separator(client, verifying_contract),
         {:ok, digest} <- digest(separator, served),
         {:ok, kind} <- signer_kind(client, account) do
      {:ok,
       %{
         digest: digest,
         separator: separator,
         verifying_contract: verifying_contract,
         signer_kind: kind
       }}
    end
  end

  defp verdict(:ok, details), do: {:ok, details}

  defp verdict({:rejected, returned}, details),
    do: {:error, {:signature_rejected, Map.put(details, :returned, returned)}}

  defp verdict({:error, _} = err, _details), do: err

  @doc """
  One line describing the outcome, for the order task's log.
  """
  @spec describe(outcome()) :: String.t()
  def describe({:ok, %{verifying_contract: vc, digest: digest, signer_kind: kind}}) do
    "pull preflight: OK -- the signature covers the digest #{short(vc)} will rebuild " <>
      "(#{short_hex(digest)}), verified #{via(kind)}"
  end

  def describe({:error, {:signature_rejected, details}}) do
    %{verifying_contract: vc, returned: returned, signer_kind: kind} = details

    "pull preflight: REJECTED -- #{short(vc)} rebuilds a digest this signature does not " <>
      "cover (#{via(kind)} answered #{describe_returned(kind, returned)}). The pull would " <>
      "revert, so funding this order would escrow a fee for a settlement that cannot happen."
  end

  def describe({:error, reason}) do
    "pull preflight: INCONCLUSIVE (#{inspect(reason)}) -- this is not a verdict on the " <>
      "signature; the check itself could not run."
  end

  # -- Internal --

  defp verifying_contract(served) do
    case get_in(served, ["domain", "verifyingContract"]) do
      "0x" <> _ = address -> {:ok, address}
      nil -> {:error, :no_verifying_contract}
      other -> {:error, {:invalid_verifying_contract, other}}
    end
  end

  # The separator the contract itself rebuilds. Every domain we pull against
  # -- Permit2 and the ERC-3009 tokens -- exposes it as an immutable public
  # getter, so this is a cache-free read of the exact 32 bytes the on-chain
  # verification will use.
  defp domain_separator(client, verifying_contract) do
    call = %{to: verifying_contract, data: selector()}

    with {:ok, hex} <- RPC.eth_call(client, call),
         {:ok, bytes} <- decode_hex(hex, :domain_separator) do
      case bytes do
        <<separator::binary-size(32)>> ->
          {:ok, separator}

        other ->
          {:error, {:domain_separator_length, byte_size(other)}}
      end
    else
      {:error, reason} -> {:error, {:domain_separator_unavailable, verifying_contract, reason}}
    end
  end

  defp selector, do: ABI.function_selector("DOMAIN_SEPARATOR()")

  defp digest(separator, served) do
    types = types(served)
    message = served["message"] || %{}

    case EIP712.hash_with_separator(separator, types, message) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, {:digest_failed, reason}}
    end
  end

  # Drop the served EIP712Domain declaration: the separator it describes is the
  # one being read from chain instead, and leaving it in would make it a second
  # root type and the primary type ambiguous.
  defp types(served) do
    (served["types"] || %{})
    |> Map.drop(["EIP712Domain"])
    |> Map.new(fn {name, fields} ->
      {name, Enum.map(fields, fn f -> {f["name"], f["type"]} end)}
    end)
  end

  # Permit2 and the ERC-3009 tokens branch on whether the owner has code: a
  # contract account is asked via ERC-1271, an EOA is recovered with ecrecover.
  # Checking the wrong one would answer a question the pull never asks -- an EOA
  # has no `isValidSignature` to call, and a 7702 account's wrapped envelope
  # cannot recover. A 7702 delegation designator IS code, so this splits them.
  defp signer_kind(client, account) do
    case RPC.deployed?(client, account) do
      {:ok, true} -> {:ok, :contract}
      {:ok, false} -> {:ok, :eoa}
      {:error, reason} -> {:error, {:signer_kind_unavailable, account, reason}}
    end
  end

  defp check(:contract, client, account, digest, sig_bytes) do
    case call_erc1271(client, account, digest, sig_bytes) do
      {:ok, @erc1271_magic} -> :ok
      {:ok, returned} -> {:rejected, returned}
      {:error, _} = err -> err
    end
  end

  defp check(:eoa, _client, account, digest, sig_bytes) do
    case recover(digest, sig_bytes) do
      {:ok, recovered} ->
        if EIP712.normalize_address(recovered) == EIP712.normalize_address(account) do
          :ok
        else
          {:rejected, recovered}
        end

      {:error, reason} ->
        {:error, {:recover_failed, reason}}
    end
  end

  defp recover(digest, <<r::binary-size(32), s::binary-size(32), v::8>>) when v in [27, 28] do
    case ExSecp256k1.recover(digest, r, s, v - 27) do
      {:ok, pubkey} -> {:ok, EIP712.address_from_pubkey(pubkey)}
      {:error, reason} -> {:error, reason}
    end
  end

  # An EOA pull carries a canonical 65-byte signature. Anything else is a
  # wrapped envelope on an account with no code to unwrap it, which the pull
  # would reject.
  defp recover(_digest, sig), do: {:error, {:not_a_canonical_signature, byte_size(sig)}}

  defp call_erc1271(client, account, digest, sig_bytes) do
    data =
      ABI.encode_call("isValidSignature(bytes32,bytes)", [
        {"bytes32", "0x" <> Base.encode16(digest, case: :lower)},
        {"bytes", sig_bytes}
      ])

    # `:data` is handed over as raw bytes: RPC.eth_call/3 hex-encodes it.
    call = %{to: account, data: data}

    with {:ok, hex} <- RPC.eth_call(client, call),
         {:ok, bytes} <- decode_hex(hex, :magic_value) do
      # A bytes4 return is left-aligned in its 32-byte word. An account that
      # reverts rather than returning a value surfaces as an RPC error above.
      {:ok, binary_part(bytes, 0, min(4, byte_size(bytes)))}
    else
      {:error, reason} -> {:error, {:erc1271_call_failed, account, reason}}
    end
  end

  defp decode_hex("0x" <> hex, label), do: decode_hex(hex, label)

  defp decode_hex(hex, label) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_hex, label}}
    end
  end

  defp decode_hex(other, label), do: {:error, {:invalid_hex, label, other}}

  defp short("0x" <> hex) when byte_size(hex) > 10 do
    "0x" <> binary_part(hex, 0, 6) <> ".." <> binary_part(hex, byte_size(hex) - 4, 4)
  end

  defp short(other), do: to_string(other)

  defp short_hex(bytes) when is_binary(bytes),
    do: short("0x" <> Base.encode16(bytes, case: :lower))

  defp via(:contract), do: "on-chain via ERC-1271 isValidSignature"
  defp via(:eoa), do: "by ecrecover against the buyer address"

  # An ERC-1271 refusal is a 4-byte magic value; an EOA mismatch is the address
  # the signature actually recovers to, which says far more than "not equal".
  defp describe_returned(:eoa, address), do: "recovered #{short(address)}"
  defp describe_returned(:contract, magic), do: short_hex(magic)
end
