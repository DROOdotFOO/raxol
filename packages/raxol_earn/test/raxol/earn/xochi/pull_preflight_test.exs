defmodule Raxol.Earn.Xochi.PullPreflightTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Earn.Xochi.PullPreflight
  alias Raxol.Payments.EIP712

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

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      result =
        case req["method"] do
          # A 7702 delegation designator is code; "0x" is a bare EOA.
          "eth_getCode" ->
            code

          "eth_call" ->
            [%{"to" => to, "data" => data} | _] = req["params"]
            dispatch(String.downcase(to), data)
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

  defp dispatch(to, _data) when to == "0x000000000022d473030f116ddee9f6b43ac78ba3" do
    "0x" <> Base.encode16(@permit2_separator, case: :lower)
  end

  defp dispatch(to, data) when to == @account do
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

  defp types_for(served) do
    served["types"]
    |> Map.drop(["EIP712Domain"])
    |> Map.new(fn {name, fields} ->
      {name, Enum.map(fields, fn f -> {f["name"], f["type"]} end)}
    end)
  end

  defp sign_over(digest) do
    {:ok, raw} = ExSecp256k1.sign(digest, @key)
    "0x" <> Base.encode16(EIP712.pack_signature(raw), case: :lower)
  end

  # What the buyer emits today: the domain projected from the served map, which
  # for this payload is exactly the three fields Permit2 declares.
  defp current_signature(served) do
    domain = Raxol.Payments.Protocols.Xochi.eip712_domain(served)
    {:ok, digest} = EIP712.hash(domain, types_for(served), served["message"])
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

    {:ok, digest} = EIP712.hash(domain, types_for(served), served["message"])
    sign_over(digest)
  end

  describe "verify/4" do
    test "accepts a pull signed over Permit2's own domain separator" do
      served = served_pull()

      assert {:ok, details} =
               PullPreflight.verify(served, current_signature(served), @account, rpc: chain())

      assert details.separator == @permit2_separator
      assert details.verifying_contract == @permit2_address
      assert details.signer_kind == :contract
    end

    test "verifies an EOA buyer by recovery, since it has no isValidSignature to call" do
      # The live ACP gate's buyer is a plain funded key, where Permit2 does
      # ecrecover rather than an ERC-1271 call. Same digest, different check.
      served = served_pull()

      assert {:ok, details} =
               PullPreflight.verify(served, current_signature(served), @owner,
                 rpc: chain(code: "0x")
               )

      assert details.signer_kind == :eoa
    end

    test "rejects an EOA signature that recovers to someone else, naming who" do
      served = served_pull()

      assert {:error, {:signature_rejected, details}} =
               PullPreflight.verify(served, current_signature(served), @account,
                 rpc: chain(code: "0x")
               )

      assert details.signer_kind == :eoa
      assert details.returned == @owner
    end

    test "rejects the pre-#878 signature for an EOA buyer too" do
      # The domain defect was never specific to smart accounts. It only
      # SURFACED there, because EOA buyers resolved to erc3009 and never took
      # the Permit2 path at all.
      served = served_pull()

      assert {:error, {:signature_rejected, details}} =
               PullPreflight.verify(served, pre_878_signature(served), @owner,
                 rpc: chain(code: "0x")
               )

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

      assert {:error, {:signature_rejected, details}} =
               PullPreflight.verify(served, pre_878_signature(served), @account, rpc: chain())

      assert details.returned == <<0xFF, 0xFF, 0xFF, 0xFF>>
      assert details.separator == @permit2_separator
    end

    test "the two signatures genuinely differ, so the pass above is not vacuous" do
      served = served_pull()
      refute current_signature(served) == pre_878_signature(served)
    end

    test "a served domain with no verifyingContract has nothing to ask" do
      served = Map.put(served_pull(), "domain", %{"name" => "Xochi", "chainId" => 8453})

      assert {:error, :no_verifying_contract} =
               PullPreflight.verify(served, "0x00", @account, rpc: chain())
    end

    test "an unreachable RPC is inconclusive, not a rejection" do
      # A failed check must never read as a verdict: reporting "signature bad"
      # when the node was down would send the next debugging round after the
      # wrong thing, which is how this issue lost two of its four attempts.
      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "upstream down") end
      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:error, {:domain_separator_unavailable, _vc, _reason}} =
               PullPreflight.verify(served, current_signature(served), @account, rpc: client)
    end
  end

  describe "describe/1" do
    test "a rejection says the pull would revert and funding would strand a fee" do
      served = served_pull()

      line =
        served
        |> PullPreflight.verify(pre_878_signature(served), @account, rpc: chain())
        |> PullPreflight.describe()

      assert line =~ "REJECTED"
      assert line =~ "would revert"
    end

    test "an inconclusive check does not claim the signature is bad" do
      line = PullPreflight.describe({:error, {:domain_separator_unavailable, "0x0", :timeout}})

      assert line =~ "INCONCLUSIVE"
      assert line =~ "not a verdict"
    end
  end
end
