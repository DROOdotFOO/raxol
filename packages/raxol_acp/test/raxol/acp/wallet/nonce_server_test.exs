defmodule Raxol.ACP.Wallet.NonceServerTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Wallet.NonceServer

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
