defmodule Raxol.Agent.CommTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.{Comm, Session}

  defmodule EchoAgent do
    use Raxol.Agent

    def init(_context), do: %{inbox: []}

    def update({:agent_message, from, {:call, caller, ref, question}}, model) do
      Comm.reply(caller, ref, {:echo, question})
      {%{model | inbox: [{from, {:call_received, question}} | model.inbox]}, []}
    end

    def update({:agent_message, from, payload}, model) do
      {%{model | inbox: [{from, payload} | model.inbox]}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    case Raxol.Core.UserPreferences.start_link(name: Raxol.Core.UserPreferences) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    case DynamicSupervisor.start_link(
           name: Raxol.DynamicSupervisor,
           strategy: :one_for_one
         ) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp await_inbox(id, n) do
    Enum.reduce_while(1..100, nil, fn _, acc ->
      case Session.get_model(id) do
        {:ok, model} when length(model.inbox) >= n ->
          {:halt, model}

        {:ok, model} ->
          Process.sleep(20)
          {:cont, model}

        _ ->
          Process.sleep(20)
          {:cont, acc}
      end
    end)
  end

  describe "send/3" do
    test "with from: the receiver sees the sender's id" do
      {:ok, _} =
        Session.start_link(app_module: EchoAgent, id: :comm_attr_target)

      :ok = Comm.send(:comm_attr_target, :ping, from: :comm_attr_sender)

      model = await_inbox(:comm_attr_target, 1)
      assert [{:comm_attr_sender, :ping}] = model.inbox
    end

    test "without from: the sender position is nil, not the receiver's id" do
      {:ok, _} =
        Session.start_link(app_module: EchoAgent, id: :comm_anon_target)

      :ok = Comm.send(:comm_anon_target, :ping)

      model = await_inbox(:comm_anon_target, 1)
      assert [{nil, :ping}] = model.inbox
    end

    test "to an unknown agent returns not_found" do
      assert {:error, :not_found} = Comm.send(:comm_nobody, :ping)
    end
  end

  describe "call/3 + reply/3" do
    test "round-trips through the target's update/2" do
      {:ok, _} =
        Session.start_link(app_module: EchoAgent, id: :comm_call_target)

      assert {:ok, {:echo, :question}} =
               Comm.call(:comm_call_target, :question, 2_000)
    end

    test "to an unknown agent returns not_found" do
      assert {:error, :not_found} = Comm.call(:comm_call_nobody, :question, 100)
    end
  end

  describe "broadcast_team/2" do
    test "reaches only sessions with a matching team_id" do
      {:ok, _} =
        Session.start_link(
          app_module: EchoAgent,
          id: :comm_bt_a1,
          team_id: :alpha
        )

      {:ok, _} =
        Session.start_link(
          app_module: EchoAgent,
          id: :comm_bt_a2,
          team_id: :alpha
        )

      {:ok, _} =
        Session.start_link(
          app_module: EchoAgent,
          id: :comm_bt_b1,
          team_id: :beta
        )

      :ok = Comm.broadcast_team(:alpha, :standup)

      a1 = await_inbox(:comm_bt_a1, 1)
      a2 = await_inbox(:comm_bt_a2, 1)
      assert [{nil, {:team_broadcast, :alpha, :standup}}] = a1.inbox
      assert [{nil, {:team_broadcast, :alpha, :standup}}] = a2.inbox

      # The beta session must NOT receive the alpha broadcast. Give the
      # cast time to have been (mis)delivered before asserting absence.
      Process.sleep(150)
      {:ok, b1} = Session.get_model(:comm_bt_b1)
      assert b1.inbox == []
    end
  end
end
