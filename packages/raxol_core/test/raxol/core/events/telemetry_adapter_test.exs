defmodule Raxol.Core.Events.TelemetryAdapterTest do
  @moduledoc """
  End-to-end tests for `Raxol.Core.Events.TelemetryAdapter.dispatch/2`.

  These tests attach a real `:telemetry` handler in setup and capture the
  metadata emitted by `TelemetryAdapter.dispatch/2`. They verify the
  contract that the adapter propagates the current `TraceContext` into
  emitted metadata: `trace_id`, `span_id`, optional `parent_span_id`, and
  optional `causation_id`. The runtime relies on this propagation so that
  downstream subscribers (CloudEvents envelopes, log lines, observability
  pipelines) can reconstruct causation chains from telemetry alone.
  """

  use ExUnit.Case, async: false

  alias Raxol.Core.Events.TelemetryAdapter
  alias Raxol.Core.Telemetry.TraceContext

  setup do
    handler_id = "telemetry_adapter_test_#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:raxol, :events, :test_event],
      fn _event_name, measurements, metadata, _config ->
        send(test_pid, {:captured, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      TraceContext.clear()
    end)

    :ok
  end

  describe "trace context propagation into metadata" do
    test "no active trace: metadata has no trace fields" do
      TelemetryAdapter.dispatch(:test_event, %{foo: :bar})

      assert_receive {:captured, _measurements, metadata}
      refute Map.has_key?(metadata, :trace_id)
      refute Map.has_key?(metadata, :span_id)
      refute Map.has_key?(metadata, :parent_span_id)
      refute Map.has_key?(metadata, :causation_id)
      assert metadata.foo == :bar
    end

    test "active trace: metadata carries trace_id and span_id" do
      ctx = TraceContext.start_trace()
      TelemetryAdapter.dispatch(:test_event, %{})

      assert_receive {:captured, _measurements, metadata}
      assert metadata.trace_id == ctx.trace_id
      assert metadata.span_id == ctx.span_id
      refute Map.has_key?(metadata, :parent_span_id)
      refute Map.has_key?(metadata, :causation_id)
    end

    test "child span: metadata includes parent_span_id" do
      root = TraceContext.start_trace()
      child = TraceContext.start_span("child")

      TelemetryAdapter.dispatch(:test_event, %{})

      assert_receive {:captured, _measurements, metadata}
      assert metadata.trace_id == root.trace_id
      assert metadata.span_id == child.span_id
      assert metadata.parent_span_id == root.span_id
    end

    test "causation_id is included when set" do
      _ = TraceContext.start_trace()
      _ = TraceContext.set_causation("upstream-span-xyz")

      TelemetryAdapter.dispatch(:test_event, %{})

      assert_receive {:captured, _measurements, metadata}
      assert metadata.causation_id == "upstream-span-xyz"
    end

    test "causation_id absent from metadata when not set" do
      _ = TraceContext.start_trace()

      TelemetryAdapter.dispatch(:test_event, %{})

      assert_receive {:captured, _measurements, metadata}
      refute Map.has_key?(metadata, :causation_id)
    end

    test "all four fields can be present simultaneously" do
      root = TraceContext.start_trace()
      _ = TraceContext.set_causation("upstream-span-xyz")
      child = TraceContext.start_span("child")

      TelemetryAdapter.dispatch(:test_event, %{user_metadata: :keep})

      assert_receive {:captured, _measurements, metadata}
      assert metadata.trace_id == root.trace_id
      assert metadata.span_id == child.span_id
      assert metadata.parent_span_id == root.span_id
      assert metadata.causation_id == "upstream-span-xyz"
      assert metadata.user_metadata == :keep
    end
  end

  describe "measurement vs metadata extraction" do
    test "value-only data goes to measurements, not metadata" do
      TelemetryAdapter.dispatch(:test_event, %{value: 42})

      assert_receive {:captured, measurements, metadata}
      assert measurements == %{value: 42}
      refute Map.has_key?(metadata, :value)
    end

    test "count goes to measurements" do
      TelemetryAdapter.dispatch(:test_event, %{count: 7})

      assert_receive {:captured, measurements, _metadata}
      assert measurements == %{count: 7}
    end

    test "explicit :measurements key takes precedence" do
      TelemetryAdapter.dispatch(:test_event, %{
        measurements: %{duration_us: 1234}
      })

      assert_receive {:captured, measurements, _metadata}
      assert measurements == %{duration_us: 1234}
    end

    test "non-measurement keys flow into metadata" do
      TelemetryAdapter.dispatch(:test_event, %{user: "alice", action: :login})

      assert_receive {:captured, measurements, metadata}
      assert measurements == %{}
      assert metadata.user == "alice"
      assert metadata.action == :login
    end
  end
end
