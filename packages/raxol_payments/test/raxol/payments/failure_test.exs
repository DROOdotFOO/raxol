defmodule Raxol.Payments.FailureTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Failure

  describe "from/1 quote failures" do
    test "cannot_solve with a liquidity reason maps to :no_liquidity" do
      f = Failure.from({:cannot_solve, "no liquidity for this route"})
      assert f.reason == :no_liquidity
      refute f.retryable?
    end

    test "cannot_solve with a slippage reason is retryable" do
      f = Failure.from({:cannot_solve, "price impact too high (slippage)"})
      assert f.reason == :slippage
      assert f.retryable?
    end

    test "cannot_solve with a Riddler error code maps via the code table" do
      f = Failure.from({:cannot_solve, "route_not_supported"})
      assert f.reason == :route_unsupported
    end

    test "cannot_solve with a nil reason defaults to :no_liquidity" do
      f = Failure.from({:cannot_solve, nil})
      assert f.reason == :no_liquidity
    end
  end

  describe "from/1 terminal settlement" do
    test "failed with a liquidity error maps to :no_liquidity" do
      f = Failure.from({:settlement, :failed, "no liquidity available"})
      assert f.reason == :no_liquidity
    end

    test "failed without an error message is :not_filled" do
      f = Failure.from({:settlement, :failed, nil})
      assert f.reason == :not_filled
      refute f.retryable?
    end

    test "expired is retryable" do
      f = Failure.from({:settlement, :expired, nil})
      assert f.reason == :expired
      assert f.retryable?
    end

    test "refunded maps to :refunded and is not retryable" do
      f = Failure.from({:settlement, :refunded, nil})
      assert f.reason == :refunded
      refute f.retryable?
      assert to_string(f) == "The transfer failed and the funds were refunded."
    end

    test "refunded carries the solver reason into the message and detail" do
      f = Failure.from({:settlement, :refunded, "solver timeout"})
      assert f.reason == :refunded
      assert f.detail == "solver timeout"
      assert to_string(f) == "The transfer failed and the funds were refunded (solver timeout)."
    end
  end

  describe "from/1 HTTP errors" do
    test "5xx is a retryable :network error" do
      f = Failure.from({:http, 503, %{}})
      assert f.reason == :network
      assert f.retryable?
    end

    test "429 is a retryable :network error" do
      f = Failure.from({:http, 429, %{}})
      assert f.reason == :network
      assert f.retryable?
    end

    test "structured error body maps via the code table" do
      f = Failure.from({:http, 400, %{"error" => "insufficient_balance"}})
      assert f.reason == :insufficient_balance
    end

    test "404 maps to :not_filled" do
      f = Failure.from({:http, 404, %{}})
      assert f.reason == :not_filled
    end

    test "other 4xx maps to :invalid_request" do
      f = Failure.from({:http, 422, %{}})
      assert f.reason == :invalid_request
    end
  end

  describe "from/1 spend gate and config" do
    test "over_budget carries the limit type" do
      f = Failure.from({:over_budget, :per_request})
      assert f.reason == :over_budget
      assert f.message =~ "per_request"
    end

    test "policy denial maps to :rejected" do
      f = Failure.from({:deny, {:domain_not_approved, "evil.test"}})
      assert f.reason == :rejected
    end

    test "missing context maps to :config_error" do
      f = Failure.from({:missing_context, :wallet})
      assert f.reason == :config_error
      assert f.message =~ "wallet"
    end
  end

  describe "from/1 stealth and validation" do
    test "missing meta-address maps to :stealth_keys_required" do
      assert Failure.from(:stealth_meta_address_required).reason == :stealth_keys_required
    end

    test "invalid meta-address maps to :stealth_keys_required" do
      assert Failure.from({:invalid_meta_address, :invalid_format}).reason ==
               :stealth_keys_required
    end

    test "not_xochi_route maps to :route_unsupported" do
      assert Failure.from({:not_xochi_route, :x402}).reason == :route_unsupported
    end

    test "execute_failed unwraps the inner reason" do
      f = Failure.from({:execute_failed, {:http, 503, %{}}})
      assert f.reason == :network
    end

    test "erc3009-for-non-USDC maps to :method_mismatch with a clear message" do
      f = Failure.from({:method_mismatch, :erc3009_requires_usdc})
      assert f.reason == :method_mismatch
      refute f.retryable?
      assert f.message =~ "USDC"
    end
  end

  describe "from/1 transport and unknown" do
    test "timeout is retryable" do
      f = Failure.from(:timeout)
      assert f.reason == :timeout
      assert f.retryable?
    end

    test "a transport struct is a retryable :network error" do
      f = Failure.from(%Req.TransportError{reason: :econnrefused})
      assert f.reason == :network
      assert f.retryable?
    end

    test "an unrecognized term is :unknown and not retryable" do
      f = Failure.from(:some_weird_thing)
      assert f.reason == :unknown
      refute f.retryable?
    end

    test "is idempotent on a Failure" do
      f = Failure.from(:timeout)
      assert Failure.from(f) == f
    end
  end

  describe "rendering" do
    test "String.Chars returns the message" do
      f = Failure.from(:timeout)
      assert to_string(f) == f.message
    end

    test "Inspect renders reason and message as prose" do
      f = Failure.from(:timeout)
      rendered = inspect(f)
      assert rendered =~ "timeout"
      assert rendered =~ f.message
    end
  end
end
