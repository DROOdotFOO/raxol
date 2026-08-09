defmodule Raxol.Agent.ClientProtocol.TurnErrorTest do
  @moduledoc """
  A failed turn must SAY what failed.

  The reason used to be dropped twice over: `TurnRunner` returned an opaque
  `{:turn_stream_error, reason}` tuple, the Session folded any unrecognized
  root result to a bare `Error.internal_error()`, and nothing logged it. A
  provider answering "your credit balance is too low" reached an editor as
  -32603 with no data, and a benchmark harness as a non-zero exit with an empty
  stderr -- the only way to read it was to drive the agent stream by hand,
  which is exactly how it was eventually found.

  Both audiences are covered here because they are served by different
  mechanisms: the peer by the error's `data`, the operator by the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Agent.ClientProtocol.TurnRunner
  alias Raxol.AgentClientProtocol.Error

  @moduletag :unix_only

  @provider_failure {:http_error, 400, %{"error" => %{"message" => "credit balance too low"}}}

  describe "a failed turn" do
    test "carries the reason to the peer as JSON-RPC error data" do
      err = TurnRunner.turn_error(:turn_stream_error, @provider_failure)

      assert %Error{code: -32_603} = err
      assert err.data["tag"] == "turn_stream_error"
      assert err.data["reason"] =~ "credit balance too low"
    end

    test "distinguishes a stream error from a crashed pump" do
      crashed = TurnRunner.turn_error(:turn_stream_crashed, :killed)

      assert crashed.data["tag"] == "turn_stream_crashed"
    end

    test "is logged, so an operator and a harness both see it" do
      log =
        capture_log(fn ->
          TurnRunner.turn_error(:turn_stream_error, @provider_failure)
        end)

      assert log =~ "turn_stream_error"
      assert log =~ "credit balance too low"
    end

    # An enormous reason must not become an enormous frame.
    test "a runaway reason is truncated" do
      err = TurnRunner.turn_error(:turn_stream_error, String.duplicate("x", 10_000))

      assert byte_size(err.data["reason"]) <= 2_000
    end

    # inspect/2 defaults elide long structures with "..."; the message we most
    # need is usually at the end of a nested provider payload.
    test "a nested reason is not elided before the message" do
      nested = {:http_error, 400, %{"error" => %{"message" => String.duplicate("a", 300)}}}

      err = TurnRunner.turn_error(:turn_stream_error, nested)

      refute err.data["reason"] =~ "..."
      assert err.data["reason"] =~ String.duplicate("a", 300)
    end
  end
end
