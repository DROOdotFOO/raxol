defmodule Raxol.Earn.Xochi.PullPreflightTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Earn.Xochi.PullPreflight
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  # Permit2's live Base DOMAIN_SEPARATOR, and the universal deployment it is
  # read from. Hardcoding the real value is what makes the fake chain below an
  # ORACLE rather than a restatement: it is the 32 bytes the contract actually
  # rebuilds, taken from chain, not from our own domain construction.
  @permit2_separator Base.decode16!(
                       "3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07",
                       case: :lower
                     )
  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @spender "0x000000000000000000000000000000000000dEaD"

  @key Base.decode16!("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
         case: :lower
       )
  @owner "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"

  @magic "0x1626ba7e" <> String.duplicate("00", 28)
  @not_magic "0xffffffff" <> String.duplicate("00", 28)

  # A chain that answers the two calls the preflight makes. `DOMAIN_SEPARATOR()`
  # returns Permit2's real value; `isValidSignature` does what a 7702 account
  # does -- recover the signer from the digest it was ASKED about and answer the
  # magic value only if it is the authorized owner. Recovering for real is the
  # point: a signature over a different digest recovers a different address, so
  # the fake cannot accidentally agree with a wrong digest.
  defp chain(opts \\ []) do
    code = Keyword.get(opts, :code, "0xef0100" <> String.duplicate("11", 20))
    chain_id = Keyword.get(opts, :chain_id, 8453)
    foreign = Keyword.get(opts, :foreign_separator, @permit2_separator)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      result =
        case req["method"] do
          # Which chain the node speaks for. Permit2 is at one address on every
          # chain with a DIFFERENT separator, so this is the only thing that
          # distinguishes a correct read from a plausible wrong one.
          "eth_chainId" ->
            "0x" <> Integer.to_string(chain_id, 16)

          # A 7702 delegation designator is code; "0x" is a bare EOA.
          "eth_getCode" ->
            code

          "eth_call" ->
            [%{"to" => to, "data" => data} | _] = req["params"]
            dispatch(String.downcase(to), data, foreign)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
      )
    end

    RPC.client(url: "http://stub.invalid/rpc", plug: plug)
  end

  defp dispatch(to, _data, _foreign) when to == "0x000000000022d473030f116ddee9f6b43ac78ba3" do
    "0x" <> Base.encode16(@permit2_separator, case: :lower)
  end

  # Any other contract answers DOMAIN_SEPARATOR() with whatever 32 bytes it
  # likes. A verifier nominated by the party under audit answers with the
  # separator for the domain that party SERVED, which is what makes the check
  # agree with the payload instead of testing it.
  defp dispatch(to, "0x3644e515", foreign) when to != @account do
    "0x" <> Base.encode16(foreign, case: :lower)
  end

  defp dispatch(to, data, _foreign) when to == @account do
    <<_selector::binary-size(4), digest::binary-size(32), _offset::binary-size(32),
      len::unsigned-big-256, rest::binary>> = decode!(data)

    <<sig::binary-size(^len), _padding::binary>> = rest
    <<r::binary-size(32), s::binary-size(32), v::8>> = sig

    {:ok, pubkey} = ExSecp256k1.recover(digest, r, s, v - 27)

    if EIP712.address_from_pubkey(pubkey) == @owner, do: @magic, else: @not_magic
  end

  defp decode!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  # The Permit2 pull a Xochi quote serves, with the domain Permit2 declares:
  # name/chainId/verifyingContract, and NO version.
  defp served_pull do
    %{
      "domain" => %{
        "name" => "Permit2",
        "chainId" => 8453,
        "verifyingContract" => @permit2_address
      },
      "primaryType" => "PermitWitnessTransferFrom",
      "types" => %{
        "EIP712Domain" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "chainId", "type" => "uint256"},
          %{"name" => "verifyingContract", "type" => "address"}
        ],
        "PermitWitnessTransferFrom" => [
          %{"name" => "permitted", "type" => "TokenPermissions"},
          %{"name" => "spender", "type" => "address"},
          %{"name" => "nonce", "type" => "uint256"},
          %{"name" => "deadline", "type" => "uint256"},
          %{"name" => "witness", "type" => "OriginPullWitness"}
        ],
        "TokenPermissions" => [
          %{"name" => "token", "type" => "address"},
          %{"name" => "amount", "type" => "uint256"}
        ],
        "OriginPullWitness" => [%{"name" => "orderId", "type" => "bytes32"}]
      },
      "message" => %{
        "permitted" => %{
          "token" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
          "amount" => "3000000"
        },
        "spender" => @spender,
        "nonce" => "1",
        "deadline" => "1790000000",
        "witness" => %{"orderId" => "0x" <> String.duplicate("11", 32)}
      }
    }
  end

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arbitrum "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

  # The ERC-3009 pull a quote serves for an EOA buyer. Two things differ from the
  # Permit2 fixture and both matter: the verifying contract is the TOKEN rather
  # than one universal address, and the domain carries a `version` -- so the
  # `expect_verifier` pin comes from the caller's own token config, and the
  # domain half has a field the Permit2 domain does not.
  #
  # This is the rail `mix raxol_earn.order --signer eoa` and the live ACP gate
  # take. It had no coverage at all while the preflight was already blocking
  # funded runs on it.
  defp served_erc3009_pull do
    %{
      "domain" => %{
        "name" => "USD Coin",
        "version" => "2",
        "chainId" => 8453,
        "verifyingContract" => @usdc_base
      },
      "primaryType" => "ReceiveWithAuthorization",
      "types" => %{
        "EIP712Domain" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "version", "type" => "string"},
          %{"name" => "chainId", "type" => "uint256"},
          %{"name" => "verifyingContract", "type" => "address"}
        ],
        "ReceiveWithAuthorization" => [
          %{"name" => "from", "type" => "address"},
          %{"name" => "to", "type" => "address"},
          %{"name" => "value", "type" => "uint256"},
          %{"name" => "validAfter", "type" => "uint256"},
          %{"name" => "validBefore", "type" => "uint256"},
          %{"name" => "nonce", "type" => "bytes32"}
        ]
      },
      "message" => %{
        "from" => @owner,
        "to" => @spender,
        "value" => "3000000",
        "validAfter" => "0",
        "validBefore" => "1790000000",
        "nonce" => "0x" <> String.duplicate("22", 32)
      }
    }
  end

  # A chain where the ERC-3009 token answers DOMAIN_SEPARATOR() with the
  # separator for the domain it declares.
  defp erc3009_chain(served),
    do: chain(code: "0x", foreign_separator: separator_for(served["domain"]))

  @hostile "0x00000000000000000000000000000000000badc0"

  # A pull whose domain nominates a verifier the worker controls, paired with a
  # chain where that verifier answers DOMAIN_SEPARATOR() with the separator for
  # the domain it served. Nothing in the payload is inconsistent -- that is the
  # point. The signature really does cover the digest that address really will
  # rebuild, so every question this module asks the chain comes back clean while
  # the pull runs somewhere else entirely.
  defp hostile_verifier do
    served =
      served_pull()
      |> Map.put("primaryType", "PermitWitnessTransferFromV2")
      |> update_in(["domain"], &Map.put(&1, "verifyingContract", @hostile))

    {served, chain(foreign_separator: separator_for(served["domain"]))}
  end

  # EIP712Domain(string name,string version,uint256 chainId,address
  # verifyingContract) -- the four-field domain the ERC-3009 tokens declare.
  # Must precede the three-field clause, which matches this map as well.
  defp separator_for(%{"version" => version} = domain) do
    %{"name" => name, "chainId" => chain_id, "verifyingContract" => "0x" <> vc} = domain

    type = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

    ExKeccak.hash_256(
      ExKeccak.hash_256(type) <>
        ExKeccak.hash_256(name) <>
        ExKeccak.hash_256(version) <>
        <<chain_id::unsigned-big-256>> <>
        <<0::size(96)>> <> Base.decode16!(vc, case: :mixed)
    )
  end

  # EIP712Domain(string name,uint256 chainId,address verifyingContract), built
  # the long way so the fake does not borrow the code under test to lie with.
  defp separator_for(%{"name" => name, "chainId" => chain_id, "verifyingContract" => "0x" <> vc}) do
    type = "EIP712Domain(string name,uint256 chainId,address verifyingContract)"

    ExKeccak.hash_256(
      ExKeccak.hash_256(type) <>
        ExKeccak.hash_256(name) <>
        <<chain_id::unsigned-big-256>> <>
        <<0::size(96)>> <> Base.decode16!(vc, case: :mixed)
    )
  end

  # Every call needs the pin now, and these tests are about the other arguments.
  # `put_new` so a test that IS about the pin can still name its own. The two
  # tests about the requirement itself call `PullPreflight.verify/4` directly.
  defp verify(served, signature, account, opts) do
    PullPreflight.verify(
      served,
      signature,
      account,
      Keyword.put_new(opts, :expect_verifier, @permit2_address)
    )
  end

  defp sign_over(digest) do
    {:ok, raw} = ExSecp256k1.sign(digest, @key)
    "0x" <> Base.encode16(EIP712.pack_signature(raw), case: :lower)
  end

  # What the buyer emits today: the domain projected from the served map, which
  # for this payload is exactly the three fields Permit2 declares.
  defp current_signature(served) do
    domain = Raxol.Payments.Protocols.Xochi.eip712_domain(served)
    {:ok, digest} = EIP712.hash(domain, XochiProtocol.eip712_types(served), served["message"])
    sign_over(digest)
  end

  # What the buyer emitted BEFORE #878: name/version/chainId/verifyingContract,
  # with a version Permit2 never declared. This is the signature that reverted
  # InvalidContractSignature() on Base and cost four funded attempts to find.
  defp pre_878_signature(served) do
    d = served["domain"]

    # The key is present and holds nil, which is exactly what the old
    # eip712_domain/1 produced: EIP712 derives the EIP712Domain field list with
    # Map.has_key?, so this still declares `string version` and encodes it as
    # the empty string.
    domain = %{
      name: d["name"],
      version: nil,
      chainId: d["chainId"],
      verifyingContract: d["verifyingContract"]
    }

    {:ok, digest} = EIP712.hash(domain, XochiProtocol.eip712_types(served), served["message"])
    sign_over(digest)
  end

  describe "verify/4" do
    test "accepts a pull signed over Permit2's own domain separator" do
      served = served_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @account, rpc: chain())

      assert details.separator == @permit2_separator
      assert details.verifying_contract == @permit2_address
      assert details.signer_kind == :contract
    end

    test "verifies an EOA buyer by recovery, since it has no isValidSignature to call" do
      # The live ACP gate's buyer is a plain funded key, where Permit2 does
      # ecrecover rather than an ERC-1271 call. Same digest, different check.
      served = served_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @owner, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
    end

    test "rejects an EOA signature that recovers to someone else, naming who" do
      served = served_pull()

      assert {:rejected, details} =
               verify(served, current_signature(served), @account, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
      assert details.returned == @owner
    end

    test "rejects the pre-#878 signature for an EOA buyer too" do
      # The domain defect was never specific to smart accounts. It only
      # SURFACED there, because EOA buyers resolved to erc3009 and never took
      # the Permit2 path at all.
      served = served_pull()

      assert {:rejected, details} =
               verify(served, pre_878_signature(served), @owner, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
      refute details.returned == @owner
    end

    test "rejects the pre-#878 signature that reverted InvalidContractSignature on Base" do
      # The regression that matters. The old projection declared a `version`
      # Permit2's domain does not carry, so the buyer signed a 4-field separator
      # against Permit2's 3-field one. Nothing in the buyer's own suite could see
      # it, because every check rebuilt the domain the same wrong way. Reading
      # the separator from the contract is what makes it visible here.
      served = served_pull()

      assert {:rejected, details} =
               verify(served, pre_878_signature(served), @account, rpc: chain())

      assert details.returned == <<0xFF, 0xFF, 0xFF, 0xFF>>
      assert details.separator == @permit2_separator
    end

    test "the two signatures genuinely differ, so the pass above is not vacuous" do
      served = served_pull()
      refute current_signature(served) == pre_878_signature(served)
    end

    test "a served domain with no verifyingContract is a rejection, not a gap" do
      # Nothing on chain claims to verify this, so no signature over it can pass.
      # Reporting that as inconclusive is what let #772's defect class through a
      # gate built to catch it: the run read "could not check" and funded anyway.
      served = Map.put(served_pull(), "domain", %{"name" => "Xochi", "chainId" => 8453})

      assert {:rejected, %{reason: :no_verifying_contract}} =
               verify(served, "0x00", @account, rpc: chain())
    end

    test "a permit2 pull is refused when the quote nominates its own verifier" do
      # The oracle must not be chosen by the party under audit. A hostile worker
      # serving a contract it controls could answer DOMAIN_SEPARATOR() with
      # whatever makes our own projection agree -- and the allowance being spent
      # was granted to the canonical Permit2, which is where the pull runs.
      hostile = "0x00000000000000000000000000000000000badc0"

      served =
        update_in(served_pull(), ["domain"], &Map.put(&1, "verifyingContract", hostile))

      assert {:rejected, %{reason: {:verifier_mismatch, ^hostile, _expected}}} =
               verify(served, current_signature(served), @account, rpc: chain())
    end

    # Every default available here would be drawn from the payload under audit,
    # so there is no default. Omitting the pin used to fall back to one keyed on
    # the served `primaryType` -- also chosen by the party that served it -- and
    # a payload declaring some other primary type walked straight past it.
    test "refuses to run at all without :expect_verifier" do
      {served, chain} = hostile_verifier()

      assert_raise ArgumentError, ~r/:expect_verifier is required/, fn ->
        PullPreflight.verify(served, current_signature(served), @account, rpc: chain)
      end
    end

    test "refuses an :expect_verifier that is not an address" do
      {served, chain} = hostile_verifier()

      for bad <- [:permit2, nil, 42, "permit2"] do
        assert_raise ArgumentError, ~r/must be a 0x address/, fn ->
          PullPreflight.verify(served, current_signature(served), @account,
            rpc: chain,
            expect_verifier: bad
          )
        end
      end
    end

    # The whole payload is internally consistent -- the signature really does
    # cover the digest that address really will rebuild. Only the caller's pin
    # tells the two apart.
    test ":expect_verifier pins the oracle regardless of what the payload declares" do
      {served, chain} = hostile_verifier()

      assert {:rejected, %{reason: {:verifier_mismatch, @hostile, @permit2_address}}} =
               verify(served, current_signature(served), @account,
                 rpc: chain,
                 expect_verifier: @permit2_address
               )
    end

    test ":expect_verifier accepts the address the rail actually pulls through" do
      served = served_pull()

      assert {:ok, _details} =
               verify(served, current_signature(served), @account,
                 rpc: chain(),
                 expect_verifier: String.downcase(@permit2_address)
               )
    end

    # `normalize_address/1` trims and downcases, so a served verifyingContract
    # can pass the pin while differing from it byte for byte. Carrying the
    # SERVED spelling forward meant `eth_call` was asked about the payload's copy
    # of the address -- and a served `"0x…BA3 "` reached the node as an invalid
    # `to:`, stopping every funded run INCONCLUSIVE while blaming an endpoint
    # that was fine. The pin is what gets dialed.
    test "the pinned verifier is what gets dialed, not the served spelling of it" do
      {:ok, asked} = Agent.start_link(fn -> [] end)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        result =
          case req["method"] do
            "eth_chainId" ->
              "0x2105"

            "eth_getCode" ->
              "0x"

            "eth_call" ->
              [%{"to" => to} | _] = req["params"]
              Agent.update(asked, &[to | &1])
              "0x" <> Base.encode16(@permit2_separator, case: :lower)
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
        )
      end

      # Same address, different spelling: passes the pin, is not the pin.
      served =
        update_in(
          served_pull(),
          ["domain"],
          &Map.put(&1, "verifyingContract", String.downcase(@permit2_address))
        )

      assert {:ok, details} =
               verify(served, current_signature(served), @owner,
                 rpc: RPC.client(url: "http://stub.invalid/rpc", plug: plug),
                 expect_verifier: @permit2_address
               )

      assert details.verifying_contract == @permit2_address
      assert Agent.get(asked, & &1) == [@permit2_address]
    end

    # A chainId that is present but unreadable is a different defect from one
    # that is absent, and describing it as absent sends the operator looking for
    # a field that is right there in the payload they captured.
    test "a chainId that is present but unreadable is its own rejection" do
      for bad <- [-1, "not-a-chain", 1.5, %{}] do
        served = update_in(served_pull(), ["domain"], &Map.put(&1, "chainId", bad))

        assert {:rejected, %{reason: {:invalid_chain_id, ^bad}}} =
                 verify(served, "0x00", @account, rpc: chain())
      end
    end

    test "a chainId that is absent is still reported as absent" do
      served = update_in(served_pull(), ["domain"], &Map.delete(&1, "chainId"))

      assert {:rejected, %{reason: :no_chain_id}} =
               verify(served, "0x00", @account, rpc: chain())
    end

    # This module and `Protocols.Xochi` both parse domain.chainId, and they now
    # agree on what a value is. Nothing reaches here that they disagree about --
    # `EIP712` refuses a padded uint256 at signing, several steps earlier -- so
    # this pins the agreement rather than a live divergence.
    test "a chainId string parses the way the signing gate parses it" do
      served = update_in(served_pull(), ["domain"], &Map.put(&1, "chainId", "8453"))

      assert {:ok, _details} =
               verify(served, current_signature(served), @account, rpc: chain())
    end

    test "an unrecoverable signature on a codeless account is a rejection" do
      # Permit2 recovers this same signature against this same account, so a
      # signature that cannot be recovered here cannot be recovered there. This
      # is the 7702 case: a wrapped envelope on an account whose delegation is
      # not actually set has nothing to unwrap it.
      served = served_pull()
      wrapped = "0x" <> String.duplicate("ab", 72)

      assert {:rejected, %{reason: {:recover_failed, {:not_a_canonical_signature, 72}}}} =
               verify(served, wrapped, @owner, rpc: chain(code: "0x"))
    end

    test "a 65-byte signature with a non-canonical v is its own rejection reason" do
      # Distinct from the wrapped-envelope case above, and reported separately:
      # collapsing both into a byte count produced "this signature is 65 bytes
      # rather than a canonical 65", which says nothing and then pointed the
      # operator at a 7702 delegation that is not the problem. Solidity's
      # ecrecover yields the zero address for any v outside 27/28, so the pull
      # rejects this too -- for the reason named here.
      served = served_pull()

      "0x" <> hex = current_signature(served)
      <<rs::binary-size(64), _v::8>> = Base.decode16!(hex, case: :lower)
      bad_v = "0x" <> Base.encode16(rs <> <<1>>, case: :lower)

      assert {:rejected, %{reason: {:recover_failed, {:non_canonical_v, 1}}}} =
               verify(served, bad_v, @owner, rpc: chain(code: "0x"))
    end

    test "a signature that is not hex is a rejection, not a gap" do
      served = served_pull()

      assert {:rejected, %{reason: {:invalid_hex, :signature}}} =
               verify(served, "0xnothex", @account, rpc: chain())
    end

    test "an RPC answering for the wrong chain is inconclusive, never a rejection" do
      # Permit2 lives at the same address on every chain with a different
      # separator, so an RPC pointed at the wrong network returns 32 plausible
      # bytes and a CORRECT signature fails to match them. Calling that a
      # rejection would tell the operator their signing is broken when their
      # ORDER_RPC_<chain> is -- and that env var falls back to Base when unset.
      served = served_pull()

      assert {:inconclusive, {:wrong_chain, declared: 8453, node: 42_161}} =
               verify(served, current_signature(served), @account, rpc: chain(chain_id: 42_161))
    end

    test "an unreachable RPC is inconclusive, not a rejection" do
      # A failed check must never read as a verdict: reporting "signature bad"
      # when the node was down would send the next debugging round after the
      # wrong thing, which is how this issue lost two of its four attempts.
      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "upstream down") end
      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:inconclusive, {:chain_id_unavailable, _reason}} =
               verify(served, current_signature(served), @account, rpc: client)
    end

    # EIP-2098: `r || vs`, with the recovery bit in the top position of `vs`.
    # Permit2's SignatureVerification takes this alongside the 65-byte form and
    # the ERC-3009 tokens go through the same library, so refusing it here would
    # be a false REJECTED on a signature the pull would accept -- and the message
    # would point at a 7702 delegation that is not the problem.
    test "accepts a compact 64-byte signature, which the verifier also accepts" do
      served = served_pull()

      "0x" <> hex = current_signature(served)
      <<r::binary-size(32), s::binary-size(32), v::8>> = Base.decode16!(hex, case: :lower)
      <<0::1, s_rest::bitstring>> = s
      compact = "0x" <> Base.encode16(<<r::binary, v - 27::1, s_rest::bitstring>>, case: :lower)

      assert byte_size(Base.decode16!(String.trim_leading(compact, "0x"), case: :lower)) == 64

      assert {:ok, details} = verify(served, compact, @owner, rpc: chain(code: "0x"))
      assert details.signer_kind == :eoa
    end

    test "a compact signature over the WRONG digest is still rejected" do
      served = served_pull()

      "0x" <> hex = pre_878_signature(served)
      <<r::binary-size(32), s::binary-size(32), v::8>> = Base.decode16!(hex, case: :lower)
      <<0::1, s_rest::bitstring>> = s
      compact = "0x" <> Base.encode16(<<r::binary, v - 27::1, s_rest::bitstring>>, case: :lower)

      assert {:rejected, details} = verify(served, compact, @owner, rpc: chain(code: "0x"))
      refute details.returned == @owner
    end

    # `RPC.get_code/3` head-matches `"0x" <> _`, so this used to leave `verify/4`
    # as a FunctionClauseError out of a function that documents three outcomes.
    test "a buyer address that is not an 0x address leaves by one of the three doors" do
      served = served_pull()

      for bad <- ["not-an-address", "", nil, :buyer] do
        assert {:rejected, %{reason: {:invalid_account, ^bad}}} =
                 verify(served, current_signature(served), bad, rpc: chain())
      end
    end

    test "a separator that cannot be read is inconclusive" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        result = if req["method"] == "eth_chainId", do: "0x2105", else: nil

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
        )
      end

      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:inconclusive, {:domain_separator_unavailable, _vc, _reason}} =
               verify(served, current_signature(served), @account, rpc: client)
    end
  end

  # The other rail. `Mix.Tasks.RaxolEarn.Order.expected_verifier/2` pins this one
  # to `cfg.src_token` rather than to a universal address, and the live ACP gate
  # reaches it with a funded EOA -- so a gate that blocks funded runs on it had
  # no test for it at all until these.
  describe "the ERC-3009 rail" do
    test "accepts a pull whose verifier is the origin token itself" do
      served = served_erc3009_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_base
               )

      assert details.verifying_contract == @usdc_base
      assert details.signer_kind == :eoa
    end

    # The #772 defect on this rail, in the direction it would actually appear:
    # the token declares a `version` and the signer drops it, so the separator
    # the token rebuilds is not the one the signature covers. Nothing in the
    # payload looks wrong -- only the chain-sourced separator tells them apart.
    test "rejects a signature that dropped the version the token declares" do
      served = served_erc3009_pull()

      versionless =
        served["domain"]
        |> Map.delete("version")
        |> then(
          &%{name: &1["name"], chainId: &1["chainId"], verifyingContract: &1["verifyingContract"]}
        )

      {:ok, digest} =
        EIP712.hash(versionless, XochiProtocol.eip712_types(served), served["message"])

      assert {:rejected, details} =
               verify(served, sign_over(digest), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_base
               )

      refute details.returned == @owner
    end

    # The pin is the destination token, not the origin one. Getting the leg
    # backwards is a plausible caller bug, and it must not read as a signing
    # defect: the served address is named, so the log says which is which.
    test "refuses a pull pinned to the wrong side of the corridor" do
      served = served_erc3009_pull()

      assert {:rejected, %{reason: {:verifier_mismatch, @usdc_base, @usdc_arbitrum}}} =
               verify(served, current_signature(served), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_arbitrum
               )
    end

    # An ERC-3009 pull on a contract buyer goes through ERC-1271 exactly as the
    # Permit2 one does -- the branch is decided by the ACCOUNT's code, never by
    # the rail.
    test "a contract buyer on this rail is asked via ERC-1271, not recovery" do
      served = served_erc3009_pull()

      chain =
        chain(
          code: "0xef0100" <> String.duplicate("11", 20),
          foreign_separator: separator_for(served["domain"])
        )

      assert {:ok, details} =
               verify(served, current_signature(served), @account,
                 rpc: chain,
                 expect_verifier: @usdc_base
               )

      assert details.signer_kind == :contract
    end
  end

  # Every other test in this file signs with a digest the test builds. That is
  # fine for proving the checker distinguishes two digests, and useless for
  # proving it agrees with the thing that will actually sign in production --
  # which is the property #772 lost. Here the bundle comes out of
  # `Xochi.sign_intent/3` itself, so a divergence anywhere in the real signing
  # path (domain projection, types projection, pull selection) fails this.
  describe "against a bundle the production signer produced" do
    defmodule ProdWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "RAXOL_PULL_PREFLIGHT_TEST_KEY"
    end

    setup do
      System.put_env(
        "RAXOL_PULL_PREFLIGHT_TEST_KEY",
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
      )

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [@spender])

      on_exit(fn ->
        System.delete_env("RAXOL_PULL_PREFLIGHT_TEST_KEY")
        Application.delete_env(:raxol_payments, :pull_solver_allowlist)
      end)

      :ok
    end

    test "accepts the pull signature sign_intent/3 actually emits" do
      served = live_pull()

      {:ok, bundle} =
        XochiProtocol.sign_intent(quote_response(served), ProdWallet, quote_request())

      assert {:ok, details} =
               verify(served, bundle[:pull_signature], @owner,
                 rpc: chain(code: "0x"),
                 expect_verifier: @permit2_address
               )

      assert details.separator == @permit2_separator
      assert details.signer_kind == :eoa
    end

    # The same bundle, checked against a separator that is not Permit2's. If this
    # passed, the one above would be proving nothing about the domain.
    test "and rejects it against a verifier that rebuilds a different domain" do
      served = live_pull()

      {:ok, bundle} =
        XochiProtocol.sign_intent(quote_response(served), ProdWallet, quote_request())

      other = %{served["domain"] | "chainId" => 8453, "name" => "NotPermit2"}

      assert {:rejected, _} =
               verify(served, bundle[:pull_signature], @owner,
                 rpc: chain(code: "0x", foreign_separator: separator_for(other)),
                 expect_verifier: @hostile
               )
    end

    # The fixture's fixed deadline is months out and would silently start failing
    # `valid_window?` on its own schedule. Only this describe block signs through
    # the validator, so only this block needs a live one.
    defp live_pull do
      deadline = Integer.to_string(System.system_time(:second) + 3600)
      update_in(served_pull(), ["message"], &Map.put(&1, "deadline", deadline))
    end

    defp quote_response(served) do
      %QuoteResponse{
        intent_id: "xi_prod",
        quote_id: "xq_prod",
        can_solve: true,
        payment_method: "permit2",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_prod"}
        },
        pull_authorization: served
      }
    end

    defp quote_request do
      %QuoteRequest{
        wallet: @owner,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "3000000",
        settlement_preference: "public"
      }
    end
  end

  describe "describe/1" do
    test "a rejection says the pull would revert and funding would strand a fee" do
      served = served_pull()

      line =
        served
        |> verify(pre_878_signature(served), @account, rpc: chain())
        |> PullPreflight.describe()

      assert line =~ "REJECTED"
      assert line =~ "would revert"
    end

    test "a payload defect reads as a rejection, not as a check that could not run" do
      line = PullPreflight.describe({:rejected, %{reason: :no_verifying_contract}})

      assert line =~ "REJECTED"
      assert line =~ "declares no domain.verifyingContract"
      refute line =~ "could not run"
    end

    test "an unreadable chainId is not described as a missing one" do
      line = PullPreflight.describe({:rejected, %{reason: {:invalid_chain_id, -1}}})

      assert line =~ "REJECTED"
      assert line =~ "domain.chainId is not a chain id"
      refute line =~ "declares no domain.chainId"
    end

    test "a bad recovery id is not described as a length problem" do
      line =
        PullPreflight.describe({:rejected, %{reason: {:recover_failed, {:non_canonical_v, 1}}}})

      assert line =~ "recovery id is 1"
      # The defect that DOES warrant the 7702 advice is the wrapped envelope,
      # and conflating the two sent operators after the wrong thing.
      refute line =~ "7702"
      refute line =~ "bytes rather than"
    end

    test "a wrapped envelope still reads as a length problem worth checking 7702 for" do
      line =
        PullPreflight.describe(
          {:rejected, %{reason: {:recover_failed, {:not_a_canonical_signature, 72}}}}
        )

      assert line =~ "72 bytes rather than"
      assert line =~ "7702"
      # Both accepted lengths are named. Saying "a canonical 65" alone was wrong
      # once the compact 64-byte form started being accepted, and an operator
      # holding a 64-byte signature would have read it as confirmation.
      assert line =~ "65"
      assert line =~ "64"
    end

    test "an inconclusive check does not claim the signature is bad" do
      line =
        PullPreflight.describe({:inconclusive, {:domain_separator_unavailable, "0x0", :timeout}})

      assert line =~ "INCONCLUSIVE"
      assert line =~ "not a verdict"
    end

    test "a wrong-chain RPC names the CHAIN to fix rather than blaming the signature" do
      line = PullPreflight.describe({:inconclusive, {:wrong_chain, declared: 8453, node: 42_161}})

      assert line =~ "INCONCLUSIVE"
      assert line =~ "not a verdict"
      assert line =~ "chain 8453"
      assert line =~ "ORIGIN-chain endpoint"
    end

    # Two callers reach this with different variables -- `mix raxol_earn.order`
    # reads ORDER_RPC_<chain>, the live gate reads XOCHI_ORDER_RPC_<chain> -- so
    # a name hardcoded here is wrong in one of them. It named ORDER_RPC_<chain>,
    # which is the one the live gate does NOT use, and pointing an operator at a
    # variable that does not exist is the exact failure this module was built to
    # stop. Each caller names its own knob in its own error text.
    test "no gap message hardcodes a caller's environment variable" do
      gaps = [
        {:wrong_chain, declared: 8453, node: 42_161},
        {:chain_id_unavailable, :timeout},
        {:domain_separator_unavailable, "0x0", :timeout},
        {:domain_separator_length, 8},
        {:signer_kind_unavailable, "0x0", :timeout},
        {:erc1271_call_failed, "0x0", :timeout}
      ]

      for gap <- gaps do
        line = PullPreflight.describe({:inconclusive, gap})
        refute line =~ "ORDER_RPC", "#{inspect(gap)} names an env var only one caller has"
      end
    end
  end
end
