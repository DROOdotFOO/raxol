defmodule Raxol.Payments.GateParityTest do
  @moduledoc """
  Cross-path parity: `SpendingHook` (agent Command path) and `AutoPay`
  (HTTP 402 Req path) must reach the same allow/deny decision for the
  same `(policy, amount, host)`. Both delegate to `Raxol.Payments.PolicyGate`,
  and this test pins that contract against future drift.
  """

  use ExUnit.Case, async: false

  alias Raxol.Payments.Directive.Pay
  alias Raxol.Payments.{Ledger, Req.AutoPay, SpendingHook, SpendingPolicy}

  defmodule TestWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x" <> String.duplicate("aa", 20)
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_), do: {:ok, <<0::512>>}
    @impl true
    def sign_typed_data(_, _, _) do
      case Process.get(:wallet_signal_target) do
        nil -> :ok
        pid -> send(pid, :wallet_signed)
      end

      {:ok, <<0::512>>}
    end

    @impl true
    def sign_hash(_), do: {:ok, <<0::520>>}
  end

  @cases [
    %{
      label: "unconstrained policy allows",
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000")
      },
      amount: Decimal.new("1"),
      host: "api.example.com",
      expected: :allow
    },
    %{
      label: "unapproved host denies",
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["allowed.example.com"]
      },
      amount: Decimal.new("1"),
      host: "evil.example.com",
      expected: {:deny, :domain_not_approved}
    },
    %{
      label: "approved subdomain allows",
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["example.com"]
      },
      amount: Decimal.new("1"),
      host: "api.example.com",
      expected: :allow
    },
    %{
      label: "amount over confirmation threshold denies",
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("50")
      },
      amount: Decimal.new("100"),
      host: "api.example.com",
      expected: {:deny, :requires_confirmation}
    },
    %{
      label: "amount at threshold allows",
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("50")
      },
      amount: Decimal.new("50"),
      host: "api.example.com",
      expected: :allow
    }
  ]

  for %{label: label} = scenario <- @cases do
    @scenario scenario
    test "parity: #{label}" do
      assert hook_decision(@scenario) == @scenario.expected
      assert auto_pay_decision(@scenario) == @scenario.expected
    end
  end

  defp hook_decision(%{policy: policy, amount: amount, host: host}) do
    {:ok, ledger} =
      Ledger.start_link(
        table_name: :"parity_hook_#{:erlang.unique_integer([:positive])}"
      )

    try do
      SpendingHook.set_config(%{ledger: ledger, policy: policy})

      pay =
        Pay.new(
          amount: amount,
          domain: host,
          perform: fn -> {:ok, :ignored} end
        )

      case SpendingHook.pre_execute(pay, %{agent_id: :parity}) do
        {:ok, _} -> :allow
        {:deny, {kind, _domain}} -> {:deny, kind}
        {:deny, {kind, _, _}} -> {:deny, kind}
      end
    after
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp auto_pay_decision(%{policy: policy, amount: amount, host: host}) do
    {:ok, ledger} =
      Ledger.start_link(
        table_name: :"parity_auto_#{:erlang.unique_integer([:positive])}"
      )

    Process.put(:wallet_signal_target, self())

    try do
      flush_wallet_signal()

      challenge = x402_challenge(amount)

      req =
        Req.new(url: "https://#{host}/data", retry: false)
        |> AutoPay.attach(
          wallet: TestWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :parity
        )
        |> Req.Request.prepend_request_steps(
          stub: fn r ->
            resp =
              Req.Response.new(status: 402, body: "")
              |> Req.Response.put_header("payment-required", challenge)

            {r, resp}
          end
        )

      resp = Req.Request.run!(req)

      cond do
        match?(%{error: :domain_not_approved}, resp.body) ->
          {:deny, :domain_not_approved}

        match?(%{error: :requires_confirmation}, resp.body) ->
          {:deny, :requires_confirmation}

        match?(%{error: :budget_exceeded}, resp.body) ->
          {:deny, :over_budget}

        received_signal?() ->
          :allow

        true ->
          {:unexpected, resp.body}
      end
    after
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # The Hook path sees `amount` directly in human-decimal units; the AutoPay
  # path receives the same logical amount as an x402 atomic-unit challenge
  # and normalizes via Assets.to_human. To keep parity meaningful, we scale
  # the challenge value by 10^6 (USDC decimals) using the real Base USDC
  # contract so both paths end up comparing the same human amount.
  defp x402_challenge(amount) do
    atomic =
      amount |> Decimal.mult(Decimal.new(1_000_000)) |> Decimal.to_integer()

    %{
      "maxAmountRequired" => atomic,
      "payTo" => "0x" <> String.duplicate("cd", 20),
      "asset" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "network" => "eip155:8453",
      "nonce" => "0x" <> String.duplicate("12", 32),
      "validAfter" => 0,
      "validBefore" => 9_999_999_999
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp received_signal? do
    receive do
      :wallet_signed -> true
    after
      0 -> false
    end
  end

  defp flush_wallet_signal do
    receive do
      :wallet_signed -> flush_wallet_signal()
    after
      0 -> :ok
    end
  end
end
