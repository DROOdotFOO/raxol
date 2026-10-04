defmodule RaxolPlayground.SettlementSandbox do
  @moduledoc """
  Deterministic, fund-free Xochi context for the landing-page settlement demo.

  Requests still cross the production `ExecuteXochiIntent` and
  `PollXochiStatus` action boundaries. Only the external Xochi HTTP service and
  wallet signature are local deterministic substitutes. This keeps the demo
  safe to run while exercising quote validation, the spending gate, signing,
  submission, polling, and ledger accounting.
  """

  import Plug.Conn

  alias Raxol.Payments.{Assets, FeeSchedule, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  @base 8453
  @arbitrum 42_161
  @amount "25.00"
  @trust_score 25
  @agent_id :settlement_demo
  @intent_id "demo_intent_4812"
  @quote_id "demo_quote_4812"

  defmodule Wallet do
    @moduledoc false
    @signature_key {__MODULE__, :signatures}

    def address, do: "0x" <> String.duplicate("11", 20)
    def chain_id, do: 8453

    def sign_typed_data(_domain, _types, _message) do
      Process.put(@signature_key, signatures() + 1)
      {:ok, <<7::size(520)>>}
    end

    def sign_message(_message), do: {:ok, <<7::size(520)>>}
    def sign_hash(_hash), do: {:ok, <<7::size(520)>>}
    def signatures, do: Process.get(@signature_key, 0)
    def reset_signatures, do: Process.delete(@signature_key)
  end

  @type run :: %{
          context: map(),
          payment: map(),
          route: String.t(),
          session_cap: Decimal.t()
        }

  @doc "Build the isolated context and request used by the settlement demo."
  @spec start(map()) :: {:ok, run()}
  def start(overrides \\ %{}) when is_map(overrides) do
    Wallet.reset_signatures()

    with {:ok, ledger} <- Ledger.start_link(name: nil),
         {:ok, from_token} <- Assets.address(@base, "USDC"),
         {:ok, to_token} <- Assets.address(@arbitrum, "USDC") do
      session_cap = Decimal.new("50.00")

      context = %{
        wallet: Wallet,
        xochi_config: %{
          base_url: "https://xochi.sandbox",
          auth_token: "sandbox",
          req_options: [plug: &respond/1, retry: false]
        },
        ledger: ledger,
        policy: %SpendingPolicy{
          per_request_max: session_cap,
          session_max: session_cap,
          lifetime_max: Decimal.new("100.00"),
          currency: "USDC",
          approved_domains: ["xochi.sandbox"]
        },
        agent_id: @agent_id
      }

      payment =
        Map.merge(
          %{
            amount: @amount,
            from_chain_id: @base,
            to_chain_id: @arbitrum,
            from_token: from_token,
            to_token: to_token,
            settlement: "stealth",
            recipient_meta_address: recipient_meta_address(),
            trust_score: @trust_score,
            slippage_bps: 50,
            min_to_amount: "24900000"
          },
          overrides
        )

      {:ok,
       %{
         context: context,
         payment: payment,
         route:
           "#{Assets.chain_name(payment.from_chain_id)} → #{Assets.chain_name(payment.to_chain_id)}",
         session_cap: session_cap
       }}
    end
  end

  @doc "Render the observed settlement results as a compact replay."
  @spec lines(map()) :: [String.t()]
  def lines(%{
        demo: demo,
        intent: intent,
        receipt: receipt,
        denied: denied,
        safe?: safe?,
        t: tick
      }) do
    payment = demo.payment
    score = payment.trust_score

    fee_bps =
      score |> FeeSchedule.tier_for_score() |> FeeSchedule.headline_bps(:stable)

    at = rem(tick, 5)

    totals =
      Ledger.get_totals(
        demo.context.ledger,
        demo.context.agent_id,
        demo.context.policy
      )

    head = [
      "XOCHI SANDBOX REPLAY · NO FUNDS",
      "#{demo.route} · #{payment.amount} USDC · #{payment.settlement}",
      "trust #{score}/100 · fee #{units(intent.xochi_fee)} USDC (#{fee_bps} bps)",
      "cap #{demo.session_cap} · spent #{totals.session} · min #{units(payment.min_to_amount)}",
      " "
    ]

    rows = [
      {"request", "slippage #{payment.slippage_bps} bps"},
      {"execute", "#{units(intent.to_amount)} USDC · #{intent.intent_id}"},
      {"receipt", "#{receipt.status} · #{receipt.settlement_type}"},
      {"guard", guard(denied, safe?)}
    ]

    head ++
      Enum.with_index(rows, fn {name, detail}, index ->
        "#{mark(index, at, tick)} #{String.pad_trailing(name, 8)} #{detail}"
      end)
  end

  defp mark(index, at, _tick) when index < at, do: "✓"
  defp mark(index, index, tick), do: Enum.at(~w(⠋ ⠙ ⠹ ⠸), rem(tick, 4))
  defp mark(_index, _at, _tick), do: "○"

  defp guard(%{reason: :over_budget}, true), do: "75.00 denied · no signature"
  defp guard(_denied, _signature_held?), do: "ERROR: unsafe denial"

  defp units(atomic) do
    atomic
    |> Decimal.new()
    |> Decimal.div(1_000_000)
    |> Decimal.round(4)
    |> to_string()
  end

  defp recipient_meta_address do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  defp respond(%Plug.Conn{request_path: "/api/intent/quote"} = conn) do
    {:ok, raw, conn} = read_body(conn)
    request = Jason.decode!(raw)
    from_amount = String.to_integer(request["from_amount"])
    tier = FeeSchedule.tier_for_score(request["trust_score"])
    fee_bps = FeeSchedule.headline_bps(tier, :stable)
    fee = div(from_amount * fee_bps, 10_000)

    to_amount = Integer.to_string(from_amount - fee)

    json(conn, %{
      "intentId" => @intent_id,
      "quoteId" => @quote_id,
      "canSolve" => true,
      "toAmount" => to_amount,
      "xochiFee" => Integer.to_string(fee),
      "eip712Data" => intent_eip712(request, to_amount)
    })
  end

  defp respond(%Plug.Conn{request_path: "/api/intent/execute"} = conn) do
    json(conn, %{
      "success" => true,
      "intentId" => @intent_id,
      "status" => "executing",
      "stealthAddress" => "0x" <> String.duplicate("42", 20)
    })
  end

  defp respond(
         %Plug.Conn{request_path: "/api/intent/" <> @intent_id <> "/status"} =
           conn
       ) do
    json(conn, %{
      "intentId" => @intent_id,
      "status" => "completed",
      "settlementType" => "stealth",
      "txHash" => "0x" <> String.duplicate("48", 32),
      "terminal" => true
    })
  end

  defp respond(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "unknown sandbox route"}))
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  # The XochiIntent Riddler's worker serves, built from the posted quote body the
  # way its `build_message` does, so the production signer's request-binding
  # check passes exactly as it would live. Signed toAmount == top-level toAmount.
  defp intent_eip712(request, to_amount) do
    %{
      "domain" => %{
        "name" => "Xochi",
        "version" => "1",
        "chainId" => request["from_chain_id"],
        "salt" => "0x" <> String.duplicate("00", 32)
      },
      "primaryType" => "XochiIntent",
      "types" => %{
        "XochiIntent" =>
          Enum.map(
            [
              {"intentId", "string"},
              {"quoteId", "string"},
              {"wallet", "address"},
              {"recipient", "string"},
              {"fromChainId", "uint256"},
              {"toChainId", "uint256"},
              {"fromToken", "string"},
              {"toToken", "string"},
              {"fromAmount", "uint256"},
              {"toAmount", "uint256"},
              {"settlementPreference", "string"},
              {"deadline", "uint256"}
            ],
            fn {name, type} -> %{"name" => name, "type" => type} end
          )
      },
      "message" => %{
        "intentId" => @intent_id,
        "quoteId" => @quote_id,
        "wallet" => address_value(request["wallet"]),
        "recipient" => request["recipient_address"] || request["wallet"],
        "fromChainId" => request["from_chain_id"],
        "toChainId" => request["to_chain_id"],
        "fromToken" => address_value(request["from_token"]),
        "toToken" => address_value(request["to_token"]),
        "fromAmount" => request["from_amount"],
        "toAmount" => to_amount,
        "settlementPreference" => request["settlement_preference"] || "public",
        "deadline" => System.system_time(:second) + 300
      }
    }
  end

  defp address_value("0x" <> _ = address), do: String.downcase(address)
  defp address_value(other), do: other
end
