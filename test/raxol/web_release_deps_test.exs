defmodule Raxol.WebReleaseDepsTest do
  @moduledoc """
  The deploy app must carry what the hosted coding agent needs.

  `raxol_agent` declares `req` optional and main raxol does not depend on
  `raxol_payments` at all. Optional deps do not propagate, so a release that
  merely depends on `raxol_agent` gets neither -- and every gate would pass
  while every LLM turn failed with `:req_not_available`, or the agent would
  refuse to start for want of a ledger.

  This asserts on `web/mix.exs` and `web/mix.lock` rather than on
  `Code.ensure_loaded?/1`, deliberately: `req` is an optional dep of the ROOT
  project, so Mix fetches it for THIS suite whatever `web/` declares. The
  absence only ever manifests in the release tree, which no ExUnit suite loads.
  Reading the lock is the strongest committed proxy, and `mix raxol.check`'s
  lockfile step runs against the root project, not `web/`.
  """
  use ExUnit.Case, async: true

  @web_root Path.expand("../../web", __DIR__)

  defp mix_exs, do: File.read!(Path.join(@web_root, "mix.exs"))
  defp mix_lock, do: File.read!(Path.join(@web_root, "mix.lock"))

  test "web/mix.exs declares the hosted coding agent's dependencies" do
    source = mix_exs()

    assert source =~ ~s({:raxol_agent, path: "../packages/raxol_agent"})
    assert source =~ ~s({:raxol_payments, path: "../packages/raxol_payments"})
    assert source =~ ~s({:req, )
  end

  test "web/mix.lock resolved them into the release tree" do
    lock = mix_lock()

    for package <- ~w(req decimal ex_secp256k1 ex_keccak) do
      assert lock =~ ~s("#{package}": ),
             "web/mix.lock has no #{package}; the deploy release would ship " <>
               "without it. Run `cd web && mix deps.get`."
    end
  end
end
