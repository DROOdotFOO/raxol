defmodule Raxol.Agent.CommandTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Command

  describe "decode/1 — loud typed rejects" do
    test "malformed JSON string is a typed error, no crash" do
      assert {:error, {:invalid_command, {:malformed_json, _}}} =
               Command.decode("{not json")
    end

    test "valid JSON that isn't an object is rejected" do
      assert {:error, {:invalid_command, :not_a_map}} =
               Command.decode("[1, 2, 3]")

      assert {:error, {:invalid_command, :not_a_map}} =
               Command.decode(~s("just a string"))
    end

    test "a non-map, non-binary term is rejected" do
      assert {:error, {:invalid_command, :not_a_command}} = Command.decode(42)
      assert {:error, {:invalid_command, :not_a_command}} = Command.decode(nil)
    end

    test "missing type is rejected" do
      assert {:error, {:invalid_command, :missing_type}} =
               Command.decode(%{"payload" => %{"text" => "hi"}})
    end

    test "unknown type is rejected" do
      assert {:error, {:invalid_command, {:unknown_type, "explode"}}} =
               Command.decode(%{"type" => "explode"})
    end

    test "prompt with missing text is rejected" do
      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(%{"type" => "prompt", "payload" => %{}})

      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(~s({"type":"prompt"}))
    end

    test "prompt with empty/whitespace text is rejected" do
      assert {:error, {:invalid_command, :empty_text}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => "   "}
               })
    end

    test "prompt with non-binary text is rejected" do
      assert {:error, {:invalid_command, :invalid_text}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => 123}
               })
    end

    test "decode never raises on arbitrary bad input" do
      for bad <- ["", "{", "null", "true", %{}, %{"type" => 1}, [], {:a, :b}] do
        assert {:error, {:invalid_command, _}} = Command.decode(bad)
      end
    end
  end

  describe "decode/1 — prompt" do
    test "valid prompt JSON decodes to a typed struct" do
      assert {:ok, %Command{type: :prompt, payload: %{text: "hello world"}}} =
               Command.decode(
                 ~s({"type":"prompt","payload":{"text":"hello world"}})
               )
    end

    test "accepts a plain map with atom keys" do
      assert {:ok, %Command{type: :prompt, payload: %{text: "hi"}}} =
               Command.decode(%{type: :prompt, payload: %{text: "hi"}})
    end

    test "carries optional attachments" do
      assert {:ok, %Command{type: :prompt, payload: payload}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => "hi", "attachments" => ["a.txt"]}
               })

      assert payload == %{text: "hi", attachments: ["a.txt"]}
    end
  end

  describe "decode/1 — interrupt" do
    test "interrupt with empty payload decodes" do
      assert {:ok, %Command{type: :interrupt, payload: %{}}} =
               Command.decode(~s({"type":"interrupt","payload":{}}))
    end

    test "interrupt without a payload key decodes" do
      assert {:ok, %Command{type: :interrupt, payload: %{}}} =
               Command.decode(%{"type" => "interrupt"})
    end

    test "interrupt carries an optional turn_id" do
      assert {:ok, %Command{type: :interrupt, payload: %{turn_id: "turn-7"}}} =
               Command.decode(%{
                 "type" => "interrupt",
                 "payload" => %{"turn_id" => "turn-7"}
               })
    end
  end

  describe "decode/1 — steer" do
    test "valid steer JSON decodes to a typed struct" do
      assert {:ok,
              %Command{
                type: :steer,
                payload: %{text: "go left instead", expected_turn_id: "turn-1"}
              }} =
               Command.decode(
                 ~s({"type":"steer","payload":{"text":"go left instead","expected_turn_id":"turn-1"}})
               )
    end

    test "accepts a plain map with atom keys" do
      assert {:ok,
              %Command{
                type: :steer,
                payload: %{text: "hi", expected_turn_id: "turn-9"}
              }} =
               Command.decode(%{
                 type: :steer,
                 payload: %{text: "hi", expected_turn_id: "turn-9"}
               })
    end

    test "missing text is rejected" do
      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"expected_turn_id" => "turn-1"}
               })
    end

    test "empty/whitespace text is rejected" do
      assert {:error, {:invalid_command, :empty_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "   ", "expected_turn_id" => "turn-1"}
               })
    end

    test "non-binary text is rejected" do
      assert {:error, {:invalid_command, :invalid_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => 123, "expected_turn_id" => "turn-1"}
               })
    end

    test "missing expected_turn_id is rejected" do
      assert {:error, {:invalid_command, :missing_expected_turn_id}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi"}
               })
    end

    test "an explicit nil expected_turn_id is rejected the same as missing" do
      assert {:error, {:invalid_command, :missing_expected_turn_id}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi", "expected_turn_id" => nil}
               })
    end

    test "carries an optional client_msg_id when present" do
      assert {:ok, %Command{type: :steer, payload: payload}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{
                   "text" => "hi",
                   "expected_turn_id" => "turn-1",
                   "client_msg_id" => "msg-42"
                 }
               })

      assert payload == %{
               text: "hi",
               expected_turn_id: "turn-1",
               client_msg_id: "msg-42"
             }
    end

    test "omits client_msg_id from the payload when absent" do
      assert {:ok, %Command{type: :steer, payload: payload}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi", "expected_turn_id" => "turn-1"}
               })

      refute Map.has_key?(payload, :client_msg_id)
    end
  end

  describe "decode/1 — attach / seek (decode fully, route stubbed)" do
    test "attach decodes to a valid struct with defaulted history_policy" do
      assert {:ok,
              %Command{
                type: :attach,
                payload: %{from_offset: 12, history_policy: :replay}
              }} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => 12}
               })
    end

    test "attach validates history_policy against the whitelist" do
      assert {:ok, %Command{payload: %{history_policy: :live}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => 0, "history_policy" => "live"}
               })

      assert {:error, {:invalid_command, {:unknown_history_policy, "teleport"}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{
                   "from_offset" => 0,
                   "history_policy" => "teleport"
                 }
               })
    end

    test "attach with a missing/invalid offset is rejected" do
      assert {:error, {:invalid_command, {:missing_offset, :from_offset}}} =
               Command.decode(%{"type" => "attach", "payload" => %{}})

      assert {:error, {:invalid_command, {:invalid_offset, :from_offset}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => -1}
               })
    end

    test "seek decodes to a valid struct" do
      assert {:ok, %Command{type: :seek, payload: %{offset: 99}}} =
               Command.decode(%{
                 "type" => "seek",
                 "payload" => %{"offset" => 99}
               })
    end

    test "seek with a missing offset is rejected" do
      assert {:error, {:invalid_command, {:missing_offset, :offset}}} =
               Command.decode(%{"type" => "seek", "payload" => %{}})
    end
  end

  describe "route/2" do
    test "prompt returns the documented start-turn action" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      assert {:start_turn, "sess-1", %{text: "go"}} =
               Command.route(cmd, %{session_id: "sess-1"})
    end

    test "prompt dispatches the action to a live session pid" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action == {:start_turn, "sess-1", %{text: "go"}}
      assert_receive {:harness_command, {:start_turn, "sess-1", %{text: "go"}}}
    end

    test "prompt accepts a bare session_id binary" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      assert {:start_turn, "bare-id", %{text: "go"}} =
               Command.route(cmd, "bare-id")
    end

    test "interrupt routes to its supervised-kill seam" do
      {:ok, cmd} =
        Command.decode(%{
          "type" => "interrupt",
          "payload" => %{"turn_id" => "turn-3"}
        })

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action == {:interrupt, "sess-1", %{turn_id: "turn-3"}}

      assert_receive {:harness_command,
                      {:interrupt, "sess-1", %{turn_id: "turn-3"}}}
    end

    test "steer routes to the session as {:harness_command, {:steer, ...}}" do
      {:ok, cmd} =
        Command.decode(%{
          "type" => "steer",
          "payload" => %{
            "text" => "go left instead",
            "expected_turn_id" => "turn-1"
          }
        })

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action ==
               {:steer, "sess-1",
                %{text: "go left instead", expected_turn_id: "turn-1"}}

      assert_receive {:harness_command,
                      {:steer, "sess-1",
                       %{text: "go left instead", expected_turn_id: "turn-1"}}}
    end

    test "attach routes to not_implemented" do
      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0}
        })

      assert {:error, :not_implemented} =
               Command.route(cmd, %{session_id: "sess-1", pid: self()})

      refute_receive {:harness_command, _}
    end

    test "seek routes to not_implemented" do
      {:ok, cmd} =
        Command.decode(%{"type" => "seek", "payload" => %{"offset" => 5}})

      assert {:error, :not_implemented} =
               Command.route(cmd, %{session_id: "sess-1"})
    end
  end

  describe "decode/1 |> route/2 — end to end" do
    test "a wire prompt line drives a start turn" do
      assert {:ok, cmd} =
               Command.decode(~s({"type":"prompt","payload":{"text":"hi"}}))

      assert {:start_turn, "s", %{text: "hi"}} =
               Command.route(cmd, %{session_id: "s"})
    end
  end
end
