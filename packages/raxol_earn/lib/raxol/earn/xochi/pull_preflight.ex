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
  price of four read-only calls: `eth_chainId` (which chain the node speaks for),
  `eth_getCode` (which branch the pull will take), and one `eth_call` each for
  the separator and the signature check. An EOA buyer costs three -- there is no
  `isValidSignature` to call.

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

  The struct half is not chain-sourced. It is encoded by `Raxol.Payments.EIP712`,
  which the Permit2 and ERC-3009 conformance suites pin against ethers-generated
  vectors, and projected into that encoder by
  `Raxol.Payments.Protocols.Xochi.eip712_types/1` -- the SIGNER's own function,
  called rather than mirrored. Those are two different guarantees and only the
  first is a vector pin: what the shared call buys is that this module and the
  signer cannot drift into rebuilding different struct hashes, which would
  surface as a REJECTED verdict on a signature that was fine.

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

  ## Three outcomes, and which of them may spend money

  `verify/4` answers `{:ok, _}`, `{:rejected, _}` or `{:inconclusive, _}`, and
  the three are separate constructors rather than shades of `{:error, _}` on
  purpose. A caller that funds on anything but `{:ok, _}` is spending money on an
  unanswered question, and an `{:error, _}` catch-all is precisely how that
  happens: every reason not yet enumerated lands in it silently, so the set of
  ways to fund an unverifiable pull grows every time a new failure mode is added
  here. With three constructors the caller must name what it does about each, and
  a new reason joins an existing constructor rather than inventing a fourth path.

  The split between `:rejected` and `:inconclusive` carries no safety weight --
  neither may fund. It exists so the operator learns whether to fix the payload
  or the environment.
  """

  alias Raxol.Earn.ABI
  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol

  # ERC-1271: bytes4(keccak256("isValidSignature(bytes32,bytes)"))
  @erc1271_magic <<0x16, 0x26, 0xBA, 0x7E>>

  @permit2_primary_type "PermitWitnessTransferFrom"

  @type details :: %{
          optional(:digest) => binary(),
          optional(:separator) => binary(),
          optional(:verifying_contract) => String.t(),
          optional(:signer_kind) => :contract | :eoa,
          optional(:returned) => term(),
          optional(:reason) => term()
        }

  @type outcome ::
          {:ok, details()}
          | {:rejected, details()}
          | {:inconclusive, term()}

  @doc """
  Verify `signature` against `account` over the digest the pull's verifying
  contract will build from `served`.

  `served` is the quote's `pull_authorization` verbatim -- its `"domain"`,
  `"types"` and `"message"` as the worker sent them.

  ## Options

  - `:rpc` -- an `Raxol.Earn.Onchain.RPC` client. Built from application config
    when absent.
  - `:expect_verifier` -- the address the caller's rail says will verify this
    signature (the canonical Permit2, or the origin token for ERC-3009). The
    served `domain.verifyingContract` must match it or the pull is rejected.
    PASS THIS. It is what stops the party who served the payload from also
    choosing the contract this module asks about it; without it the fallback pin
    keys off the served `primaryType`, which that party also controls.

  Returns:

  - `{:ok, details}` -- the verifier vouches for this signature over the digest
    it will rebuild. This is the ONLY outcome a funded run may proceed on.
  - `{:rejected, details}` -- the signature provably will not verify, either
    because the verifier said so or because the payload cannot produce a
    verifiable signature at all. `details.reason` says which.
  - `{:inconclusive, reason}` -- the check could not be completed, so this is NOT
    a verdict on the signature and must not be reported as one. It is still not
    permission to fund.
  """
  @spec verify(map(), String.t(), String.t(), keyword()) :: outcome()
  def verify(served, signature, account, opts \\ []) when is_map(served) do
    client = Keyword.get_lazy(opts, :rpc, fn -> RPC.client() end)
    expected = Keyword.get(opts, :expect_verifier)

    with {:ok, sig_bytes} <- signature_bytes(signature),
         {:ok, details} <- describe_target(client, served, account, expected) do
      details.signer_kind
      |> check(client, account, details.digest, sig_bytes)
      |> verdict(details)
    else
      # A defect found before the target resolved has no digest or separator to
      # report alongside it, only the reason it stopped there.
      {:rejected_because, reason} -> {:rejected, %{reason: reason}}
      {:inconclusive, _} = out -> out
    end
  end

  # Everything the verdict is about, resolved before the signature is looked at:
  # that the node speaks for the chain the domain names, which contract verifies,
  # the separator it rebuilds, the digest that yields, and whether the buyer is
  # asked by ERC-1271 or by recovery.
  defp describe_target(client, served, account, expected) do
    with :ok <- same_chain(client, served),
         {:ok, verifying_contract} <- verifying_contract(served, expected),
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
    do: {:rejected, details |> Map.put(:returned, returned) |> Map.put(:reason, :answered)}

  defp verdict({:rejected_because, reason}, details),
    do: {:rejected, Map.put(details, :reason, reason)}

  defp verdict({:inconclusive, _} = out, _details), do: out

  @doc """
  One line describing the outcome, for the order task's log.
  """
  @spec describe(outcome()) :: String.t()
  def describe({:ok, %{verifying_contract: vc, digest: digest, signer_kind: kind}}) do
    "pull preflight: OK -- the signature covers the digest #{short(vc)} will rebuild " <>
      "(#{short_hex(digest)}), verified #{via(kind)}"
  end

  def describe({:rejected, %{reason: :answered} = details}) do
    %{verifying_contract: vc, returned: returned, signer_kind: kind} = details

    "pull preflight: REJECTED -- #{short(vc)} rebuilds a digest this signature does not " <>
      "cover (#{via(kind)} answered #{describe_returned(kind, returned)}). The pull would " <>
      "revert, so funding this order would escrow a fee for a settlement that cannot happen."
  end

  def describe({:rejected, %{reason: reason}}) do
    "pull preflight: REJECTED -- #{describe_defect(reason)}. No signature over this " <>
      "authorization can verify, so funding this order would escrow a fee for a settlement " <>
      "that cannot happen."
  end

  def describe({:inconclusive, reason}) do
    "pull preflight: INCONCLUSIVE (#{inspect(reason)}) -- this is not a verdict on the " <>
      "signature; #{describe_gap(reason)}. Funding is refused either way: an unanswered " <>
      "check is not permission to escrow."
  end

  # -- Internal --

  # A served `verifyingContract` is a claim about WHO will check the signature,
  # made by the same party whose payload is under audit. Reading a separator from
  # an address the quote chose would let a hostile worker nominate a contract
  # whose DOMAIN_SEPARATOR() it controls, and the check would agree with the
  # payload exactly the way #772's tests agreed with #772.
  #
  # `:expect_verifier` is how a caller breaks that: it names the verifier from
  # the rail the caller ASKED for, so the oracle is not drawn from served data at
  # all. Without it the only pin available keys off `served["primaryType"]` --
  # also served, also chosen by the same party -- so a payload declaring some
  # other primary type skips the pin. That floor makes a bare call no worse than
  # nothing; it is not a substitute for passing the option.
  defp verifying_contract(served, expected) do
    with {:ok, address} <- declared_verifier(served) do
      pinned_verifier(expected, served["primaryType"], address)
    end
  end

  defp declared_verifier(served) do
    case get_in(served, ["domain", "verifyingContract"]) do
      "0x" <> _ = address -> {:ok, address}
      nil -> {:rejected_because, :no_verifying_contract}
      other -> {:rejected_because, {:invalid_verifying_contract, other}}
    end
  end

  defp pinned_verifier(expected, _primary_type, address) when is_binary(expected) do
    if EIP712.normalize_address(address) == EIP712.normalize_address(expected) do
      {:ok, address}
    else
      {:rejected_because, {:verifier_mismatch, address, expected}}
    end
  end

  defp pinned_verifier(nil, @permit2_primary_type, address) do
    canonical = Permit2.verifying_contract()

    if EIP712.normalize_address(address) == EIP712.normalize_address(canonical) do
      {:ok, address}
    else
      {:rejected_because, {:verifier_not_permit2, address, canonical}}
    end
  end

  defp pinned_verifier(nil, _primary_type, address), do: {:ok, address}

  # Permit2's separator commits to the chain id, and Permit2 is deployed at the
  # SAME address everywhere -- so a node for the wrong chain answers this call
  # happily with 32 valid-looking bytes that belong to a different domain. The
  # digest then differs for a reason that has nothing to do with the signature,
  # and reporting it as a rejection would tell the operator their signing is
  # broken when their RPC url is. `ORDER_RPC_<from>` falls back to the Base
  # endpoint when unset, so this is the DEFAULT path for any non-Base origin.
  defp same_chain(client, served) do
    declared = to_uint(get_in(served, ["domain", "chainId"]))

    case {declared, RPC.eth_chain_id(client)} do
      {nil, _} -> {:rejected_because, :no_chain_id}
      {chain, {:ok, chain}} -> :ok
      {chain, {:ok, other}} -> {:inconclusive, {:wrong_chain, declared: chain, node: other}}
      {_chain, {:error, reason}} -> {:inconclusive, {:chain_id_unavailable, reason}}
    end
  end

  defp to_uint(n) when is_integer(n) and n >= 0, do: n

  # Trimmed, to agree with `Protocols.Xochi`'s parser of the same field. Nothing
  # reaching here can currently differ -- `EIP712` refuses a padded uint256 at
  # signing, several steps earlier -- but two parsers of one field disagreeing is
  # a bug waiting for a caller, and the disagreement here would surface as a hard
  # rejection reading "declares no domain.chainId" for a payload that declares one.
  defp to_uint(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_uint(_), do: nil

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
          {:inconclusive, {:domain_separator_length, byte_size(other)}}
      end
    else
      {:error, reason} ->
        {:inconclusive, {:domain_separator_unavailable, verifying_contract, reason}}
    end
  end

  defp selector, do: ABI.function_selector("DOMAIN_SEPARATOR()")

  # A served envelope this module cannot encode is one no signature can cover:
  # the signer encoded SOMETHING, and it was not this. That is a defect in the
  # payload, not a gap in the check.
  # The struct half is projected by the SIGNER's own function, not a copy of it.
  # A copy would agree with itself and diverge from production the moment either
  # side changed -- and it would report that divergence as the signature being
  # bad, which is the false verdict this module exists to avoid. It also does not
  # make the check circular in any way the moduledoc does not already own: the
  # domain half is what is sourced from the chain, and this step has no judgment
  # in it beyond dropping EIP712Domain, which both sides must do identically or
  # neither is encoding EIP-712.
  defp digest(separator, served) do
    types = XochiProtocol.eip712_types(served)
    message = served["message"] || %{}

    case EIP712.hash_with_separator(separator, types, message) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:rejected_because, {:digest_failed, reason}}
    end
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
      {:error, reason} -> {:inconclusive, {:signer_kind_unavailable, account, reason}}
    end
  end

  defp check(:contract, client, account, digest, sig_bytes) do
    case call_erc1271(client, account, digest, sig_bytes) do
      {:ok, @erc1271_magic} -> :ok
      {:ok, returned} -> {:rejected, returned}
      {:inconclusive, _} = out -> out
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

      # Permit2 and the ERC-3009 tokens run this same recovery against this same
      # account. A signature that cannot be recovered here cannot be recovered
      # there either, which makes this a verdict and not a gap.
      {:error, reason} ->
        {:rejected_because, {:recover_failed, reason}}
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
      # REVERTS rather than returning a value surfaces as an RPC error above and
      # is classified `:inconclusive` -- indistinguishable here from a node that
      # dropped the call, and both block, so the safe reading wins.
      {:ok, binary_part(bytes, 0, min(4, byte_size(bytes)))}
    else
      {:error, reason} -> {:inconclusive, {:erc1271_call_failed, account, reason}}
    end
  end

  # A signature that is not hex is not a signature. The pull is handed these same
  # bytes, so there is nothing here for a working RPC to resolve later.
  defp signature_bytes(signature) do
    case decode_hex(signature, :signature) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:rejected_because, reason}
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

  # What is wrong with the payload, in the operator's terms. These are all
  # defects in what the quote served or what was signed over it, so each one
  # names the artifact to capture rather than a knob to turn.
  defp describe_defect(:no_verifying_contract),
    do:
      "the served pull declares no domain.verifyingContract, so nothing on chain " <>
        "claims to verify it"

  defp describe_defect(:no_chain_id),
    do: "the served pull declares no domain.chainId, so it names no chain to settle on"

  defp describe_defect({:invalid_verifying_contract, other}),
    do: "the served domain.verifyingContract is not an address (#{inspect(other)})"

  defp describe_defect({:verifier_mismatch, served, expected}),
    do:
      "the served domain.verifyingContract is #{short(served)}, not #{short(expected)}, which " <>
        "is what this rail pulls through. Asking the served address about the signature would " <>
        "be asking the party that chose it, so the check stops here"

  defp describe_defect({:verifier_not_permit2, served, canonical}),
    do:
      "the served domain.verifyingContract is #{short(served)}, not the canonical Permit2 " <>
        "at #{short(canonical)}. The allowance this pull spends was granted to Permit2, so " <>
        "whatever that address says about the signature is not what will run"

  defp describe_defect({:digest_failed, reason}),
    do: "the served types and message cannot be EIP-712 encoded (#{inspect(reason)})"

  defp describe_defect({:recover_failed, {:not_a_canonical_signature, size}}),
    do:
      "the buyer has no code on this chain, so the pull recovers with ecrecover, and this " <>
        "signature is #{size} bytes rather than a canonical 65. A wrapped envelope needs an " <>
        "account that can unwrap it -- check whether the 7702 delegation is actually set"

  defp describe_defect({:recover_failed, reason}),
    do: "this signature does not recover to any address (#{inspect(reason)})"

  defp describe_defect({:invalid_hex, :signature}),
    do: "the signature is not hex"

  defp describe_defect(other), do: inspect(other)

  # What stopped the check, and what the operator does about it. Every one of
  # these is environmental, so every one of them is worth a retry -- unlike the
  # defects above.
  defp describe_gap({:wrong_chain, declared: declared, node: node}),
    do:
      "the RPC answers for chain #{node} while the pull is for chain #{declared}, so the " <>
        "separator read back belongs to a different domain. Permit2 is at one address on " <>
        "every chain, which is why this reads as a mismatch rather than an error. Set " <>
        "ORDER_RPC_#{declared} -- it falls back to the Base endpoint when unset"

  defp describe_gap({:chain_id_unavailable, _}),
    do: "the RPC did not answer eth_chainId, so which chain it speaks for is unknown"

  defp describe_gap({:domain_separator_unavailable, vc, _}),
    do: "#{short(vc)} did not answer DOMAIN_SEPARATOR()"

  defp describe_gap({:domain_separator_length, n}),
    do: "DOMAIN_SEPARATOR() answered #{n} bytes rather than 32"

  defp describe_gap({:signer_kind_unavailable, account, _}),
    do: "eth_getCode did not answer for #{short(account)}, so the pull's own branch is unknown"

  # A revert lands here rather than in a rejection, because this cannot tell a
  # reverting `isValidSignature` (which IS a verdict -- the pull reverts too)
  # from a node that dropped the call. Erring toward "retry" is the safe
  # direction for a check that blocks either way, but say what a repeat means so
  # the operator is not sent after the RPC forever.
  defp describe_gap({:erc1271_call_failed, account, _}),
    do:
      "#{short(account)} did not answer isValidSignature. If it answers other calls, this is " <>
        "the account REVERTING rather than the node failing, and the signature is the suspect"

  defp describe_gap(_other), do: "the check itself could not run"

  # An ERC-1271 refusal is a 4-byte magic value; an EOA mismatch is the address
  # the signature actually recovers to, which says far more than "not equal".
  defp describe_returned(:eoa, address), do: "recovered #{short(address)}"
  defp describe_returned(:contract, magic), do: short_hex(magic)
end
