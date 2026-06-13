defmodule Raxol.ACP.Transport.MockTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Transport
  alias Raxol.ACP.Transport.Mock

  describe "connection lifecycle" do
    test "starts disconnected" do
      t = Mock.new()
      refute Mock.connected?(t)
    end

    test "connect/2 records the owner" do
      t = Mock.new()

      ctx = %{owner: self(), chain_ids: [8453], wallet_address: "0x"}
      :ok = Transport.connect(t, ctx)

      assert Mock.connected?(t)
    end

    test "disconnect/1 clears the owner" do
      t = Mock.new()

      Transport.connect(t, %{owner: self(), chain_ids: [8453], wallet_address: "0x"})
      :ok = Transport.disconnect(t)

      refute Mock.connected?(t)
    end
  end

  describe "deliver/2" do
    test "sends `{:transport, entry}` to the owner" do
      t = Mock.new()
      Transport.connect(t, %{owner: self(), chain_ids: [8453], wallet_address: "0x"})

      Mock.deliver(t, %{"kind" => "system", "event" => "job.created"})

      assert_receive {:transport, %{"kind" => "system"}}, 50
    end

    test "drops deliveries when nothing is connected" do
      t = Mock.new()
      Mock.deliver(t, %{"kind" => "message"})
      refute_receive {:transport, _}, 50
    end
  end

  describe "get_history/2" do
    test "returns set_history fixture" do
      t = Mock.new()
      key = {8453, "j1"}

      Mock.set_history(t, key, [%{"kind" => "message", "content" => "hi"}])

      assert {:ok, [%{"content" => "hi"}]} = Transport.get_history(t, key)
    end

    test "returns [] when nothing was seeded" do
      t = Mock.new()
      assert {:ok, []} = Transport.get_history(t, {8453, "missing"})
    end
  end

  describe "sent traffic" do
    test "post_message and send_message both record" do
      t = Mock.new()
      key = {8453, "j1"}

      Transport.post_message(t, key, "hello", "text")
      Transport.send_message(t, key, "stream", "text")

      assert Mock.sent(t) == [
               {:post, key, "hello", "text"},
               {:send, key, "stream", "text"}
             ]
    end
  end
end
