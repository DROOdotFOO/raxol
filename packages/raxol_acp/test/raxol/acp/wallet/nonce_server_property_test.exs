defmodule Raxol.ACP.Wallet.NonceServerPropertyTest do
  @moduledoc """
  Concurrency invariant behind the nonce seeding fix: however many callers race
  on first-use seeding, the NonceServer never hands out a duplicate nonce. Two
  transactions signed with the same nonce means one is silently dropped by the
  RPC, so uniqueness under concurrency is the property that matters. The nonces
  handed out are also exactly the contiguous run starting at the seeded base --
  no gaps that would strand later transactions.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.ACP.Wallet.NonceServer

  property "concurrent seeders get unique, gap-free nonces for any base and count" do
    check all(
            base <- integer(0..1_000_000_000),
            n <- integer(1..64),
            max_runs: 40
          ) do
      server = start_unseeded()

      nonces =
        1..n
        |> Task.async_stream(
          fn _ ->
            case NonceServer.get_next_if_seeded(server) do
              {:ok, x} -> x
              :unseeded -> NonceServer.seed_and_next(server, base)
            end
          end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.map(fn {:ok, x} -> x end)

      assert length(Enum.uniq(nonces)) == n, "duplicate nonce handed out under concurrency"
      assert Enum.sort(nonces) == Enum.to_list(base..(base + n - 1)), "nonces are not gap-free"
    end
  end

  defp start_unseeded do
    name = Module.concat(__MODULE__, "Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = NonceServer.start_link(name: name)
    name
  end
end
