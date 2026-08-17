defmodule Raxol.Earn.Xochi.LiveOrderPinTest do
  @moduledoc """
  The funded ACP live gate grants a REAL Permit2 allowance on the buyer's origin
  wallet. Permit2 has no on-chain recipient guard, so that allowance is a standing
  capability towards whatever spender the quote named, and the operator's pin is
  the only thing bounding it.

  The gate itself cannot be exercised here: it moves money, it is tag-excluded,
  and its module body only compiles when the live env is present. So its one
  safety property is asserted against the gate's PARSED source instead -- the gate
  must reach the allowance through `Raxol.Earn.Xochi.OriginPull`, which fails
  closed on an unpinned spender, and must not hold a second route to the approver
  that skips it. Written after a review found the gate granting a max allowance
  keyed only on the served quote, while `mix raxol_earn.order` had already been
  given the pin.

  Parsed, not grepped. A text search answers the wrong question in both
  directions: a commented-out call still reads as present, so the guard would
  stay green over code that no longer runs; and merely explaining in prose why
  the approver is off-limits reads as calling it, so documenting the rule would
  break the build. `Code.string_to_quoted/1` discards comments and leaves
  docstrings as inert literals, so what remains is what executes.
  """

  use ExUnit.Case, async: true

  @gate Path.join(__DIR__, "live_order_test.exs")
  @external_resource @gate

  setup do
    {:ok, gate: analyze(File.read!(@gate))}
  end

  test "the allowance is decided by the shared pin, not by the gate", %{gate: gate} do
    assert {:OriginPull, :allowance_plan, 3} in gate.calls,
           "the live gate must decide the allowance through OriginPull, which refuses " <>
             "an unpinned or mismatched Permit2 spender"

    assert {:OriginPull, :ensure_allowance, 3} in gate.calls,
           "the live gate must grant the allowance through OriginPull, so it is bounded " <>
             "to the intent's authorized pull"
  end

  test "no path reaches the approver around the pin", %{gate: gate} do
    refute :Permit2Approver in gate.modules,
           "calling the approver directly grants an allowance without the spender pin; " <>
             "go through OriginPull"
  end

  # The pin is checked against ONE served quote. Signing a different one throws
  # the check away: a quote served `erc3009` passes the Permit2 branch trivially,
  # and a second quote served `permit2` is then signed with no pin behind it,
  # leaving only the solver allowlist -- which already contains the mirrored pull
  # proxy, i.e. exactly what the pin exists to add to.
  test "the intent signed is the quote that was checked, not a second one", %{gate: gate} do
    refute Enum.any?(gate.calls, fn {_mod, fun, _arity} -> fun == :quote_and_sign end),
           "quote_and_sign/3 fetches a FRESH quote and signs that one, so the spender pin " <>
             "and the bounded allowance would be checked against a quote the gate never signs"

    assert {:XochiProtocol, :sign_intent, 3} in gate.calls,
           "the gate must sign the quote preflight_quote/4 already checked and the " <>
             "allowance was granted against"
  end

  test "the pinned spender is operator-supplied, with no default", %{gate: gate} do
    assert {"XOCHI_ORDER_PULL_SPENDER", 1} in gate.env,
           "the Permit2 allowance pin must come from XOCHI_ORDER_PULL_SPENDER"

    refute Enum.any?(gate.env, fn {name, arity} ->
             name == "XOCHI_ORDER_PULL_SPENDER" and arity > 1
           end),
           "a default would make the gate grant an allowance towards an address nobody " <>
             "typed; unset must skip the cell instead"
  end

  # -- The gate's source, as calls rather than text --

  # `calls` are {LastAliasSegment, function, arity} for qualified calls and
  # {nil, function, arity} for local ones; `modules` is every alias segment named
  # anywhere; `env` is each System.get_env with a literal name, carrying its arity
  # so a defaulted lookup is distinguishable from an undefaulted one.
  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    empty = %{calls: MapSet.new(), modules: MapSet.new(), env: MapSet.new()}

    {_ast, found} =
      Macro.prewalk(ast, empty, fn
        {{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, [name | rest]} = node, acc
        when is_binary(name) ->
          {node, %{acc | env: MapSet.put(acc.env, {name, length(rest) + 1})}}

        {{:., _, [{:__aliases__, _, mods}, fun]}, _, args} = node, acc when is_list(args) ->
          {node, %{acc | calls: MapSet.put(acc.calls, {List.last(mods), fun, length(args)})}}

        {:__aliases__, _, mods} = node, acc ->
          {node, %{acc | modules: MapSet.union(acc.modules, MapSet.new(mods))}}

        {fun, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, %{acc | calls: MapSet.put(acc.calls, {nil, fun, length(args)})}}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
