defmodule Raxol.Core.Telemetry.TraceContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.TraceContext

  setup do
    on_exit(fn -> TraceContext.clear() end)
    :ok
  end

  describe "start_trace/1" do
    test "generates unique trace_id and span_id" do
      ctx = TraceContext.start_trace()

      assert is_binary(ctx.trace_id)
      assert is_binary(ctx.span_id)
      assert byte_size(ctx.trace_id) == 16
      assert byte_size(ctx.span_id) == 16
      assert ctx.parent_span_id == nil
    end

    test "generates different ids on each call" do
      ctx1 = TraceContext.start_trace()
      ctx2 = TraceContext.start_trace()

      assert ctx1.trace_id != ctx2.trace_id
      assert ctx1.span_id != ctx2.span_id
    end

    test "uses custom trace_id when provided" do
      ctx = TraceContext.start_trace(trace_id: "custom-trace-123")

      assert ctx.trace_id == "custom-trace-123"
      assert is_binary(ctx.span_id)
      assert ctx.parent_span_id == nil
    end

    test "resets span stack on new trace" do
      TraceContext.start_trace()
      TraceContext.start_span("child")

      ctx = TraceContext.start_trace()

      assert ctx.parent_span_id == nil
    end
  end

  describe "current/0" do
    test "returns nil fields when no trace started" do
      ctx = TraceContext.current()

      assert ctx == %{
               trace_id: nil,
               span_id: nil,
               parent_span_id: nil,
               causation_id: nil
             }
    end

    test "returns active context after start_trace" do
      started = TraceContext.start_trace()
      ctx = TraceContext.current()

      assert ctx == started
    end
  end

  describe "start_span/1" do
    test "creates child span with parent set to previous span" do
      root = TraceContext.start_trace()
      child = TraceContext.start_span("child_op")

      assert child.trace_id == root.trace_id
      assert child.span_id != root.span_id
      assert child.parent_span_id == root.span_id
    end

    test "generates a new unique span_id" do
      TraceContext.start_trace()
      child = TraceContext.start_span("op")

      assert is_binary(child.span_id)
      assert byte_size(child.span_id) == 16
    end
  end

  describe "end_span/0" do
    test "restores parent span after ending child" do
      root = TraceContext.start_trace()
      _child = TraceContext.start_span("child_op")
      restored = TraceContext.end_span()

      assert restored.trace_id == root.trace_id
      assert restored.span_id == root.span_id
      assert restored.parent_span_id == nil
    end

    test "handles nested spans correctly" do
      root = TraceContext.start_trace()
      child1 = TraceContext.start_span("level1")
      child2 = TraceContext.start_span("level2")

      # Verify deepest nesting
      assert child2.parent_span_id == child1.span_id

      # End level2 -> back to level1
      after_end2 = TraceContext.end_span()
      assert after_end2.span_id == child1.span_id
      assert after_end2.parent_span_id == root.span_id

      # End level1 -> back to root
      after_end1 = TraceContext.end_span()
      assert after_end1.span_id == root.span_id
      assert after_end1.parent_span_id == nil
    end

    test "handles triple nesting" do
      root = TraceContext.start_trace()
      s1 = TraceContext.start_span("a")
      s2 = TraceContext.start_span("b")
      _s3 = TraceContext.start_span("c")

      TraceContext.end_span()
      ctx = TraceContext.current()
      assert ctx.span_id == s2.span_id
      assert ctx.parent_span_id == s1.span_id

      TraceContext.end_span()
      ctx = TraceContext.current()
      assert ctx.span_id == s1.span_id
      assert ctx.parent_span_id == root.span_id

      TraceContext.end_span()
      ctx = TraceContext.current()
      assert ctx.span_id == root.span_id
      assert ctx.parent_span_id == nil
    end
  end

  describe "clear/0" do
    test "removes all trace context" do
      TraceContext.start_trace()
      TraceContext.start_span("op")

      assert TraceContext.clear() == :ok

      ctx = TraceContext.current()
      assert ctx.trace_id == nil
      assert ctx.span_id == nil
      assert ctx.parent_span_id == nil
    end

    test "active? returns false after clear" do
      TraceContext.start_trace()
      assert TraceContext.active?()

      TraceContext.clear()
      refute TraceContext.active?()
    end
  end

  describe "active?/0" do
    test "returns false when no trace" do
      refute TraceContext.active?()
    end

    test "returns true after start_trace" do
      TraceContext.start_trace()
      assert TraceContext.active?()
    end
  end

  describe "with_trace/1" do
    test "executes function within a trace and returns result" do
      result =
        TraceContext.with_trace(fn ->
          assert TraceContext.active?()
          :the_result
        end)

      assert result == :the_result
      refute TraceContext.active?()
    end

    test "clears context even when function raises" do
      assert_raise RuntimeError, "boom", fn ->
        TraceContext.with_trace(fn ->
          raise "boom"
        end)
      end

      refute TraceContext.active?()
    end
  end

  describe "with_span/2" do
    test "creates span, executes function, and restores parent" do
      root = TraceContext.start_trace()

      result =
        TraceContext.with_span("my_span", fn ->
          ctx = TraceContext.current()
          assert ctx.parent_span_id == root.span_id
          assert ctx.span_id != root.span_id
          :span_result
        end)

      assert result == :span_result

      ctx = TraceContext.current()
      assert ctx.span_id == root.span_id
      assert ctx.parent_span_id == nil
    end

    test "restores parent span even when function raises" do
      root = TraceContext.start_trace()

      assert_raise RuntimeError, "oops", fn ->
        TraceContext.with_span("failing_span", fn ->
          raise "oops"
        end)
      end

      ctx = TraceContext.current()
      assert ctx.span_id == root.span_id
    end

    test "nests correctly" do
      root = TraceContext.start_trace()

      TraceContext.with_span("outer", fn ->
        outer_ctx = TraceContext.current()
        assert outer_ctx.parent_span_id == root.span_id

        TraceContext.with_span("inner", fn ->
          inner_ctx = TraceContext.current()
          assert inner_ctx.parent_span_id == outer_ctx.span_id
        end)

        restored = TraceContext.current()
        assert restored.span_id == outer_ctx.span_id
      end)

      final = TraceContext.current()
      assert final.span_id == root.span_id
    end
  end

  describe "format/0" do
    test "returns empty string when no trace" do
      assert TraceContext.format() == ""
    end

    test "returns formatted trace and span ids" do
      TraceContext.start_trace(trace_id: "abcdef0123456789")
      formatted = TraceContext.format()

      assert formatted =~ ~r/^\[trace:abcdef01 span:[a-f0-9]{8}\]$/
    end
  end

  describe "to_headers/0" do
    test "returns empty map when no trace" do
      assert TraceContext.to_headers() == %{}
    end

    test "returns headers with trace and span ids" do
      ctx = TraceContext.start_trace()
      headers = TraceContext.to_headers()

      assert headers["x-trace-id"] == ctx.trace_id
      assert headers["x-span-id"] == ctx.span_id
      refute Map.has_key?(headers, "x-parent-span-id")
    end

    test "includes parent span id when in a child span" do
      TraceContext.start_trace()
      TraceContext.start_span("child")
      headers = TraceContext.to_headers()

      assert Map.has_key?(headers, "x-parent-span-id")
    end
  end

  describe "from_headers/1" do
    test "restores trace from headers" do
      ctx = TraceContext.from_headers(%{"x-trace-id" => "remote-trace-abc"})

      assert ctx.trace_id == "remote-trace-abc"
      assert is_binary(ctx.span_id)
    end

    test "sets parent_span_id from incoming span header" do
      ctx =
        TraceContext.from_headers(%{
          "x-trace-id" => "remote-trace",
          "x-span-id" => "remote-span"
        })

      assert ctx.trace_id == "remote-trace"
      assert ctx.parent_span_id == "remote-span"
    end

    test "returns nil context when headers are empty" do
      ctx = TraceContext.from_headers(%{})

      assert ctx.trace_id == nil
    end

    test "round-trips causation_id through headers" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("caused-by-event-42")

      headers = TraceContext.to_headers()
      assert headers["x-causation-id"] == "caused-by-event-42"

      TraceContext.clear()
      _ = TraceContext.from_headers(headers)

      assert TraceContext.current().causation_id == "caused-by-event-42"
    end
  end

  describe "causation_id" do
    test "current/0 includes causation_id field defaulting to nil" do
      ctx = TraceContext.current()
      assert Map.has_key?(ctx, :causation_id)
      assert ctx.causation_id == nil
    end

    test "set_causation/1 stores the id in the current process" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("event-99")

      assert TraceContext.current().causation_id == "event-99"
    end

    test "set_causation(nil) clears the id" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("event-99")
      _ = TraceContext.set_causation(nil)

      assert TraceContext.current().causation_id == nil
    end

    test "clear/0 removes causation_id" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("event-99")
      :ok = TraceContext.clear()

      assert TraceContext.current().causation_id == nil
    end

    test "causation_id is independent of parent_span_id" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("upstream-span")
      _ = TraceContext.start_span("child")

      ctx = TraceContext.current()
      assert ctx.causation_id == "upstream-span"
      assert is_binary(ctx.parent_span_id)
      refute ctx.parent_span_id == ctx.causation_id
    end
  end

  describe "to_metadata/1" do
    test "returns extra unchanged when inactive" do
      assert TraceContext.to_metadata(%{a: 1}) == %{a: 1}
    end

    test "merges trace_id/span_id/parent_span_id when active" do
      ctx = TraceContext.start_trace()
      meta = TraceContext.to_metadata(%{component: :button})
      assert meta.component == :button
      assert meta.trace_id == ctx.trace_id
      assert meta.span_id == ctx.span_id
      assert meta.parent_span_id == ctx.parent_span_id
    end
  end

  describe "telemetry emission (equivalence with the retired Context)" do
    setup do
      test_pid = self()
      ref = make_ref()

      events = [
        [:raxol, :test, :op, :start],
        [:raxol, :test, :op, :stop],
        [:raxol, :test, :op, :exception],
        [:raxol, :test, :evt]
      ]

      :telemetry.attach_many(
        "tc-equiv-#{inspect(ref)}",
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("tc-equiv-#{inspect(ref)}") end)
      %{ref: ref}
    end

    test "execute/3 emits with trace context merged into metadata", %{ref: ref} do
      ctx = TraceContext.start_trace()
      TraceContext.execute([:raxol, :test, :evt], %{count: 1}, %{k: :v})
      assert_receive {^ref, [:raxol, :test, :evt], %{count: 1}, meta}
      assert meta.k == :v
      assert meta.trace_id == ctx.trace_id
      assert meta.span_id == ctx.span_id
    end

    test "span/3 emits start then stop, returns fun result, injects trace", %{ref: ref} do
      TraceContext.start_trace()
      result = TraceContext.span([:raxol, :test, :op], %{c: :x}, fn -> :ok_result end)
      assert result == :ok_result
      assert_receive {^ref, [:raxol, :test, :op, :start], %{system_time: _}, m_start}
      assert is_binary(m_start.trace_id) and is_binary(m_start.span_id)
      assert_receive {^ref, [:raxol, :test, :op, :stop], %{duration: _}, m_stop}
      assert m_stop.result == :ok
    end

    test "span/3 emits :exception and reraises on failure", %{ref: ref} do
      TraceContext.start_trace()

      assert_raise RuntimeError, "boom", fn ->
        TraceContext.span([:raxol, :test, :op], %{}, fn -> raise "boom" end)
      end

      assert_receive {^ref, [:raxol, :test, :op, :exception], %{duration: _}, meta}
      assert %RuntimeError{} = meta.exception
    end
  end
end
