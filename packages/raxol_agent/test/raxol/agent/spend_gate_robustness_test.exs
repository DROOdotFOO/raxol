defmodule Raxol.Agent.SpendGateRobustnessTest do
  @moduledoc """
  Regression suite for the U7-I SpendGate adversarial-review findings (money-critical
  exception-safety + registry durability). These are NOT the reserve-before-call
  *law* reds (that is `U7SpendGateRedTest`) — they pin that a RAISE in the frozen
  seams (`try_reserve` / `emit` / `call_fun`) or a stray message to the registry
  owner can never strand a charged budget, leak a claim, or destroy the dedup table.

  `async: false`: several tests poke the shared VM-global `SpendGate.Reservations`
  singleton (unexpected messages, scope sweeps), so they must not run concurrently
  with the async law suite that also drives the real gate through that registry.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.SpendGate

  # A minimal context. `budget_id` is the STABLE dedup scope (finding #4); an
  # explicit id makes two freshly-built `try_reserve` closures for one budget
  # share a reservation namespace. Callers that omit it fall back (documented).
  defp ctx(opts) do
    %{
      emit: Keyword.get(opts, :emit, fn _record -> :ok end),
      try_reserve: Keyword.get(opts, :try_reserve, fn _amount -> {:ok, 999} end),
      budget_id: Keyword.get(opts, :budget_id, make_ref())
    }
  end

  describe "finding #1 — a raise in the reserve/call window releases the claim" do
    test "try_reserve raising releases the claim (cost_ref retryable after)" do
      cost_ref = "f1-#{System.unique_integer([:positive])}"

      # One stable context (⇒ one stable dedup scope): the seam raises the FIRST
      # time, then succeeds. If the claim leaked on the raise, the retry would be
      # refused :duplicate_reserve instead of taking a fresh claim.
      {:ok, flag} = Agent.start_link(fn -> :raise end)

      tr = fn _amount ->
        case Agent.get_and_update(flag, fn s -> {s, :ok_mode} end) do
          :raise -> raise "budget boom"
          :ok_mode -> {:ok, 900}
        end
      end

      c = ctx(try_reserve: tr)

      assert_raise RuntimeError, "budget boom", fn ->
        SpendGate.reserve(c, cost_ref, 100)
      end

      assert {:ok, %{cost_ref: ^cost_ref}} = SpendGate.reserve(c, cost_ref, 100)
    end

    test "call_fun raising in around/4 releases the claim (cost_ref retryable after)" do
      cost_ref = "f1b-#{System.unique_integer([:positive])}"
      c = ctx([])

      assert_raise RuntimeError, "provider boom", fn ->
        SpendGate.around(c, cost_ref, 100, fn -> raise "provider boom" end)
      end

      # Claim released ⇒ the same cost_ref can be reserved again.
      assert {:ok, %{cost_ref: ^cost_ref}} = SpendGate.reserve(c, cost_ref, 100)
    end
  end
end
