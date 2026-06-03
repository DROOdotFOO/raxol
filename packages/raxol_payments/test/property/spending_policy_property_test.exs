defmodule Raxol.Payments.SpendingPolicyPropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.SpendingPolicy.domain_approved?/2`.

  The classic mistake here is matching subdomains by string suffix
  alone, which lets `evil-example.com` match `example.com`. The
  function uses an explicit `"." <> approved` boundary check; these
  properties pin that boundary across generated string shapes.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.SpendingPolicy

  defp host_segment do
    string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp host do
    list_of(host_segment(), min_length: 2, max_length: 4)
    |> map(&Enum.join(&1, "."))
  end

  defp policy_with(approved_list) do
    %SpendingPolicy{
      per_request_max: Decimal.new(1),
      session_max: Decimal.new(1),
      lifetime_max: Decimal.new(1),
      approved_domains: approved_list
    }
  end

  property "exact match is always approved" do
    check all(h <- host()) do
      assert SpendingPolicy.domain_approved?(policy_with([h]), h)
    end
  end

  property "any subdomain of approved is approved" do
    check all(
            base <- host(),
            prefix <- host_segment()
          ) do
      domain = prefix <> "." <> base

      assert SpendingPolicy.domain_approved?(policy_with([base]), domain),
             "expected #{domain} to be approved under #{base}"
    end
  end

  property "case differences do not affect approval" do
    check all(
            base <- host(),
            prefix <- host_segment()
          ) do
      domain = String.upcase(prefix <> "." <> base)
      assert SpendingPolicy.domain_approved?(policy_with([base]), domain)
    end
  end

  property "prefix-sneaking never approves: 'X-approved' must not match 'approved'" do
    check all(
            approved <- host(),
            sneaker_prefix <- host_segment()
          ) do
      # `sneaker-approved` ends with `approved` but has no dot boundary.
      sneaker = sneaker_prefix <> "-" <> approved

      refute SpendingPolicy.domain_approved?(policy_with([approved]), sneaker),
             "prefix sneak #{sneaker} should NOT match #{approved}"
    end
  end

  property "shorter-than-approved domain never approves" do
    check all(
            approved <- host(),
            shorter <- host_segment()
          ) do
      # A bare segment can never be longer than a multi-segment approved host
      # AND can never include the dot boundary, so it must not approve.
      if String.length(shorter) < String.length(approved) and
           shorter != approved do
        refute SpendingPolicy.domain_approved?(policy_with([approved]), shorter)
      end
    end
  end

  property "empty domain never approves under any non-empty policy" do
    check all(approved_list <- list_of(host(), min_length: 1, max_length: 3)) do
      refute SpendingPolicy.domain_approved?(policy_with(approved_list), "")
    end
  end

  property "nil approved_domains approves every non-empty domain" do
    check all(h <- host()) do
      policy = policy_with(nil)
      assert SpendingPolicy.domain_approved?(policy, h)
    end
  end

  property "empty approved_domains list denies every domain" do
    check all(h <- host()) do
      refute SpendingPolicy.domain_approved?(policy_with([]), h)
    end
  end
end
