defmodule Raxol.Payments.SigningBoundaryPropertyTest do
  @moduledoc """
  The signing boundary is the crown jewel: a BEAM process holds a key that can
  move USDC/USDT/WETH across chains. The invariant that must never regress is

      a spend-gate rejection implies zero wallet signatures.

  Put another way, no money-moving Action may reach `wallet.sign_*` unless
  `SpendGate.authorize/3` returned `:ok` first. The per-Action tests each pin one
  rejection reason (over per-request); this file generalizes that to the whole
  rejection space and adds two structural guards so a future Action can't quietly
  open a path to the signer.

  ## How it detects a leak

  `SentinelWallet` announces every signature to the test process. Since an Action
  runs synchronously in that process, a signature reached after the gate said no
  lands in the mailbox and `refute_received :wallet_signed` fails. The Action must
  also return the gate's error (not a network/route error), so the "no signature"
  assertion is never vacuously true.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Actions.Payments
  alias Raxol.Payments.Actions.Payments.{ExecuteRelayTransfer, ExecuteXochiIntent}
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @tron 728_126_428
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  # A gate rejection surfaces through `Failure.from/1` as one of these reasons.
  # Asserting the failure is one of them proves the gate stopped the payment,
  # rather than an unrelated error making "no signature" vacuously true.
  @gate_reasons [:over_budget, :rejected, :policy_required]

  # Wallet whose every signer announces itself to the calling (test) process.
  defmodule SentinelWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_domain, _types, _message), do: signed()
    def sign_message(_message), do: signed()
    def sign_hash(_digest), do: signed()

    defp signed do
      send(self(), :wallet_signed)
      {:ok, <<7::size(520)>>}
    end
  end

  # -- ExecuteXochiIntent: gate rejection never signs --

  describe "ExecuteXochiIntent signing boundary" do
    property "no amount over the per-request cap is ever signed" do
      # Any amount above the 0.10 cap must be denied at the gate before signing,
      # for the whole range of amounts a caller might submit.
      check all(cents <- integer(11..500)) do
        stub_xochi()
        ledger = fresh_ledger()

        ctx =
          xochi_ctx(ledger, xochi_policy(%{per_request_max: dec("0.10")}))

        params = xochi_params(cents_to_amount(cents))

        assert {:error, %Failure{reason: :over_budget}} =
                 ExecuteXochiIntent.run(params, ctx)

        refute_received :wallet_signed
      end
    end

    test "no categorical gate rejection is ever signed" do
      # The non-budget gate branches (domain not approved, confirmation withheld,
      # a required-but-missing policy) must each stop before the signature too.
      for scenario <- categorical_xochi_scenarios() do
        stub_xochi()
        ledger = fresh_ledger()
        ctx = categorical_ctx(ledger, scenario)

        assert {:error, %Failure{reason: reason}} =
                 ExecuteXochiIntent.run(xochi_params("0.50"), ctx),
               "#{scenario.label}: expected a gate rejection"

        assert reason in @gate_reasons,
               "#{scenario.label}: #{inspect(reason)} is not a gate rejection"

        refute_received :wallet_signed
      end
    end
  end

  # -- ExecuteRelayTransfer: gate rejection never signs, even with a gasless
  # quote that WOULD sign if the gate were bypassed --

  describe "ExecuteRelayTransfer signing boundary" do
    property "no amount over the per-request cap is signed, even on a gasless quote" do
      # A gasless quote is the relay path that actually signs typed data. If the
      # gate is honored, no amount over the cap reaches that signature.
      check all(cents <- integer(11..500)) do
        stub_relay_gasless()
        ledger = fresh_ledger()

        ctx =
          relay_ctx(ledger, relay_policy(%{per_request_max: dec("0.10")}))

        params = relay_params(cents_to_amount(cents))

        assert {:error, %Failure{reason: :over_budget}} =
                 ExecuteRelayTransfer.run(params, ctx)

        refute_received :wallet_signed
      end
    end
  end

  # -- Structural guards: keep the boundary from silently widening --

  describe "signing-boundary structural guards" do
    test "every sensitive money-moving Action has a known signing mechanism" do
      # If a new `sensitive: true` Action appears, this fails until it is
      # classified here. Each entry names how it is kept from reaching a signer
      # without authorization:
      #
      #   ExecuteXochiIntent  -- SpendGate.authorize/3 before Xochi.execute signs
      #   ExecuteRelayTransfer-- SpendGate.authorize/3 before wallet.sign_typed_data
      #   Transfer            -- authorize-only; never signs (returns "authorized")
      #   CreateMandate       -- signs a struct-derived Mandate digest (sign_hash),
      #                          not an arbitrary hash; gated at LLM tool dispatch
      #                          by `sensitive: true` (see ToolGateTest)
      #   ExecuteDepositRoute -- verify-only; never signs. It fetches a Tron-origin
      #                          quote and verifies the deposit_attestation, then
      #                          returns the deposit instructions. raxol has no Tron
      #                          tx stack and moves no funds; the agent funds the
      #                          verified address externally. `sensitive: true`
      #                          gates it at LLM dispatch since acting on its output
      #                          moves real funds.
      known_sensitive =
        MapSet.new([
          Payments.Transfer,
          Payments.ExecuteXochiIntent,
          Payments.ExecuteRelayTransfer,
          Payments.ExecuteDepositRoute,
          Payments.CreateMandate
        ])

      actual_sensitive =
        Payments.actions()
        |> Enum.filter(& &1.__action_meta__().sensitive)
        |> MapSet.new()

      assert actual_sensitive == known_sensitive,
             "sensitive Action set changed; classify the new/removed Action's " <>
               "signing mechanism here. Added: #{inspect(MapSet.difference(actual_sensitive, known_sensitive) |> MapSet.to_list())}, " <>
               "removed: #{inspect(MapSet.difference(known_sensitive, actual_sensitive) |> MapSet.to_list())}"
    end

    test "no Action module reaches the opaque-digest signer sign_hash" do
      # `sign_hash/1` signs a precomputed 32-byte digest with no amount to check,
      # so it must stay unreachable from LLM-callable Actions. Its only intended
      # caller is `Mandate.sign/2`, which computes the digest from a validated
      # Mandate struct. Guard: no file under the Actions tree references it.
      offenders =
        "lib/raxol/payments/actions/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn path -> File.read!(path) =~ "sign_hash" end)

      assert offenders == [],
             "these Action modules reference sign_hash and may bypass the gate: " <>
               inspect(offenders)
    end
  end

  # -- Helpers --

  defp dec(s), do: Decimal.new(s)

  defp cents_to_amount(cents),
    do: cents |> Decimal.new() |> Decimal.div(100) |> Decimal.to_string()

  defp fresh_ledger do
    spec =
      Supervisor.child_spec({Ledger, [name: nil]},
        id: {:ledger, System.unique_integer([:positive])}
      )

    start_supervised!(spec)
  end

  # Xochi ------------------------------------------------------------------

  defp xochi_config do
    %{
      base_url: "https://xochi.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp xochi_policy(overrides) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: dec("1.00"),
        session_max: dec("1000.00"),
        lifetime_max: dec("1000.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["xochi.test"]
      },
      overrides
    )
  end

  defp xochi_ctx(ledger, policy) do
    %{
      wallet: SentinelWallet,
      xochi_config: xochi_config(),
      ledger: ledger,
      policy: policy,
      agent_id: "a1"
    }
  end

  defp xochi_params(amount) do
    %{
      amount: amount,
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc_base,
      to_token: @usdc_base,
      settlement: "stealth",
      recipient_meta_address: recipient_meta()
    }
  end

  defp recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  # A quote that would lead to a signature (canSolve, eip712Data). toAmount is
  # large enough to clear any same-asset delivery floor for the tested amounts,
  # so the gate -- not the floor -- is the thing that stops the payment.
  defp stub_xochi do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            "toAmount" => "5000000",
            "xochiFee" => "1000",
            "eip712Data" => %{
              "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
              "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
              "message" => %{"amount" => 500_000}
            }
          })

        "/api/intent/execute" ->
          Req.Test.json(conn, %{
            "success" => true,
            "intentId" => "int_1",
            "status" => "executing",
            "stealthAddress" => "0xstealth"
          })
      end
    end)
  end

  defp categorical_xochi_scenarios do
    [
      %{
        label: :domain_not_approved,
        policy: xochi_policy(%{approved_domains: ["not-xochi.test"]}),
        extra_ctx: %{}
      },
      %{
        label: :confirmation_withheld,
        policy: xochi_policy(%{require_confirmation_above: dec("0.00")}),
        extra_ctx: %{}
      },
      %{
        # A required-but-missing policy: no SpendingPolicy in context, and
        # require_policy on -- the guard must fail closed rather than treat a
        # missing policy as unlimited spend.
        label: :policy_required_but_missing,
        policy: nil,
        extra_ctx: %{require_policy: true}
      }
    ]
  end

  # Build the context for a categorical scenario. A nil policy means "no
  # SpendingPolicy in context", so the :policy key is left out entirely.
  defp categorical_ctx(ledger, %{policy: nil, extra_ctx: extra}) do
    ledger
    |> xochi_ctx(nil)
    |> Map.delete(:policy)
    |> Map.merge(extra)
  end

  defp categorical_ctx(ledger, %{policy: policy, extra_ctx: extra}) do
    ledger
    |> xochi_ctx(policy)
    |> Map.merge(extra)
  end

  # Relay ------------------------------------------------------------------

  defp relay_config do
    %{
      base_url: "https://relay.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp relay_policy(overrides) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: dec("1.00"),
        session_max: dec("1000.00"),
        lifetime_max: dec("1000.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["relay.test"]
      },
      overrides
    )
  end

  defp relay_ctx(ledger, policy) do
    %{
      wallet: SentinelWallet,
      relay_config: relay_config(),
      ledger: ledger,
      policy: policy,
      agent_id: "a1"
    }
  end

  defp relay_params(amount) do
    %{
      amount: amount,
      from_chain_id: 8453,
      to_chain_id: @tron,
      from_token: @usdc_base,
      to_token: @usdt_trc20,
      to_address: @tron_addr,
      settlement: "public"
    }
  end

  # A gasless quote: the relay path that actually signs typed data. If the gate
  # were bypassed, `maybe_sign_gasless` would reach SentinelWallet.sign_typed_data.
  defp stub_relay_gasless do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/relay/quote" ->
          Req.Test.json(conn, %{
            "transfer_id" => "t_1",
            "quote_id" => "q_1",
            "can_fill" => true,
            "to_amount" => "499000",
            "deposit_address" => "0xdeposit",
            "gasless" => %{
              "domain" => %{"name" => "Permit2", "chainId" => 8453},
              "types" => %{"Permit" => [%{"name" => "amount", "type" => "uint256"}]},
              "message" => %{"amount" => 500_000}
            }
          })

        "/relay/execute" ->
          Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
      end
    end)
  end
end
