defmodule Raxol.Agent.ClientProtocol.PermissionTest do
  @moduledoc """
  The authorizer alone, against a process standing in for the ACP session:
  it answers `request_permission` with a chosen outcome and reports every
  call it receives. `Raxol.AgentClientProtocol.Ctx.request_permission/4`
  folds a timeout, a client error, a disconnect and a cancel into
  `{:ok, :cancelled}`, so the outcomes here are the ones it can produce,
  and one it cannot.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.Reference.Counter.Increment
  alias Raxol.Agent.Reference.Counter.Reset

  @session_id "sess-1"

  defp session(outcome) do
    test = self()
    spawn_link(fn -> session_loop(outcome, test) end)
  end

  defp session_loop(outcome, test) do
    receive do
      {:"$gen_call", from, {:request_permission, request}} ->
        send(test, {:asked, request})
        GenServer.reply(from, outcome)

      {:"$gen_call", from, {:post_update, notification}} ->
        send(test, {:posted, notification.update})
        GenServer.reply(from, :ok)
    end

    session_loop(outcome, test)
  end

  defp selected(option_id), do: {:ok, {:selected, %{option_id: option_id}}}

  defp posted do
    receive do
      {:posted, update} -> [update | posted()]
    after
      0 -> []
    end
  end

  defp statuses do
    Enum.map(posted(), fn
      {:tool_call, call} -> {:tool_call, call.tool_call_id, call.status}
      {:tool_call_update, update} -> {:update, update.tool_call_id, update.fields.status}
    end)
  end

  describe "an action that is not sensitive" do
    test "is allowed without asking, and announced in progress" do
      gate = Permission.authorizer(session(:never_asked), @session_id)

      assert gate.(Increment, %{}, %{}) == :ok
      refute_received {:asked, _request}

      assert [{:tool_call, call}] = posted()
      assert %{title: "Run `increment`", status: :in_progress} = call
    end
  end

  describe "a sensitive action" do
    test "is allowed when the client selects the allow option" do
      gate = Permission.authorizer(session(selected(Permission.allow_option_id())), @session_id)

      assert gate.(Reset, %{}, %{}) == :ok
      assert_received {:asked, request}
      assert request.session_id == @session_id

      assert Enum.map(request.options, &{&1.option_id, &1.kind}) == [
               {Permission.allow_option_id(), :allow_once},
               {Permission.reject_option_id(), :reject_once}
             ]

      id = request.tool_call.tool_call_id
      assert statuses() == [{:tool_call, id, :pending}, {:update, id, :in_progress}]
    end

    test "is denied and marked failed when the client rejects" do
      gate = Permission.authorizer(session(selected(Permission.reject_option_id())), @session_id)

      assert {:deny, {:permission_rejected, "reset"}} = gate.(Reset, %{}, %{})
      assert [{:tool_call, id, :pending}, {:update, id, :failed}] = statuses()
    end

    test "is denied when the ask ends without a selection" do
      gate = Permission.authorizer(session({:ok, :cancelled}), @session_id)

      assert {:deny, {:permission_cancelled, "reset"}} = gate.(Reset, %{}, %{})
    end

    test "is denied when the client selects an option that was not offered" do
      gate = Permission.authorizer(session(selected("not-offered")), @session_id)

      assert {:deny, {:permission_unknown_option, "reset", "not-offered"}} =
               gate.(Reset, %{}, %{})
    end

    test "is denied on an answer of any other shape" do
      gate = Permission.authorizer(session(:something_else), @session_id)

      assert {:deny, {:permission_unexpected, "reset", :something_else}} =
               gate.(Reset, %{}, %{})
    end

    test "gets a tool call id of its own on every call" do
      gate = Permission.authorizer(session(selected(Permission.allow_option_id())), @session_id)

      gate.(Reset, %{}, %{})
      gate.(Reset, %{}, %{})

      assert_received {:asked, first}
      assert_received {:asked, second}
      assert first.tool_call.tool_call_id != second.tool_call.tool_call_id
    end
  end

  describe "settle/3" do
    test "closes the calls the authorizer allowed, and only those" do
      stub = session(selected(Permission.reject_option_id()))
      gate = Permission.authorizer(stub, @session_id)

      assert gate.(Increment, %{}, %{}) == :ok
      assert {:deny, _reason} = gate.(Reset, %{}, %{})
      [{:tool_call, allowed, :in_progress} | _denied] = statuses()

      assert Permission.settle(stub, @session_id, :completed) == :ok
      assert statuses() == [{:update, allowed, :completed}]

      assert Permission.settle(stub, @session_id, :failed) == :ok
      assert statuses() == []
    end

    test "tells the process that built the authorizer, whichever process runs it" do
      stub = session(:never_asked)
      gate = Permission.authorizer(stub, @session_id)

      worker = Task.async(fn -> gate.(Increment, %{}, %{}) end)
      assert Task.await(worker) == :ok
      [{:tool_call, id, :in_progress}] = statuses()

      assert Permission.settle(stub, @session_id, :failed) == :ok
      assert statuses() == [{:update, id, :failed}]
    end
  end
end
