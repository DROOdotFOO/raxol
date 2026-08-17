defmodule Raxol.Earn.Xochi.LiveOrderPinTest do
  @moduledoc """
  The funded ACP live gate grants a REAL Permit2 allowance on the buyer's origin
  wallet. Permit2 has no on-chain recipient guard, so that allowance is a standing
  capability towards whatever spender the quote named, and the operator's pin is
  the only thing bounding it.

  The gate itself cannot be exercised here: it moves money, it is tag-excluded,
  and its module body only compiles when the live env is present. So its one
  safety property is asserted against the source instead -- the gate must reach
  the allowance through `Raxol.Earn.Xochi.OriginPull`, which fails closed on an
  unpinned spender, and must not hold a second route to the approver that skips
  it. Written after a review found the gate granting a max allowance keyed only on
  the served quote, while `mix raxol_earn.order` had already been given the pin.
  """

  use ExUnit.Case, async: true

  @gate Path.join(__DIR__, "live_order_test.exs")
  @external_resource @gate

  setup do
    {:ok, source: File.read!(@gate)}
  end

  test "the allowance is decided by the shared pin, not by the gate", %{source: source} do
    assert source =~ "OriginPull.allowance_plan(",
           "the live gate must decide the allowance through OriginPull, which refuses " <>
             "an unpinned or mismatched Permit2 spender"

    assert source =~ "OriginPull.ensure_allowance(",
           "the live gate must grant the allowance through OriginPull, so it is bounded " <>
             "to the intent's authorized pull"
  end

  test "no path reaches the approver around the pin", %{source: source} do
    refute source =~ "Permit2Approver",
           "calling the approver directly grants an allowance without the spender pin; " <>
             "go through OriginPull"
  end

  test "the pinned spender is operator-supplied, with no default", %{source: source} do
    assert source =~ ~s|System.get_env("XOCHI_ORDER_PULL_SPENDER")|,
           "the Permit2 allowance pin must come from XOCHI_ORDER_PULL_SPENDER"

    refute source =~ ~s|System.get_env("XOCHI_ORDER_PULL_SPENDER",|,
           "a default would make the gate grant an allowance towards an address nobody " <>
             "typed; unset must skip the cell instead"
  end
end
