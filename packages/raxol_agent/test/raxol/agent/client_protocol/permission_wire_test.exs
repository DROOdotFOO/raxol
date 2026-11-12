defmodule Raxol.Agent.ClientProtocol.PermissionWireTest do
  @moduledoc """
  A sensitive action in a live turn, over a connection to the real server
  loop: the reference agent's `reset` reaches the client as one
  `session/request_permission`, and the client's answer decides whether the
  count changes.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.Test.AcpPipe

  @counter "Raxol.Agent.Reference.Counter"

  setup do
    AcpPipe.start_trees()

    root = Path.join(System.tmp_dir!(), "acp_perm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, id: "p#{System.unique_integer([:positive])}"}
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
end
