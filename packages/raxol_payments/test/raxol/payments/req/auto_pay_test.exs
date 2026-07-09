defmodule Raxol.Payments.Req.AutoPayTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.{Ledger, Req.AutoPay, SpendingPolicy}

  defmodule StubWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x" <> String.duplicate("aa", 20)
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_msg), do: {:ok, <<0::512>>}
    @impl true
    def sign_typed_data(_domain, _types, _message) do
      case Process.get(:wallet_signal_target) do
        nil -> :ok
        pid -> send(pid, :wallet_signed)
      end

      {:ok, <<0::512>>}
    end

    @impl true
    def sign_hash(_digest), do: {:ok, <<0::520>>}
  end

  # Build a base64-encoded x402 `payment-required` challenge body.
  defp x402_challenge(amount) do
    %{
      "maxAmountRequired" => amount,
      "payTo" => "0x" <> String.duplicate("cd", 20),
      "asset" => "0x" <> String.duplicate("ef", 20),
      "network" => "eip155:8453",
      "nonce" => "0x" <> String.duplicate("12", 32),
      "validAfter" => 0,
      "validBefore" => 9_999_999_999
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp stub_402(amount) do
    fn req ->
      resp =
        Req.Response.new(status: 402, body: "")
        |> Req.Response.put_header("payment-required", x402_challenge(amount))

      {req, resp}
    end
  end

  # 402 on the first request, then 2xx on the retry (which carries the signed
  # x-payment header) -- i.e. a payment that actually completes.
  defp stub_402_then_ok(amount) do
    fn req ->
      resp =
        if Req.Request.get_header(req, "x-payment") == [] do
          Req.Response.new(status: 402, body: "")
          |> Req.Response.put_header("payment-required", x402_challenge(amount))
        else
          Req.Response.new(status: 200, body: "ok")
        end

      {req, resp}
    end
  end

  # 402 on the first request, then a non-2xx on the retry -- the server did not
  # honor the payment, so it did not complete.
  defp stub_402_then_error(amount) do
    fn req ->
      resp =
        if Req.Request.get_header(req, "x-payment") == [] do
          Req.Response.new(status: 402, body: "")
          |> Req.Response.put_header("payment-required", x402_challenge(amount))
        else
          Req.Response.new(status: 500, body: "server error")
        end

      {req, resp}
    end
  end

  describe "attach/2" do
    test "adds auto_pay response step to the request" do
      req =
        Req.new(url: "https://example.com")
        |> AutoPay.attach(wallet: SomeWallet)

      step_names = Enum.map(req.response_steps, fn {name, _fun} -> name end)
      assert :auto_pay in step_names
    end

    test "preserves existing response steps" do
      noop = fn {req, resp} -> {req, resp} end

      req =
        Req.new(url: "https://example.com")
        |> Req.Request.append_response_steps(custom: noop)
        |> AutoPay.attach(wallet: SomeWallet)

      step_names = Enum.map(req.response_steps, fn {name, _fun} -> name end)
      assert :custom in step_names
      assert :auto_pay in step_names
    end
  end

  describe "non-402 passthrough" do
    test "200 response passes through unchanged" do
      req =
        Req.new(url: "https://example.com", retry: false)
        |> AutoPay.attach(wallet: SomeWallet)
        |> Req.Request.prepend_request_steps(
          stub: fn req ->
            {req, Req.Response.new(status: 200, body: "ok")}
          end
        )

      resp = Req.Request.run!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "500 response passes through unchanged" do
      req =
        Req.new(url: "https://example.com", retry: false)
        |> AutoPay.attach(wallet: SomeWallet)
        |> Req.Request.prepend_request_steps(
          stub: fn req ->
            {req, Req.Response.new(status: 500, body: "error")}
          end
        )

      resp = Req.Request.run!(req)
      assert resp.status == 500
      assert resp.body == "error"
    end
  end

  describe "402 with no matching protocol" do
    test "returns original 402 when no protocol headers match" do
      req =
        Req.new(url: "https://example.com", retry: false)
        |> AutoPay.attach(wallet: SomeWallet, protocols: [:x402, :mpp])
        |> Req.Request.prepend_request_steps(
          stub: fn req ->
            resp = Req.Response.new(status: 402, body: "payment required")
            {req, resp}
          end
        )

      resp = Req.Request.run!(req)
      assert resp.status == 402
      assert resp.body == "payment required"
    end
  end

  describe "auto_pay step removal on retry" do
    test "auto_pay step is not present after attach + strip cycle" do
      req =
        Req.new(url: "https://example.com")
        |> AutoPay.attach(wallet: SomeWallet)

      # Simulate what remove_auto_pay_step does internally
      stripped = %{
        req
        | response_steps:
            Enum.reject(req.response_steps, fn {name, _} ->
              name == :auto_pay
            end)
      }

      step_names =
        Enum.map(stripped.response_steps, fn {name, _fun} -> name end)

      refute :auto_pay in step_names
    end
  end

  describe "policy gate enforcement" do
    setup do
      Process.put(:wallet_signal_target, self())

      {:ok, ledger} =
        Ledger.start_link(table_name: :"gate_ledger_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end)

      %{ledger: ledger}
    end

    test "denies 402 on a non-approved host without calling wallet", %{
      ledger: ledger
    } do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["allowed.example.com"]
      }

      req =
        Req.new(url: "https://evil.example.com/api", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :test
        )
        |> Req.Request.prepend_request_steps(stub: stub_402(1))

      resp = Req.Request.run!(req)

      assert resp.body == %{
               error: :domain_not_approved,
               domain: "evil.example.com"
             }

      refute_received :wallet_signed
    end

    test "denies 402 when amount exceeds confirmation threshold and no callback is given",
         %{
           ledger: ledger
         } do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("50")
      }

      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :test
        )
        # 100_000_000 atomic = 100 USDC, exceeds the 50-dollar threshold.
        |> Req.Request.prepend_request_steps(stub: stub_402(100_000_000))

      resp = Req.Request.run!(req)

      assert %{error: :requires_confirmation, domain: "api.example.com"} =
               resp.body

      refute_received :wallet_signed
    end

    test "calls wallet when on_confirm returns :approve", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("50")
      }

      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :test,
          on_confirm: fn _amount, _domain -> :approve end
        )
        |> Req.Request.prepend_request_steps(stub: stub_402(100_000_000))

      _resp = Req.Request.run!(req)
      assert_received :wallet_signed
    end

    test "denies when on_confirm returns :deny", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        require_confirmation_above: Decimal.new("50")
      }

      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :test,
          on_confirm: fn _amount, _domain -> :deny end
        )
        |> Req.Request.prepend_request_steps(stub: stub_402(100_000_000))

      resp = Req.Request.run!(req)

      assert %{error: :requires_confirmation, domain: "api.example.com"} =
               resp.body

      refute_received :wallet_signed
    end

    test "approved domain + amount within budget signs and records under real host",
         %{
           ledger: ledger
         } do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["api.example.com"]
      }

      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: policy,
          agent_id: :test
        )
        |> Req.Request.prepend_request_steps(stub: stub_402_then_ok(1))

      resp = Req.Request.run!(req)
      assert resp.status == 200
      assert_received :wallet_signed

      # Brief settle for the ledger cast/call to flush.
      :timer.sleep(20)
      # A completed payment records exactly the spend -- no release.
      [entry] = Ledger.get_history(ledger, :test)
      assert entry.metadata.domain == "api.example.com"
      refute entry.metadata[:type] == :release
    end
  end

  describe "budget release on a payment that does not complete" do
    setup do
      Process.put(:wallet_signal_target, self())

      {:ok, ledger} =
        Ledger.start_link(table_name: :"autopay_release_#{:erlang.unique_integer()}")

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["api.example.com"]
      }

      %{ledger: ledger, policy: policy}
    end

    defp autopay_req(ledger, policy, stub) do
      Req.new(url: "https://api.example.com/data", retry: false)
      |> AutoPay.attach(wallet: StubWallet, ledger: ledger, policy: policy, agent_id: :test)
      |> Req.Request.prepend_request_steps(stub: stub)
    end

    test "a non-2xx paid retry releases the reservation", %{ledger: ledger, policy: policy} do
      resp = autopay_req(ledger, policy, stub_402_then_error(1)) |> Req.Request.run!()
      assert resp.status == 500
      assert_received :wallet_signed

      :timer.sleep(20)
      # Spend was reserved then released; totals net back to zero.
      assert Decimal.equal?(Ledger.get_totals(ledger, :test, policy).lifetime, "0")
    end

    test "a transport error on the paid retry releases the reservation", %{
      ledger: ledger,
      policy: policy
    } do
      # First request 402s; the retry (carrying x-payment) raises a transport error.
      stub = fn req ->
        if Req.Request.get_header(req, "x-payment") == [] do
          resp =
            Req.Response.new(status: 402, body: "")
            |> Req.Response.put_header("payment-required", x402_challenge(1))

          {req, resp}
        else
          {req, %Req.TransportError{reason: :econnrefused}}
        end
      end

      _resp = autopay_req(ledger, policy, stub) |> Req.Request.run!()

      :timer.sleep(20)
      assert Decimal.equal?(Ledger.get_totals(ledger, :test, policy).lifetime, "0")
    end

    test "a malformed (float) price is rejected before any reservation or signing", %{
      ledger: ledger,
      policy: policy
    } do
      # A float price is not valid atomic units, so the x402 challenge is rejected
      # at parse: no protocol matches, nothing is reserved, nothing is signed.
      resp = autopay_req(ledger, policy, stub_402_then_ok(0.05)) |> Req.Request.run!()

      assert resp.status == 402
      refute_received :wallet_signed
      :timer.sleep(20)
      assert Decimal.equal?(Ledger.get_totals(ledger, :test, policy).lifetime, "0")
    end
  end
end
