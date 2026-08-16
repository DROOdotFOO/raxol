defmodule Raxol.Payments.PolicyGatePropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.PolicyGate`. The gate is small but
  central -- every payment in the system flows through it. These
  properties pin two invariants that regress easily under refactor:

    1. Check ordering: domain rejection beats confirmation rejection.
    2. Callback isolation: `:on_confirm` is only consulted when the
       confirmation gate actually applies (domain has passed AND
       amount exceeds the threshold).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.{PolicyGate, SpendingPolicy}

  # Generators -----------------------------------------------------------

  defp host_segment do
    string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp host do
    list_of(host_segment(), min_length: 2, max_length: 4)
    |> map(&Enum.join(&1, "."))
  end

  defp positive_amount do
    map(integer(1..1_000_000), &Decimal.new/1)
  end

  defp policy_with_domain(approved_list) do
    %SpendingPolicy{
      per_request_max: Decimal.new("1000000"),
      session_max: Decimal.new("1000000"),
      lifetime_max: Decimal.new("1000000"),
      approved_domains: approved_list
    }
  end

  # Properties -----------------------------------------------------------

  property "domain check fires before confirmation check" do
    check all(
            approved_host <- host(),
            attempted_host <- host(),
            attempted_host != approved_host,
            not String.ends_with?(attempted_host, "." <> approved_host),
            amount <- positive_amount()
          ) do
      policy = %{
        policy_with_domain([approved_host])
        | require_confirmation_above: Decimal.new("0")
      }

      # Even with an always-:approve callback installed and an amount above
      # the threshold, an unapproved domain must deny on the domain reason.
      result =
        PolicyGate.evaluate(policy, amount, attempted_host, on_confirm: fn _, _ -> :approve end)

      assert match?({:deny, {:domain_not_approved, _}}, result),
             "expected domain-deny for host #{attempted_host} not in #{approved_host}, got #{inspect(result)}"
    end
  end

  property ":on_confirm is never called on a domain-denied path" do
    check all(
            approved_host <- host(),
            attempted_host <- host(),
            attempted_host != approved_host,
            not String.ends_with?(attempted_host, "." <> approved_host),
            amount <- positive_amount()
          ) do
      policy = %{
        policy_with_domain([approved_host])
        | require_confirmation_above: Decimal.new("0")
      }

      # The canary callback raises if invoked. If domain-deny fires first,
      # we never reach it.
      canary = fn _, _ -> raise "on_confirm called on a domain-denied path" end

      assert match?(
               {:deny, {:domain_not_approved, _}},
               PolicyGate.evaluate(policy, amount, attempted_host, on_confirm: canary)
             )
    end
  end

  property ":on_confirm is never called when amount is at or below threshold" do
    check all(
            amount <- positive_amount(),
            # threshold strictly >= amount
            over <- integer(0..1_000_000),
            h <- host()
          ) do
      threshold = Decimal.add(amount, Decimal.new(over))

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000000"),
        session_max: Decimal.new("1000000"),
        lifetime_max: Decimal.new("1000000"),
        require_confirmation_above: threshold
      }

      canary = fn _, _ -> raise "on_confirm called below threshold" end

      assert :ok = PolicyGate.evaluate(policy, amount, h, on_confirm: canary)
    end
  end

  property "approved domain + amount at-or-below threshold always allows" do
    check all(
            h <- host(),
            amount <- positive_amount()
          ) do
      # threshold strictly above amount -> requires_confirmation? is false
      threshold = Decimal.add(amount, Decimal.new(1))

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000000"),
        session_max: Decimal.new("1000000"),
        lifetime_max: Decimal.new("1000000"),
        # approved_domains: nil -> all domains allowed
        require_confirmation_above: threshold
      }

      assert :ok = PolicyGate.evaluate(policy, amount, h)
    end
  end
end
