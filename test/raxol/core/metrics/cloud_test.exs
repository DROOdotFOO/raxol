defmodule Raxol.Core.Metrics.CloudTest do
  @moduledoc """
  Tests for cloud metrics export: configuration, batching, and the real
  HTTP path. Exports go over the wire to a local capture server (a real
  cowboy listener), so what is asserted is what a collector would receive.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Metrics.Cloud

  defmodule CapturePlug do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      send(
        opts[:test_pid],
        {:http_request,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: Map.new(conn.req_headers),
           body: body
         }}
      )

      send_resp(conn, 200, "")
    end
  end

  # A real HTTP listener on an ephemeral port; requests are relayed to the
  # test process for assertion.
  defp start_capture_server do
    ref = :"cloud_capture_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(CapturePlug, [test_pid: self()], port: 0, ref: ref)

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    :ranch.get_port(ref)
  end

  # Bind an ephemeral port, then release it: gives a port that is very
  # likely closed, for the connection-refused path.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_cloud(opts) do
    start_supervised!({Cloud, [name: Cloud] ++ opts})
  end

  # Quiet defaults: big batches and a long interval so only explicit
  # flushes (or explicit batch-size tests) trigger exports.
  defp quiet_opts(port, extra \\ []) do
    [
      endpoint: "http://127.0.0.1:#{port}/v1/metrics",
      batch_size: 100,
      flush_interval: 60_000
    ] ++ extra
  end

  defp otlp_metrics(body) do
    get_in(body, [
      "resourceMetrics",
      Access.at(0),
      "scopeMetrics",
      Access.at(0),
      "metrics"
    ])
  end

  describe "configure/1" do
    setup do
      start_cloud(quiet_opts(0))
      :ok
    end

    test "accepts a valid config" do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key",
        batch_size: 50,
        flush_interval: 5000
      }

      assert :ok == Cloud.configure(config)
      returned = Cloud.get_config()
      assert returned.service == :datadog
      assert returned.api_key == "test_key"
      assert returned.batch_size == 50
    end

    test "rejects an unknown service" do
      assert {:error, :invalid_service} == Cloud.configure(%{service: :invalid})
    end

    test "rejects cloudwatch with a specific reason" do
      assert {:error, :cloudwatch_not_supported} ==
               Cloud.configure(%{service: :cloudwatch})
    end

    test "rejects an empty endpoint" do
      assert {:error, :invalid_endpoint} == Cloud.configure(%{endpoint: ""})
    end

    test "accepts a config without api_key" do
      assert :ok == Cloud.configure(%{service: :prometheus})
    end

    test "rejects a non-string api_key" do
      assert {:error, :invalid_api_key} == Cloud.configure(%{api_key: 123})
    end

    test "rejects an invalid batch size" do
      assert {:error, :invalid_batch_size} == Cloud.configure(%{batch_size: 0})
    end

    test "rejects an invalid flush interval" do
      assert {:error, :invalid_flush_interval} ==
               Cloud.configure(%{flush_interval: 0})
    end
  end

  describe "OTLP export" do
    test "posts spec-shaped OTLP JSON to the collector endpoint" do
      port = start_capture_server()
      start_cloud(quiet_opts(port))

      Cloud.record(:performance, :frame_time, 16, [:test])
      Cloud.record(:performance, :frame_time, 24, [:test])

      assert :ok == Cloud.flush_metrics()
      assert_receive {:http_request, req}, 2_000

      assert req.method == "POST"
      assert req.path == "/v1/metrics"
      assert req.headers["content-type"] =~ "application/json"

      [metric] = req.body |> Jason.decode!() |> otlp_metrics()
      assert metric["name"] == "raxol.performance.frame_time"

      # Every recorded value arrives as its own data point, in order.
      points = metric["gauge"]["dataPoints"]
      assert Enum.map(points, & &1["asDouble"]) == [16.0, 24.0]

      for point <- points do
        assert [%{"key" => "test", "value" => %{"stringValue" => "true"}}] =
                 point["attributes"]

        assert is_integer(point["timeUnixNano"])
      end
    end

    test "signoz sends the access token header" do
      port = start_capture_server()
      start_cloud(quiet_opts(port, service: :signoz, api_key: "sgnz-token"))

      Cloud.record(:performance, :frame_time, 1, [])
      assert :ok == Cloud.flush_metrics()

      assert_receive {:http_request, req}, 2_000
      assert req.headers["signoz-access-token"] == "sgnz-token"
    end

    test "flushing an empty buffer sends nothing and returns ok" do
      port = start_capture_server()
      start_cloud(quiet_opts(port))

      assert :ok == Cloud.flush_metrics()
      refute_receive {:http_request, _}, 200
    end
  end

  describe "Datadog export" do
    test "posts a v1 series body with the api key header" do
      port = start_capture_server()

      start_cloud(
        quiet_opts(port,
          service: :datadog,
          endpoint: "http://127.0.0.1:#{port}/api/v1/series",
          api_key: "dd-key"
        )
      )

      Cloud.record(:performance, :render_ms, 10, [{:surface, :terminal}])
      Cloud.record(:performance, :render_ms, 14, [{:surface, :terminal}])
      assert :ok == Cloud.flush_metrics()

      assert_receive {:http_request, req}, 2_000
      assert req.path == "/api/v1/series"
      assert req.headers["dd-api-key"] == "dd-key"

      # Same {metric, tags} -> one series carrying every point.
      %{"series" => [series]} = Jason.decode!(req.body)
      assert series["metric"] == "raxol.performance.render_ms"
      assert series["type"] == "gauge"
      assert series["tags"] == ["surface:terminal"]
      assert [[_, 10.0], [_, 14.0]] = series["points"]
    end

    test "refuses to export without an api key" do
      port = start_capture_server()
      start_cloud(quiet_opts(port, service: :datadog))

      Cloud.record(:performance, :render_ms, 10, [])
      assert {:error, :missing_api_key} == Cloud.flush_metrics()
      refute_receive {:http_request, _}, 200
    end
  end

  describe "Prometheus export" do
    test "posts text exposition format with sanitized names" do
      port = start_capture_server()

      start_cloud(
        quiet_opts(port,
          service: :prometheus,
          endpoint: "http://127.0.0.1:#{port}/metrics/job/raxol"
        )
      )

      Cloud.record(:performance, :"frame.time", 5, [:slow])
      Cloud.record(:performance, :"frame.time", 9, [:slow])
      assert :ok == Cloud.flush_metrics()

      assert_receive {:http_request, req}, 2_000
      assert req.headers["content-type"] =~ "text/plain"

      # Exposition format is a snapshot: the latest value per label set.
      assert req.body == ~s(raxol_performance_frame_time{slow="true"} 9.0\n)
    end
  end

  describe "batching and flushing" do
    test "reaching batch_size flushes without an explicit call" do
      port = start_capture_server()
      start_cloud(quiet_opts(port, batch_size: 2))

      Cloud.record(:performance, :tick, 1, [])
      Cloud.record(:performance, :tick, 3, [])

      assert_receive {:http_request, req}, 2_000

      [metric | _] = req.body |> Jason.decode!() |> otlp_metrics()
      points = metric["gauge"]["dataPoints"]
      assert Enum.map(points, & &1["asDouble"]) == [1.0, 3.0]
    end

    test "the periodic timer flushes on the configured interval" do
      port = start_capture_server()
      start_cloud(quiet_opts(port, flush_interval: 50))

      Cloud.record(:performance, :tick, 1, [])

      # No explicit flush: only the timer can deliver this.
      assert_receive {:http_request, _req}, 2_000
    end

    test "a failed export returns the error and retains the batch for retry" do
      port = start_capture_server()
      start_cloud(quiet_opts(closed_port()))

      Cloud.record(:performance, :tick, 7, [])
      assert {:error, _reason} = Cloud.flush_metrics()

      # Repoint at the live server; the retained metric must arrive.
      assert :ok ==
               Cloud.configure(%{
                 endpoint: "http://127.0.0.1:#{port}/v1/metrics"
               })

      assert :ok == Cloud.flush_metrics()
      assert_receive {:http_request, req}, 2_000

      [metric | _] = req.body |> Jason.decode!() |> otlp_metrics()
      assert metric["name"] == "raxol.performance.tick"
    end
  end

  describe "producer wiring" do
    test "MetricsCollector.record_metric reaches the cloud exporter end to end" do
      port = start_capture_server()
      start_cloud(quiet_opts(port, batch_size: 1))

      Raxol.Core.Metrics.MetricsCollector.record_metric(
        :frame_time,
        :performance,
        42,
        tags: [:e2e]
      )

      assert_receive {:http_request, req}, 2_000

      [metric] = req.body |> Jason.decode!() |> otlp_metrics()
      assert metric["name"] == "raxol.performance.frame_time"
      assert [%{"asDouble" => 42.0}] = metric["gauge"]["dataPoints"]
    end

    test "record/4 without a running exporter is a safe no-op" do
      # No Cloud started in this test.
      assert :ok == Cloud.record(:performance, :orphan, 1, [])
    end
  end
end
