defmodule Raxol.Agent.ClientProtocol.ServeTest do
  @moduledoc """
  `raxol acp`'s arguments and the life of its server loop: the exit code a
  connection's end maps to, what becomes of the agents it started, and the
  connection's turn cap.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.BenchmarkProfile
  alias Raxol.Agent.ClientProtocol.Budget
  alias Raxol.Agent.ClientProtocol.Serve
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Session
  alias Raxol.Agent.Test.AcpPipe

  @counter "Raxol.Agent.Reference.Counter"

  describe "run/1" do
    test "--help prints the usage and exits 0" do
      assert capture_io(fn -> assert Serve.run(["--help"]) == 0 end) =~
               "Usage: raxol acp [--agent <app>[:<id>]]"
    end

    test "unknown arguments exit 64 with the usage on stderr" do
      for argv <- [["--backend", "mock"], ["--nope"], ["stray"]] do
        stderr = capture_io(:stderr, fn -> assert Serve.run(argv) == 64 end)
        assert stderr =~ "raxol acp: unknown arguments"
        assert stderr =~ "Usage: raxol acp"
      end
    end

    test "a malformed --agent exits 64" do
      for spec <- ["", ":c1", "Raxol.Agent.Reference.Counter:"] do
        stderr = capture_io(:stderr, fn -> assert Serve.run(["--agent", spec]) == 64 end)
        assert stderr =~ "--agent takes <app> or <app>:<id>"
      end
    end
  end

  describe "parse_agent/1" do
    test "reads an app, and an id after the first colon" do
      assert Serve.parse_agent(nil) == {:ok, nil}
      assert Serve.parse_agent(@counter) == {:ok, %{app: @counter, id: nil}}
      assert Serve.parse_agent(@counter <> ":c1") == {:ok, %{app: @counter, id: "c1"}}
      assert Serve.parse_agent("App:a:b") == {:ok, %{app: "App", id: "a:b"}}
    end
  end

  describe "serve_connection/2" do
    setup do
      AcpPipe.start_trees()
      %{root: AcpPipe.tmp_root("acp_serve"), id: "s#{uniq()}"}
    end

    test "a peer disconnect ends serving with exit code 0" do
      pipe = AcpPipe.connect(nil)

      assert AcpPipe.disconnect(pipe) == 0
    end

    test "an abnormal connection exit ends serving with exit code 1" do
      pipe = AcpPipe.connect(nil)

      assert kill_connection(pipe) =~ "connection ended abnormally"
    end

    test "the connection's end stops its agents and frees their ids", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)
      {_updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "increment")

      assert AcpPipe.disconnect(pipe) == 0

      assert Session.Supervisor.whereis(id) == nil
      assert Session.Supervisor.owner(id) == :error
      assert Registry.lookup(Raxol.Agent.Registry, id) == []
      assert {:ok, records} = FileStore.read_records(id, base_dir: base)
      assert "turn_completed" in Enum.map(records, & &1["type"])
    end

    test "serving the id again continues its journal with fresh state", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)
      {_updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "increment")
      {updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "increment")
      assert AcpPipe.reply_text(updates) == "count: 2"
      assert AcpPipe.disconnect(pipe) == 0
      {:ok, before} = FileStore.read_records(id, base_dir: base)

      again = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(again, root)

      {updates, {:ok, _response}} = AcpPipe.turn(again, id, "increment")
      assert AcpPipe.reply_text(updates) == "count: 1"
      assert AcpPipe.disconnect(again) == 0

      {:ok, records} = FileStore.read_records(id, base_dir: base)
      assert Enum.take(records, length(before)) == before
      marker = Enum.at(records, length(before))
      assert %{"type" => "agent_started", "payload" => %{"prior_offset" => prior}} = marker
      assert prior == length(before)
    end

    test "a turn in flight when the connection dies is journaled as cancelled",
         %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)

      tag = AcpPipe.prompt(pipe, id, "hold")
      assert_receive {:acp_turn_update, ^tag, 0, %{update: {:tool_call, _call}}}, 5_000

      kill_connection(pipe)

      assert Session.Supervisor.whereis(id) == nil
      {:ok, records} = FileStore.read_records(id, base_dir: base)
      closing = Enum.find(records, &match?(%{"type" => "turn_canceled"}, &1))
      assert %{"turn_id" => "acp-" <> _, "payload" => %{"reason" => "caller_down"}} = closing
    end

    test "a turn cap refuses the prompt after the one that reached it", %{root: root, id: id} do
      {:ok, profile} = BenchmarkProfile.from_env(%{"RAXOL_MAX_TURNS" => "1"})
      start_supervised!({Budget, profile})

      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)

      assert {_updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "increment")

      assert {[], {:error, error}} = AcpPipe.turn(pipe, id, "increment")
      assert error.code == -32_603
      assert %{"tag" => "budget_exhausted", "reason" => ":max_turns"} = error.data

      assert Budget.spent().turns == 1
    end
  end

  # Kills the server's Connection, which owns its end of the pair once it
  # has answered `initialize`. Returns what the loop wrote to stderr on its
  # way to exit code 1.
  defp kill_connection(%{serving: serving, server: server}) do
    %{owner: connection} = :sys.get_state(server.pid)

    capture_io(:stderr, fn ->
      Process.exit(connection, :kill)
      assert_receive {:acp_exit, ^serving, 1}, 5_000
    end)
  end

  defp uniq, do: System.unique_integer([:positive])
end
