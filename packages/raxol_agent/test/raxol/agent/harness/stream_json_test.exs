defmodule Raxol.Agent.Harness.StreamJsonTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Harness.StreamJson

  describe "parse_line/1" do
    test "extracts text blocks from assistant messages" do
      line = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}})
      assert StreamJson.parse_line(line) == [{:text, "hi"}]
    end

    test "extracts thinking blocks as reasoning" do
      line = ~s({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}})
      assert StreamJson.parse_line(line) == [{:reasoning, "hmm"}]
    end

    test "extracts tool_use blocks as tool calls" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","name":"do_it","id":"t1","input":{"x":1}}]}})

      assert [{:tool_call, %{name: "do_it", id: "t1", input: %{"x" => 1}}}] =
               StreamJson.parse_line(line)
    end

    test "handles multiple blocks in order" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}})

      assert StreamJson.parse_line(line) == [{:text, "a"}, {:text, "b"}]
    end

    test "a success result becomes a done event with content and usage" do
      line =
        ~s({"type":"result","subtype":"success","result":"final","usage":{"input_tokens":5}})

      assert [{:done, %{content: "final", usage: %{"input_tokens" => 5}}}] =
               StreamJson.parse_line(line)
    end

    test "an error result becomes an error event" do
      line = ~s({"type":"result","subtype":"error_max_turns","result":"too long"})

      assert [{:error, {:result_error, "error_max_turns", "too long"}}] =
               StreamJson.parse_line(line)
    end

    test "system and user lines are ignored" do
      assert StreamJson.parse_line(~s({"type":"system","subtype":"init"})) == []
      assert StreamJson.parse_line(~s({"type":"user","message":{"content":[]}})) == []
    end

    test "non-JSON lines parse to nothing" do
      assert StreamJson.parse_line("warning: something") == []
      assert StreamJson.parse_line("") == []
    end
  end
end
