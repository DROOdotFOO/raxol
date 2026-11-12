defmodule Raxol.Agent.ClientProtocol.TurnTest do
  @moduledoc """
  The ways a turn ends without an answer, over a connection to the real
  server loop: each is a JSON-RPC internal error whose `data` names what
  happened, and the same line in the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.Session
  alias Raxol.Agent.Test.AcpPipe
  alias Raxol.Agent.Test.TurnProbe

  @counter "Raxol.Agent.Reference.Counter"
  @probe "Raxol.Agent.Test.TurnProbe"

  setup do
    AcpPipe.start_trees()
    AcpPipe.spawnable([TurnProbe])
    %{root: AcpPipe.tmp_root("acp_turn"), id: "t#{System.unique_integer([:positive])}"}
  end

  defp serving(app, root, id) do
    pipe = AcpPipe.connect(%{app: app, id: id})
    {:ok, ^id} = AcpPipe.new_session(pipe, root)
    pipe
  end

  # The error a prompt is answered with, and what was logged meanwhile.
  defp failed_turn(pipe, id, text) do
    {result, log} = with_log(fn -> AcpPipe.turn(pipe, id, text) end)
    assert {[], {:error, error}} = result
    assert error.code == -32_603
    {error.data, log}
  end

  test "an atom error from the agent is turn_failed", %{root: root, id: id} do
    pipe = serving(@probe, root, id)

    assert {%{"tag" => "turn_failed", "reason" => ":boom"}, log} =
             failed_turn(pipe, id, "error-atom")

    assert log =~ "[acp] turn_failed: :boom"

    # The session takes the next prompt.
    assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "anything")
    assert AcpPipe.reply_text(updates) == "unknown"
  end

  test "an error that is not an atom is turn_reply_invalid, with the reply", %{root: root, id: id} do
    pipe = serving(@probe, root, id)

    assert {%{"tag" => "turn_reply_invalid", "reason" => ~s({:error, "x"})}, log} =
             failed_turn(pipe, id, "error-text")

    assert log =~ ~s([acp] turn_reply_invalid: {:error, "x"})
  end

  test "a reply without usage is turn_reply_invalid, with the reply", %{root: root, id: id} do
    pipe = serving(@probe, root, id)

    assert {%{"tag" => "turn_reply_invalid", "reason" => ~s({:ok, "x"})}, _log} =
             failed_turn(pipe, id, "no-usage")
  end

  test "the reason is cut at 2,000 characters", %{root: root, id: id} do
    pipe = serving(@probe, root, id)

    assert {%{"tag" => "turn_reply_invalid", "reason" => reason}, _log} =
             failed_turn(pipe, id, "long-error")

    assert String.length(reason) == 2_000
    assert String.starts_with?(reason, ~s({:error, "xxx))
  end

  test "an agent that goes down in the turn is agent_down", %{root: root, id: id} do
    pipe = serving(@counter, root, id)

    tag = AcpPipe.prompt(pipe, id, "hold")
    assert_receive {:acp_turn_update, ^tag, 0, %{update: {:tool_call, _call}}}, 5_000

    {result, log} =
      with_log(fn ->
        Process.exit(Session.Supervisor.whereis(id), :kill)
        AcpPipe.collect(tag)
      end)

    assert {[{:tool_call_update, closing}], {:error, error}} = result
    assert closing.fields.status == :failed
    assert error.code == -32_603
    assert error.data == %{"tag" => "agent_down", "reason" => inspect(id)}
    assert log =~ "[acp] agent_down: #{inspect(id)}"
  end

  test "a prompt for an agent that is not running is agent_not_running", %{root: root, id: id} do
    pipe = serving(@counter, root, id)
    :ok = Session.Supervisor.stop_session(id)
    Session.await_free(id)

    assert {%{"tag" => "agent_not_running", "reason" => reason}, _log} =
             failed_turn(pipe, id, "get")

    assert reason == inspect(id)
  end
end
