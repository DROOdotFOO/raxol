defmodule Raxol.Core.Telemetry.ContextTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Telemetry.Context

  setup do
    Context.clear()
    on_exit(fn -> Context.clear() end)
    :ok
  end

  describe "trace lifecycle" do
    test "start_trace returns a fresh context with nil parent and empty baggage" do
      ctx = Context.start_trace()
      assert is_binary(ctx.trace_id)
      assert is_binary(ctx.span_id)
      assert ctx.parent_span_id == nil
      assert ctx.baggage == %{}
      assert Context.get() == ctx
    end

    test "start_trace honors a provided trace_id and baggage" do
      ctx = Context.start_trace(trace_id: "incoming-123", baggage: %{a: 1})
      assert ctx.trace_id == "incoming-123"
      assert ctx.baggage == %{a: 1}
    end

    test "trace_id/0 and span_id/0 mirror the active context; nil when inactive" do
      assert Context.trace_id() == nil
      assert Context.span_id() == nil
      ctx = Context.start_trace()
      assert Context.trace_id() == ctx.trace_id
      assert Context.span_id() == ctx.span_id
    end

    test "clear wipes trace and span stack" do
      Context.start_trace()
      Context.start_span(:child)
      assert Context.clear() == :ok
      assert Context.get() == nil
    end
  end

  describe "span nesting" do
    test "start_span creates a child whose parent is the previous span" do
      root = Context.start_trace()
      child = Context.start_span(:render)
      assert child.parent_span_id == root.span_id
      assert child.span_id != root.span_id
      assert child.trace_id == root.trace_id
    end

    test "end_span restores the parent span" do
      root = Context.start_trace()
      _child = Context.start_span(:render)
      restored = Context.end_span()
      assert restored.span_id == root.span_id
    end

    test "start_span with no active trace bootstraps a trace" do
      assert Context.get() == nil
      Context.start_span(:solo)
      assert %{trace_id: tid} = Context.get()
      assert is_binary(tid)
    end

    test "with_span runs the fun then restores the parent" do
      root = Context.start_trace()

      result =
        Context.with_span(:work, fn ->
          assert Context.get().parent_span_id == root.span_id
          :done
        end)

      assert result == :done
      assert Context.get().span_id == root.span_id
    end
  end

  describe "baggage" do
    test "put/get baggage round-trips within an active trace" do
      Context.start_trace()
      assert Context.put_baggage(:user_id, "u1") == :ok
      assert Context.get_baggage(:user_id) == "u1"
      assert Context.get_baggage(:missing, :dflt) == :dflt
    end

    test "baggage ops are no-ops with default when inactive" do
      assert Context.put_baggage(:k, "v") == :ok
      assert Context.get_baggage(:k, :fallback) == :fallback
    end
  end

  describe "to_metadata" do
    test "returns extra unchanged when inactive" do
      assert Context.to_metadata(%{a: 1}) == %{a: 1}
    end

    test "merges trace_id/span_id/parent_span_id when active" do
      ctx = Context.start_trace()
      meta = Context.to_metadata(%{component: :button})
      assert meta.component == :button
      assert meta.trace_id == ctx.trace_id
      assert meta.span_id == ctx.span_id
      assert meta.parent_span_id == ctx.parent_span_id
    end
  end

  describe "telemetry emission (the contract the merge must preserve)" do
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
        "ctx-char-#{inspect(ref)}",
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("ctx-char-#{inspect(ref)}") end)
      %{ref: ref}
    end

    test "execute/3 emits with trace context merged into metadata", %{ref: ref} do
      ctx = Context.start_trace()
      Context.execute([:raxol, :test, :evt], %{count: 1}, %{k: :v})
      assert_receive {^ref, [:raxol, :test, :evt], %{count: 1}, meta}
      assert meta.k == :v
      assert meta.trace_id == ctx.trace_id
      assert meta.span_id == ctx.span_id
    end

    test "span/3 emits start then stop, returns fun result, injects trace", %{ref: ref} do
      Context.start_trace()
      result = Context.span([:raxol, :test, :op], %{c: :x}, fn -> :ok_result end)
      assert result == :ok_result
      assert_receive {^ref, [:raxol, :test, :op, :start], %{system_time: _}, m_start}
      assert is_binary(m_start.trace_id) and is_binary(m_start.span_id)
      assert_receive {^ref, [:raxol, :test, :op, :stop], %{duration: _}, m_stop}
      assert m_stop.result == :ok
    end

    test "span/3 emits :exception and reraises on failure", %{ref: ref} do
      Context.start_trace()

      assert_raise RuntimeError, "boom", fn ->
        Context.span([:raxol, :test, :op], %{}, fn -> raise "boom" end)
      end

      assert_receive {^ref, [:raxol, :test, :op, :exception], %{duration: _}, meta}
      assert %RuntimeError{} = meta.exception
    end
  end

  describe "capture/restore" do
    test "capture/restore round-trips context into another process" do
      ctx = Context.start_trace()
      captured = Context.capture()

      task =
        Task.async(fn ->
          Context.restore(captured)
          Context.get().trace_id
        end)

      assert Task.await(task) == ctx.trace_id
    end

    test "capture returns nil when inactive; restore(nil) is a no-op" do
      assert Context.capture() == nil
      assert Context.restore(nil) == :ok
    end
  end
end
