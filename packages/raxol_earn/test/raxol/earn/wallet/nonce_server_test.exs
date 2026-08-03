defmodule Raxol.Earn.Wallet.NonceServerTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Wallet.NonceServer

  defp start(opts \\ []) do
    name = Module.concat(__MODULE__, "Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = NonceServer.start_link(Keyword.put(opts, :name, name))
    name
  end

  describe "start_link/1" do
    test "default initial_nonce is 0" do
      server = start()
      assert NonceServer.peek(server) == 0
    end

    test "respects custom initial_nonce" do
      server = start(initial_nonce: 42)
      assert NonceServer.peek(server) == 42
    end
  end

  describe "get_next/1" do
    test "returns current value and increments" do
      server = start(initial_nonce: 10)
      assert NonceServer.get_next(server) == 10
      assert NonceServer.get_next(server) == 11
      assert NonceServer.get_next(server) == 12
      assert NonceServer.peek(server) == 13
    end

    test "is atomic under heavy concurrent load (100 callers, 0 duplicates)" do
      server = start()

      results =
        1..100
        |> Task.async_stream(fn _ -> NonceServer.get_next(server) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, n} -> n end)
        |> Enum.sort()

      # Every value 0..99 must appear exactly once.
      assert results == Enum.to_list(0..99)
      assert NonceServer.peek(server) == 100
    end
  end

  describe "peek/1" do
    test "does not increment" do
      server = start(initial_nonce: 5)
      assert NonceServer.peek(server) == 5
      assert NonceServer.peek(server) == 5
      assert NonceServer.peek(server) == 5
      assert NonceServer.get_next(server) == 5
    end
  end

  describe "reset/2" do
    test "forces the next nonce" do
      server = start()
      assert NonceServer.get_next(server) == 0
      assert NonceServer.get_next(server) == 1
      :ok = NonceServer.reset(server, 100)
      assert NonceServer.peek(server) == 100
      assert NonceServer.get_next(server) == 100
      assert NonceServer.get_next(server) == 101
    end

    test "can reset backward (e.g. after a failed transaction)" do
      server = start(initial_nonce: 50)
      assert NonceServer.get_next(server) == 50
      :ok = NonceServer.reset(server, 50)
      assert NonceServer.get_next(server) == 50
    end
  end

  describe "atomic seeding" do
    test "get_next_if_seeded reports unseeded until seeded, then hands out nonces" do
      server = start()
      assert NonceServer.get_next_if_seeded(server) == :unseeded
      assert NonceServer.seed_and_next(server, 7) == 7
      assert NonceServer.get_next_if_seeded(server) == {:ok, 8}
      assert NonceServer.get_next_if_seeded(server) == {:ok, 9}
    end

    test "an explicit initial_nonce marks the server seeded" do
      server = start(initial_nonce: 3)
      assert NonceServer.get_next_if_seeded(server) == {:ok, 3}
    end

    test "reset marks an unseeded server seeded" do
      server = start()
      assert NonceServer.get_next_if_seeded(server) == :unseeded
      :ok = NonceServer.reset(server, 20)
      assert NonceServer.get_next_if_seeded(server) == {:ok, 20}
    end

    test "resync marks a seeded server unseeded so the next use re-fetches" do
      server = start(initial_nonce: 9)
      assert NonceServer.get_next_if_seeded(server) == {:ok, 9}
      :ok = NonceServer.resync(server)
      assert NonceServer.get_next_if_seeded(server) == :unseeded
      # Re-seed from a (new) chain value and carry on.
      assert NonceServer.seed_and_next(server, 30) == 30
      assert NonceServer.get_next_if_seeded(server) == {:ok, 31}
    end

    test "seed_and_next hands out unique nonces even when callers race on seeding" do
      server = start()
      chain_nonce = 5

      results =
        1..100
        |> Task.async_stream(
          fn _ ->
            case NonceServer.get_next_if_seeded(server) do
              {:ok, n} -> n
              :unseeded -> NonceServer.seed_and_next(server, chain_nonce)
            end
          end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, n} -> n end)
        |> Enum.sort()

      # No two callers get the same nonce; the base is the chain nonce, so the
      # 100 assignments are exactly 5..104. A racy seed would repeat a value and
      # break this equality.
      assert length(Enum.uniq(results)) == 100
      assert results == Enum.to_list(5..104)
      assert NonceServer.peek(server) == 105
    end
  end

  describe "isolation between instances" do
    test "two instances increment independently" do
      a = start(initial_nonce: 0)
      b = start(initial_nonce: 1000)

      assert NonceServer.get_next(a) == 0
      assert NonceServer.get_next(b) == 1000
      assert NonceServer.get_next(a) == 1
      assert NonceServer.get_next(b) == 1001
    end
  end
end
