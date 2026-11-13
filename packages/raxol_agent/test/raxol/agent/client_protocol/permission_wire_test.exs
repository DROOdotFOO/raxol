defmodule Raxol.Agent.ClientProtocol.PermissionWireTest do
  @moduledoc """
  A sensitive action in a live turn, over a connection to the real server
  loop: the reference agent's `reset` reaches the client as one
  `session/request_permission`, and the client's answer decides whether the
  count changes. `Raxol.Agent.Test.TurnProbe` supplies an action called with
  arguments, and one whose turn outlives the call.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.Comm
  alias Raxol.Agent.Session
  alias Raxol.Agent.Test.AcpPipe
  alias Raxol.Agent.Test.TurnProbe

  @counter "Raxol.Agent.Reference.Counter"
  @probe "Raxol.Agent.Test.TurnProbe"

  setup do
    AcpPipe.start_trees()
    %{root: AcpPipe.tmp_root("acp_perm"), id: "p#{System.unique_integer([:positive])}"}
  end

  defp counting(root, id, opts) do
    pipe = AcpPipe.connect(%{app: @counter, id: id}, opts)
    {:ok, ^id} = AcpPipe.new_session(pipe, root)
    {_updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "increment")
    pipe
  end

  defp count(pipe, id) do
    {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "get")
    AcpPipe.reply_text(updates)
  end

  defp paying(root, id, opts) do
    AcpPipe.spawnable([TurnProbe])
    pipe = AcpPipe.connect(%{app: @probe, id: id}, opts)
    {:ok, ^id} = AcpPipe.new_session(pipe, root)
    pipe
  end

  test "a rejected reset is denied and changes nothing", %{root: root, id: id} do
    pipe = counting(root, id, permission: Permission.reject_option_id())

    assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "reset")

    assert_received {:permission_asked, request}
    assert request.session_id == id
    assert Enum.map(request.options, & &1.kind) == [:allow_once, :reject_once]

    assert AcpPipe.tool_statuses(updates) == [{"Run `reset`", :pending}, {nil, :failed}]
    assert AcpPipe.reply_text(updates) =~ "[Tool error for reset]: denied"
    assert count(pipe, id) == "count: 1"
  end

  test "an allowed reset runs", %{root: root, id: id} do
    pipe = counting(root, id, permission: Permission.allow_option_id())

    assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "reset")
    assert_received {:permission_asked, _request}

    assert AcpPipe.tool_statuses(updates) == [
             {"Run `reset`", :pending},
             {nil, :in_progress},
             {nil, :completed}
           ]

    assert AcpPipe.reply_text(updates) == "count: 0"
    assert count(pipe, id) == "count: 0"
  end

  test "an option the client was not offered is denied", %{root: root, id: id} do
    pipe = counting(root, id, permission: "allow-everything")

    assert {updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "reset")
    assert AcpPipe.reply_text(updates) =~ "[Tool error for reset]: denied"
    assert count(pipe, id) == "count: 1"
  end

  test "a client without session/request_permission is denied", %{root: root, id: id} do
    pipe = counting(root, id, [])

    assert {updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "reset")
    assert AcpPipe.reply_text(updates) =~ "[Tool error for reset]: denied"
    assert count(pipe, id) == "count: 1"
  end

  test "an action that is not sensitive asks nothing", %{root: root, id: id} do
    pipe = counting(root, id, permission: Permission.reject_option_id())

    refute_received {:permission_asked, _request}
    assert count(pipe, id) == "count: 1"
  end

  test "the client is asked with the arguments the action is called with",
       %{root: root, id: id} do
    pipe = paying(root, id, permission: Permission.reject_option_id())

    assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "pay")

    assert_received {:permission_asked, request}
    assert %{title: "Run `pay`", raw_input: %{"amount" => 5}} = request.tool_call.fields

    assert [{:tool_call, announced} | _rest] = updates
    assert %{title: "Run `pay`", status: :pending, raw_input: %{"amount" => 5}} = announced
    assert announced.tool_call_id == request.tool_call.tool_call_id
  end

  test "an allowed call is closed with its outcome unknown when the turn is cancelled",
       %{root: root, id: id} do
    pipe = paying(root, id, permission: Permission.allow_option_id())

    tag = AcpPipe.prompt(pipe, id, "pay")
    # Answered once the agent has applied the payment the allowed call made.
    assert {:ok, 5} = Comm.call(id, "paid", 5_000)
    :ok = AcpPipe.cancel(pipe, id)

    assert {updates, {:ok, %{stop_reason: :cancelled}}} = AcpPipe.collect(tag)

    assert [{:tool_call, call}, {:tool_call_update, allowed}, {:tool_call_update, closing}] =
             updates

    assert allowed.fields.status == :in_progress
    assert closing.tool_call_id == call.tool_call_id
    assert closing.fields.status == :failed
    assert [{:content, %{content: {:text, %{text: note}}}}] = closing.fields.content
    assert note =~ "Outcome unknown"
    assert note =~ "may have run"
  end

  test "a turn that ends while the client is asked closes the call and withdraws the request",
       %{root: root, id: id} do
    pipe = AcpPipe.connect(%{app: @counter, id: id}, permission: :hold)
    {:ok, ^id} = AcpPipe.new_session(pipe, root)

    tag = AcpPipe.prompt(pipe, id, "reset")
    assert_receive {:permission_asked, request}, 5_000
    assert_receive {:permission_held, asked}, 5_000
    held = Process.monitor(asked)

    Process.exit(Session.Supervisor.whereis(id), :kill)

    assert {updates, {:error, error}} = AcpPipe.collect(tag)
    assert %{"tag" => "agent_down"} = error.data

    assert [{:tool_call, %{status: :pending}}, {:tool_call_update, closing}] = updates
    assert closing.tool_call_id == request.tool_call.tool_call_id
    assert closing.fields.status == :failed
    assert closing.fields.content == nil

    # `$/cancel_request` ends the client's handler for the request.
    assert_receive {:DOWN, ^held, :process, ^asked, :shutdown}, 5_000
    assert Process.alive?(pipe.conn)
  end
end
