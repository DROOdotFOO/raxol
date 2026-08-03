defmodule Raxol.Earn.Transport.SSEParserTest do
  @moduledoc """
  Pure unit tests for the SSE frame splitter and JSON parser. These
  don't hit the network -- they verify our wire-level parsing against
  hand-crafted SSE chunks.

  The functions tested are internal to `Raxol.Earn.Transport.SSE` and
  exposed here via a small public surface for testability rather than
  by reaching into private functions.
  """
  use ExUnit.Case, async: true

  alias Raxol.Earn.Transport.SSE.Parser

  describe "split_frames/1" do
    test "single complete frame; no remainder" do
      input = "data: {\"a\":1}\n\n"
      assert {[frame], ""} = Parser.split_frames(input)
      assert frame == "data: {\"a\":1}"
    end

    test "two complete frames" do
      input = "data: 1\n\ndata: 2\n\n"
      assert {[f1, f2], ""} = Parser.split_frames(input)
      assert f1 == "data: 1"
      assert f2 == "data: 2"
    end

    test "partial frame at end is buffered" do
      input = "data: complete\n\ndata: partial"
      assert {[complete], rest} = Parser.split_frames(input)
      assert complete == "data: complete"
      assert rest == "data: partial"
    end

    test "no frames yet" do
      input = "data: still partial"
      assert {[], "data: still partial"} = Parser.split_frames(input)
    end
  end

  describe "parse_frame/1" do
    test "single-line data with JSON object" do
      assert {:ok, %{"a" => 1}} = Parser.parse_frame("data: {\"a\":1}")
    end

    test "multi-line data concatenates" do
      frame = "data: {\"a\":\ndata: 1}"
      assert {:ok, %{"a" => 1}} = Parser.parse_frame(frame)
    end

    test "handles 'data:' without a trailing space" do
      assert {:ok, %{"x" => true}} = Parser.parse_frame("data:{\"x\":true}")
    end

    test "ignores `event:` and `id:` lines" do
      frame = "event: entry\nid: 42\ndata: {\"ok\":1}"
      assert {:ok, %{"ok" => 1}} = Parser.parse_frame(frame)
    end

    test "empty data returns error" do
      assert {:error, :no_data} = Parser.parse_frame("event: heartbeat")
    end

    test "non-JSON data returns error" do
      assert {:error, :invalid_json} = Parser.parse_frame("data: not-json")
    end
  end
end
