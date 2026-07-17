defmodule Raxol.AgentClientProtocol.Transport.PairedTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Transport.Paired

  setup do
    {left, right} = Paired.create_pair()
    :ok = Paired.set_owner(left, self())
    :ok = Paired.set_owner(right, self())
    %{left: left, right: right}
  end

  describe "order preservation" do
    test "1000 rapid sends arrive in order", %{left: left, right: right} do
      n = 1000

      final_left =
        Enum.reduce(1..n, left, fn i, side ->
          {:ok, side} = Paired.send_message(side, %{"seq" => i})
          side
        end)

      _ = final_left

      received =
        for _ <- 1..n do
          assert_receive {:acp_transport, ref, {:message, %{"seq" => seq}}}, 1_000
          assert ref == right.pid
          seq
        end

      assert received == Enum.to_list(1..n)
    end
  end

  describe "bidirectional simultaneous traffic" do
    test "both sides can send concurrently without interleaving corruption", %{
      left: left,
      right: right
    } do
      n = 200
      test_pid = self()

      left_task =
        Task.async(fn ->
          Enum.each(1..n, fn i ->
            {:ok, _} = Paired.send_message(left, %{"from" => "left", "seq" => i})
          end)

          send(test_pid, :left_done)
        end)

      right_task =
        Task.async(fn ->
          Enum.each(1..n, fn i ->
            {:ok, _} = Paired.send_message(right, %{"from" => "right", "seq" => i})
          end)

          send(test_pid, :right_done)
        end)

      Task.await(left_task)
      Task.await(right_task)
      assert_receive :left_done
      assert_receive :right_done

      messages =
        for _ <- 1..(2 * n) do
          assert_receive {:acp_transport, _ref, {:message, message}}, 2_000
          message
        end

      from_left = Enum.filter(messages, &(&1["from"] == "left"))
      from_right = Enum.filter(messages, &(&1["from"] == "right"))

      assert Enum.map(from_left, & &1["seq"]) == Enum.to_list(1..n)
      assert Enum.map(from_right, & &1["seq"]) == Enum.to_list(1..n)
    end
  end

  describe "close propagation" do
    test "closing left delivers {:closed, :peer_closed} to right's owner", %{
      left: left,
      right: right
    } do
      assert :ok = Paired.close(left)
      assert_receive {:acp_transport, ref, {:closed, :peer_closed}}
      assert ref == right.pid
    end

    test "closing right delivers {:closed, :peer_closed} to left's owner", %{
      left: left,
      right: right
    } do
      assert :ok = Paired.close(right)
      assert_receive {:acp_transport, ref, {:closed, :peer_closed}}
      assert ref == left.pid
    end

    test "close is idempotent", %{left: left} do
      assert :ok = Paired.close(left)
      assert :ok = Paired.close(left)
      assert :ok = Paired.close(left)
    end

    test "sending after local close returns {:error, :closed}", %{left: left} do
      assert :ok = Paired.close(left)
      assert {:error, :closed} = Paired.send_message(left, %{"hello" => "world"})
    end

    test "sending after peer close returns {:error, :closed}", %{left: left, right: right} do
      assert :ok = Paired.close(right)
      # Drain the {:closed, :peer_closed} delivered to left's owner.
      assert_receive {:acp_transport, _ref, {:closed, :peer_closed}}
      assert {:error, :closed} = Paired.send_message(left, %{"hello" => "world"})
    end

    test "closing does not message the closer's own owner", %{left: left} do
      left_pid = left.pid
      assert :ok = Paired.close(left)
      refute_receive {:acp_transport, ^left_pid, {:closed, _}}, 50
    end
  end

  describe "owner handoff" do
    test "set_owner/2 redirects future inbound delivery", %{left: left, right: right} do
      parent = self()

      {:ok, new_owner} =
        Task.start(fn ->
          receive do
            {:acp_transport, _ref, {:message, message}} ->
              send(parent, {:handed_off_message, message})
          end
        end)

      :ok = Paired.set_owner(right, new_owner)
      {:ok, _left} = Paired.send_message(left, %{"routed_to" => "new_owner"})

      assert_receive {:handed_off_message, %{"routed_to" => "new_owner"}}
      refute_receive {:acp_transport, _ref, {:message, %{"routed_to" => "new_owner"}}}, 50
    end

    test "handoff mid-stream: earlier messages went to old owner, later to new", %{
      left: left,
      right: right
    } do
      {:ok, left} = Paired.send_message(left, %{"seq" => 1})
      assert_receive {:acp_transport, _ref, {:message, %{"seq" => 1}}}

      parent = self()

      {:ok, new_owner} =
        Task.start(fn ->
          receive do
            {:acp_transport, _ref, {:message, message}} ->
              send(parent, {:new_owner_got, message})
          end
        end)

      :ok = Paired.set_owner(right, new_owner)
      {:ok, _left} = Paired.send_message(left, %{"seq" => 2})

      assert_receive {:new_owner_got, %{"seq" => 2}}
    end

    test "a handle with no owner set silently drops inbound messages", %{left: left} do
      {right_no_owner_left, _right_no_owner_right} = Paired.create_pair()
      :ok = Paired.set_owner(right_no_owner_left, self())
      # Deliberately do not set an owner on right_no_owner_right.

      {:ok, _} = Paired.send_message(right_no_owner_left, %{"a" => 1})
      refute_receive {:acp_transport, _ref, {:message, %{"a" => 1}}}, 50

      # Sanity: unrelated pair from setup still works fine.
      {:ok, _} = Paired.send_message(left, %{"b" => 2})
      assert_receive {:acp_transport, _ref, {:message, %{"b" => 2}}}
    end
  end

  describe "no message loss / exactly-once" do
    test "send N, receive exactly N, each exactly once", %{left: left, right: right} do
      n = 500

      Enum.reduce(1..n, left, fn i, side ->
        {:ok, side} = Paired.send_message(side, %{"unique" => i})
        side
      end)

      received =
        for _ <- 1..n do
          assert_receive {:acp_transport, ref, {:message, %{"unique" => i}}}, 2_000
          assert ref == right.pid
          i
        end

      refute_receive {:acp_transport, _ref, {:message, _}}, 50

      assert length(received) == n
      assert Enum.uniq(received) == received
      assert Enum.sort(received) == Enum.to_list(1..n)
    end
  end
end
