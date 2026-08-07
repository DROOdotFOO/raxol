defmodule Raxol.AgentClientProtocol.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Transport.Stdio

  # These tests exercise :spawn mode against tiny, portable peer commands
  # (`cat`, `printf`, `true`, `false`) that exist on any Unix CI runner.
  # `:self` mode (owning the BEAM's own fd 0/1) is intentionally NOT
  # exercised here: opening the real stdin/stdout during a test run would
  # fight ExUnit's own IO capture over `:user` and is genuinely
  # sandbox-unrunnable — it belongs in a release/escript entry point, not
  # a unit test.

  describe "round trip through cat (framer + decode)" do
    test "a sent message is echoed back and decodes to the same map" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())

      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{"x" => 1}}
      {:ok, transport} = Stdio.send_message(transport, msg)

      assert_receive {:acp_transport, ref, {:message, ^msg}}, 2_000
      assert ref == transport.pid

      :ok = Stdio.close(transport)
    end

    test "rapid sends round-trip in send order" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())
      n = 50

      final =
        Enum.reduce(1..n, transport, fn i, t ->
          {:ok, t2} = Stdio.send_message(t, %{"seq" => i})
          t2
        end)

      received =
        for _ <- 1..n do
          assert_receive {:acp_transport, ref, {:message, %{"seq" => seq}}}, 2_000
          assert ref == final.pid
          seq
        end

      assert received == Enum.to_list(1..n)

      :ok = Stdio.close(final)
    end

    test "a value containing a literal newline round-trips without corrupting framing" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())

      msg = %{"text" => "line one\nline two", "seq" => 1}
      {:ok, transport} = Stdio.send_message(transport, msg)

      assert_receive {:acp_transport, _ref, {:message, ^msg}}, 2_000

      # And the transport is still healthy for a subsequent frame — proof
      # the embedded newline (escaped by Jason inside the JSON string, not
      # emitted as a raw frame-delimiting byte) did not desync the reader.
      msg2 = %{"seq" => 2}
      {:ok, transport} = Stdio.send_message(transport, msg2)
      assert_receive {:acp_transport, _ref, {:message, ^msg2}}, 2_000

      :ok = Stdio.close(transport)
    end
  end

  describe "tolerant decoding of a misbehaving peer" do
    test "a non-JSON line and a valid-JSON-but-non-object line both produce decode_error, not a crash" do
      {:ok, transport} =
        Stdio.start_spawn("printf", ["not-json-at-all\n[1,2,3]\n"], owner: self())

      assert_receive {:acp_transport, ref, {:decode_error, _reason, "not-json-at-all"}}, 2_000
      assert ref == transport.pid

      assert_receive {:acp_transport, ^ref,
                      {:decode_error, {:not_an_object, [1, 2, 3]}, "[1,2,3]"}},
                     2_000

      # The peer (printf) exits right after writing — transport must still
      # deliver the exit cleanly rather than crash on the garbage it just
      # tolerated.
      assert_receive {:acp_transport, ^ref, {:closed, {:exit_status, 0}}}, 2_000
    end
  end

  describe "peer process exit" do
    test "a zero-exit peer delivers {:closed, {:exit_status, 0}}" do
      {:ok, transport} = Stdio.start_spawn("true", [], owner: self())

      assert_receive {:acp_transport, ref, {:closed, {:exit_status, 0}}}, 2_000
      assert ref == transport.pid
    end

    test "a nonzero-exit peer delivers its exit code" do
      {:ok, _transport} = Stdio.start_spawn("false", [], owner: self())

      assert_receive {:acp_transport, _ref, {:closed, {:exit_status, 1}}}, 2_000
    end
  end

  describe "close" do
    test "is idempotent" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())

      assert :ok = Stdio.close(transport)
      assert :ok = Stdio.close(transport)
    end

    test "send_message after close returns {:error, :closed}" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())
      :ok = Stdio.close(transport)

      assert {:error, :closed} = Stdio.send_message(transport, %{"a" => 1})
    end
  end

  describe "ownership" do
    test "frames arriving before an owner is set are buffered and flushed in order on adopt" do
      {:ok, transport} = Stdio.start_spawn("cat")

      {:ok, transport} = Stdio.send_message(transport, %{"early" => 1})
      {:ok, transport} = Stdio.send_message(transport, %{"early" => 2})
      # Let both ownerless round trips complete before adopting an owner.
      Process.sleep(50)

      :ok = Stdio.set_owner(transport, self())
      {:ok, transport} = Stdio.send_message(transport, %{"late" => true})

      # The pre-owner frames are delivered (a real editor's `initialize` sent
      # before the supervisor adopts the transport is not lost), in order,
      # ahead of the live frame.
      assert_receive {:acp_transport, _ref, {:message, %{"early" => 1}}}, 2_000
      assert_receive {:acp_transport, _ref, {:message, %{"early" => 2}}}, 2_000
      assert_receive {:acp_transport, _ref, {:message, %{"late" => true}}}, 2_000

      :ok = Stdio.close(transport)
    end
  end

  describe "unresolvable executable" do
    test "returns {:error, :executable_not_found} instead of raising" do
      assert {:error, :executable_not_found} =
               Stdio.start_spawn("definitely-not-a-real-executable-xyz")
    end
  end

  describe "unexpected messages" do
    test "are logged at debug and do not crash the transport" do
      {:ok, transport} = Stdio.start_spawn("cat", [], owner: self())

      send(transport.pid, :some_unexpected_message)

      msg = %{"still" => "alive"}
      {:ok, transport} = Stdio.send_message(transport, msg)
      assert_receive {:acp_transport, _ref, {:message, ^msg}}, 2_000

      :ok = Stdio.close(transport)
    end
  end
end
