defmodule Raxol.Agent.SecurityTest do
  @moduledoc """
  Security-focused tests for the raxol_agent package.

  Covers atom exhaustion prevention, argument validation limits,
  and input sanitization across Protocol, ToolConverter, and
  SessionStreamServer.
  """

  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Protocol decode atom safety
  # ---------------------------------------------------------------------------

  describe "Protocol.decode/1 atom safety" do
    alias Raxol.Agent.Protocol

    @valid_types ~w(directive observation query response takeover release status_update alert)

    test "rejects invalid message type with descriptive error" do
      assert {:error, {:invalid_type, "bad_type"}} =
               Protocol.decode(%{
                 "from" => "agent_a",
                 "to" => "agent_b",
                 "type" => "bad_type"
               })
    end

    test "unknown from/to stay as strings (no atom creation)" do
      unique_from =
        "totally_unknown_agent_#{System.unique_integer([:positive])}"

      unique_to = "totally_unknown_target_#{System.unique_integer([:positive])}"

      {:ok, msg} =
        Protocol.decode(%{
          "from" => unique_from,
          "to" => unique_to,
          "type" => "directive"
        })

      assert msg.from == unique_from
      assert is_binary(msg.from)

      assert msg.to == unique_to
      assert is_binary(msg.to)

      assert msg.type == :directive
    end

    test "pre-existing atoms in from/to are converted" do
      # :scout and :analyst already exist in the atom table from Protocol tests
      {:ok, msg} =
        Protocol.decode(%{
          "from" => "scout",
          "to" => "analyst",
          "type" => "observation"
        })

      assert msg.from == :scout
      assert msg.to == :analyst
    end

    test "broadcast target is decoded as atom" do
      {:ok, msg} =
        Protocol.decode(%{
          "from" => "scout",
          "to" => "broadcast",
          "type" => "alert"
        })

      assert msg.to == :broadcast
    end

    test "all 8 valid types decode from their string form" do
      for type_str <- @valid_types do
        {:ok, msg} =
          Protocol.decode(%{
            "from" => "scout",
            "to" => "broadcast",
            "type" => type_str
          })

        assert msg.type == String.to_existing_atom(type_str)
      end
    end

    test "invalid format returns error" do
      assert {:error, :invalid_format} = Protocol.decode(%{"from" => "a"})
      assert {:error, :invalid_format} = Protocol.decode("not a map")
      assert {:error, :invalid_format} = Protocol.decode(42)
    end
  end

  # ---------------------------------------------------------------------------
  # ToolConverter argument validation
  # ---------------------------------------------------------------------------

  describe "ToolConverter argument limits" do
    alias Raxol.Agent.Action.ToolConverter

    defmodule EchoAction do
      @moduledoc false
      def __action_meta__, do: %{name: "echo"}
      def to_tool_definition, do: %{name: "echo"}
      def call(params, _ctx), do: {:ok, params}
    end

    @actions [EchoAction]

    test "rejects deeply nested arguments (depth > 4)" do
      deep = %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => "too deep"}}}}}
      tool_call = %{"name" => "echo", "arguments" => deep}

      assert {:error, :arguments_too_deep} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "rejects maps with too many keys (> 64)" do
      big_map = Map.new(1..65, fn i -> {"key_#{i}", "val"} end)
      tool_call = %{"name" => "echo", "arguments" => big_map}

      assert {:error, :too_many_argument_keys} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "rejects oversized string values (> 10KB)" do
      oversized = String.duplicate("x", 10_001)
      tool_call = %{"name" => "echo", "arguments" => %{"data" => oversized}}

      assert {:error, :argument_value_too_large} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "accepts valid arguments within all limits" do
      tool_call = %{"name" => "echo", "arguments" => %{"msg" => "hello"}}

      assert {:ok, params} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)

      assert params["msg"] == "hello" or params[:msg] == "hello"
    end

    test "returns unknown_tool error for nonexistent tool name" do
      tool_call = %{"name" => "does_not_exist", "arguments" => %{}}

      assert {:error, {:unknown_tool, "does_not_exist"}} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "rejects non-object JSON string arguments" do
      tool_call = %{
        "name" => "echo",
        "arguments" => ~s(["array", "not", "object"])
      }

      assert {:error, :arguments_not_object} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "depth limit is exact at boundary (depth 4 is ok, depth 5 is not)" do
      # depth 4: root -> a -> b -> c -> d (leaf is string at depth 4)
      at_limit = %{"a" => %{"b" => %{"c" => %{"d" => "ok"}}}}
      tool_call = %{"name" => "echo", "arguments" => at_limit}

      assert {:ok, _} = ToolConverter.dispatch_tool_call(tool_call, @actions)
    end

    test "key count is cumulative across nesting levels" do
      # 33 keys at root + 33 keys nested = 66 total > 64
      outer = Map.new(1..33, fn i -> {"outer_#{i}", "v"} end)
      inner = Map.new(1..33, fn i -> {"inner_#{i}", "v"} end)
      combined = Map.put(outer, "nested", inner)

      tool_call = %{"name" => "echo", "arguments" => combined}

      assert {:error, :too_many_argument_keys} =
               ToolConverter.dispatch_tool_call(tool_call, @actions)
    end
  end

  # ---------------------------------------------------------------------------
  # SessionStreamServer parse_session_id safety
  # ---------------------------------------------------------------------------

  describe "SessionStreamServer parse_session_id" do
    import Plug.Test

    alias Raxol.Agent.SessionStreamServer
    alias Raxol.Agent.SessionStreamer

    setup do
      {:ok, streamer} = SessionStreamer.start_link(name: nil, max_history: 50)
      %{streamer: streamer}
    end

    defp call_server(conn, streamer) do
      conn
      |> Plug.Conn.put_private(:streamer, streamer)
      |> Plug.Conn.put_private(:session_stream_require_auth, false)
      |> SessionStreamServer.call(SessionStreamServer.init([]))
    end

    test "numeric session id is parsed as integer", %{streamer: streamer} do
      SessionStreamer.subscribe(999, streamer)
      SessionStreamer.emit(999, {:text_delta, "hello"}, streamer)
      Process.sleep(20)

      conn = conn(:get, "/sessions/999/history") |> call_server(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"] == "999"
      assert length(body["events"]) == 1
    end

    test "non-numeric session id stays as string", %{streamer: streamer} do
      SessionStreamer.subscribe("my_agent", streamer)
      SessionStreamer.emit("my_agent", {:text_delta, "hi"}, streamer)
      Process.sleep(20)

      conn = conn(:get, "/sessions/my_agent/history") |> call_server(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["session_id"] == "my_agent"
      assert length(body["events"]) == 1
    end

    test "session id with mixed chars stays as string", %{streamer: streamer} do
      conn = conn(:get, "/sessions/agent-42x/history") |> call_server(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # "agent-42x" cannot parse to integer, stays as string
      assert body["session_id"] == "agent-42x"
    end
  end
end
