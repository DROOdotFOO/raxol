defmodule Raxol.Agent.ClientProtocol.PermissionTest do
  @moduledoc """
  The gate that lets the ACP surface hold WRITE tools at all.

  The surface used to be narrowed to read/grep/glob because there was no
  approval channel. Now the toolset is full and this gate is the only thing
  standing between a model's `write_file` and the filesystem, so the cases that
  matter are the refusals: what happens when the client says no, says nothing,
  says something we never offered, or cannot answer at all.

  `Raxol.AgentClientProtocol.Ctx.request_permission/4` collapses timeout /
  error / disconnect / cancel into `{:ok, :cancelled}` before we see it, so the
  Session is stubbed here to return the shapes Ctx can actually produce, plus
  the one shape it promises never to (asserting we still deny rather than
  crash).
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Actions.Fs

  @session_id "sess-1"

  # A stub Session: answers {:request_permission, req} with a canned outcome and
  # forwards the request so a test can inspect what was actually offered.
  defp stub_session(outcome, report_to \\ nil) do
    test = report_to || self()

    spawn_link(fn -> stub_loop(outcome, test) end)
  end

  defp stub_loop(outcome, test) do
    receive do
      {:"$gen_call", from, {:request_permission, req}} ->
        send(test, {:asked, req})
        GenServer.reply(from, outcome)
        stub_loop(outcome, test)
    end
  end

  describe "non-sensitive tools" do
    test "are allowed without any round trip" do
      # A session that would CRASH if called proves no ask happened.
      gate = Permission.authorizer(:no_such_session, @session_id)

      for action <- [Fs.ReadFile, Fs.ListDir, Fs.FileStat, Code.Grep, Code.Glob] do
        assert gate.(action, %{}, %{}) == :ok
      end
    end
  end

  describe "sensitive tools" do
    test "write_file is allowed when the client selects the allow option" do
      session =
        stub_session({:ok, {:selected, %{option_id: Permission.allow_option_id()}}})

      gate = Permission.authorizer(session, @session_id)

      assert gate.(Code.Write, %{}, %{}) == :ok
      assert_receive {:asked, _req}
    end

    test "edit_file and bash are gated too, not just write_file" do
      session =
        stub_session({:ok, {:selected, %{option_id: Permission.allow_option_id()}}})

      gate = Permission.authorizer(session, @session_id)

      for action <- [Code.Edit, Code.Bash] do
        assert gate.(action, %{}, %{}) == :ok
        assert_receive {:asked, _}
      end
    end

    test "the ask offers exactly one allow-once and one reject-once option" do
      session =
        stub_session({:ok, {:selected, %{option_id: Permission.allow_option_id()}}})

      gate = Permission.authorizer(session, @session_id)
      gate.(Code.Write, %{}, %{})

      assert_receive {:asked, req}
      assert req.session_id == @session_id

      kinds = Enum.map(req.options, & &1.kind)
      assert kinds == [:allow_once, :reject_once]

      ids = Enum.map(req.options, & &1.option_id)
      assert ids == [Permission.allow_option_id(), Permission.reject_option_id()]
    end
  end

  describe "refusals" do
    test "an explicit reject denies" do
      session =
        stub_session({:ok, {:selected, %{option_id: Permission.reject_option_id()}}})

      gate = Permission.authorizer(session, @session_id)

      assert {:deny, {:permission_rejected, _}} = gate.(Code.Write, %{}, %{})
    end

    # This is the case Ctx collapses timeout / client error / decode failure /
    # disconnect / racing-cancel into. All of them arrive here.
    test "a cancelled outcome denies" do
      session = stub_session({:ok, :cancelled})
      gate = Permission.authorizer(session, @session_id)

      assert {:deny, {:permission_cancelled, _}} = gate.(Code.Write, %{}, %{})
    end

    # A client that echoes an optionId we never offered must not get a write.
    test "an option we never offered denies rather than allowing" do
      session = stub_session({:ok, {:selected, %{option_id: "attacker-chosen"}}})
      gate = Permission.authorizer(session, @session_id)

      assert {:deny, {:permission_unknown_option, _, "attacker-chosen"}} =
               gate.(Code.Write, %{}, %{})
    end

    test "a shape Ctx promises never to return still denies instead of crashing" do
      session = stub_session(:something_else_entirely)
      gate = Permission.authorizer(session, @session_id)

      assert {:deny, {:permission_unexpected, _, _}} = gate.(Code.Write, %{}, %{})
    end
  end

  describe "TurnRunner injection" do
    alias Raxol.Agent.ClientProtocol.TurnRunner

    test "the gate lands in the agent context as :tool_authorizer" do
      opts = TurnRunner.with_permission_gate([], self(), @session_id)

      assert is_function(opts[:context][:tool_authorizer], 3)
    end

    test "an existing authorizer is NOT replaced" do
      mine = fn _a, _p, _c -> {:deny, :mine} end

      opts =
        TurnRunner.with_permission_gate([context: %{tool_authorizer: mine}], self(), @session_id)

      assert opts[:context][:tool_authorizer] == mine
    end

    # cwd and jail markers ride in the same map; clobbering them would silently
    # unroot the fs tools.
    test "other context keys survive injection" do
      opts =
        TurnRunner.with_permission_gate(
          [context: %{cwd: "/w", jail: true}],
          self(),
          @session_id
        )

      assert opts[:context][:cwd] == "/w"
      assert opts[:context][:jail] == true
      assert is_function(opts[:context][:tool_authorizer], 3)
    end
  end
end
