defmodule Raxol.Core.Metrics.Cloud do
  @moduledoc """
  Cloud export for the Raxol metrics system.

  Buffers metrics and ships them over HTTP to a configured backend:

    * `:otlp` / `:signoz` — OTLP/HTTP JSON to an OpenTelemetry collector
      (`POST` to the configured endpoint, default `/v1/metrics`). For
      `:signoz`, a configured `api_key` is sent as `signoz-access-token`.
    * `:datadog` — the v1 series API (`DD-API-KEY` header, requires
      `api_key`).
    * `:prometheus` — Prometheus Pushgateway text exposition (`POST`; point
      the endpoint at `/metrics/job/<job>`).

  OTLP and Datadog export every recorded data point. Prometheus is a
  snapshot format (repeating a `{name, labels}` sample is invalid), so it
  exports the latest value per label set.

  Metrics enter through `record/4` (or the equivalent
  `{:metrics, type, name, value, tags}` message), which
  `Raxol.Core.Metrics.MetricsCollector.record_metric/4` forwards
  automatically whenever this process is running. Batches flush when they
  reach `batch_size` or every `flush_interval` ms; a failed export keeps
  the batch for the next flush, capped at ten batches to bound memory.

  HTTP transport is `Req`, an optional dependency; without it every export
  returns `{:error, :http_client_unavailable}`.

  CloudWatch is not supported: it needs SigV4 request signing, which means
  an AWS dependency this library does not take. (An earlier version
  accepted `:cloudwatch` and silently dropped the metrics.)
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log

  @compile {:no_warn_undefined, Req}

  @type cloud_service :: :otlp | :signoz | :datadog | :prometheus
  @type cloud_config :: %{
          service: cloud_service(),
          endpoint: String.t(),
          api_key: String.t() | nil,
          batch_size: pos_integer(),
          flush_interval: pos_integer(),
          compression: boolean()
        }

  # Default to OTLP (SigNoz / any OpenTelemetry collector).
  @default_config %{
    service: :otlp,
    endpoint: "http://localhost:4318/v1/metrics",
    api_key: nil,
    batch_size: 100,
    flush_interval: 10_000,
    compression: true
  }

  # On export failure the buffer is retained for retry, but never beyond
  # this many batches.
  @max_buffered_batches 10

  @doc """
  Records a metric for cloud export. A no-op returning `:ok` when the
  Cloud process is not running, so producers can call it unconditionally.
  """
  @spec record(atom(), atom() | String.t(), number(), list()) :: :ok
  def record(type, name, value, tags \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Kernel.send(pid, {:metrics, type, name, value, tags})
    end

    :ok
  end

  @doc """
  Configures the cloud metrics service.
  """
  @spec configure(map()) :: :ok | {:error, term()}
  def configure(config) when is_map(config) do
    GenServer.call(__MODULE__, {:configure, config})
  end

  @doc """
  Gets the current cloud configuration.
  """
  @spec get_config() :: cloud_config()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Flushes buffered metrics to the cloud service now. Returns the export
  result: `:ok` (also for an empty buffer) or `{:error, reason}`.
  """
  @spec flush_metrics() :: :ok | {:error, term()}
  def flush_metrics do
    GenServer.call(__MODULE__, :flush_metrics)
  end

  @impl true
  def init_manager(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %{
      config: config,
      metrics_buffer: [],
      last_flush: System.system_time(:millisecond)
    }

    schedule_flush(config.flush_interval)
    {:ok, state}
  end

  @impl true
  def handle_manager_call({:configure, new_config}, _from, state) do
    case validate_cloud_config(new_config) do
      :ok ->
        new_state = %{state | config: Map.merge(state.config, new_config)}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_manager_call(:flush_metrics, _from, state) do
    {new_state, result} = flush_metrics_to_cloud(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_manager_info(:flush_metrics, state) do
    {new_state, _result} = flush_metrics_to_cloud(state)
    schedule_flush(new_state.config.flush_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info({:metrics, type, name, value, tags}, state) do
    metric = %{
      type: type,
      name: name,
      value: value,
      tags: tags,
      timestamp: System.system_time(:second)
    }

    new_buffer = [metric | state.metrics_buffer]

    if length(new_buffer) >= state.config.batch_size do
      {new_state, _result} =
        flush_metrics_to_cloud(%{state | metrics_buffer: new_buffer})

      {:noreply, new_state}
    else
      {:noreply, %{state | metrics_buffer: new_buffer}}
    end
  end

  defp flush_metrics_to_cloud(%{metrics_buffer: []} = state), do: {state, :ok}

  defp flush_metrics_to_cloud(state) do
    # Chronological order; each formatter does its own backend-correct
    # grouping over the raw entries.
    metrics = Enum.reverse(state.metrics_buffer)

    case send_metrics_to_cloud(metrics, state.config) do
      :ok ->
        {%{
           state
           | metrics_buffer: [],
             last_flush: System.system_time(:millisecond)
         }, :ok}

      {:error, reason} = error ->
        Log.warning(
          "[Metrics.Cloud] export to #{state.config.service} failed: #{inspect(reason)}; " <>
            "retaining #{length(state.metrics_buffer)} metrics for retry"
        )

        capped =
          Enum.take(
            state.metrics_buffer,
            @max_buffered_batches * state.config.batch_size
          )

        {%{
           state
           | metrics_buffer: capped,
             last_flush: System.system_time(:millisecond)
         }, error}
    end
  end

  defp send_metrics_to_cloud(metrics, config) do
    case config.service do
      service when service in [:otlp, :signoz] ->
        post_json(
          config.endpoint,
          format_for_otlp(metrics),
          otlp_headers(config)
        )

      :datadog ->
        with :ok <- require_api_key(config) do
          post_json(config.endpoint, format_for_datadog(metrics), [
            {"dd-api-key", config.api_key}
          ])
        end

      :prometheus ->
        post_text(config.endpoint, format_for_prometheus(metrics))

      _ ->
        {:error, :invalid_service}
    end
  end

  defp otlp_headers(%{service: :signoz, api_key: key})
       when is_binary(key) and key != "",
       do: [{"signoz-access-token", key}]

  defp otlp_headers(_config), do: []

  defp require_api_key(%{api_key: key}) when is_binary(key) and key != "",
    do: :ok

  defp require_api_key(_config), do: {:error, :missing_api_key}

  # -- HTTP transport (Req, optional dependency) --------------------------------

  defp post_json(url, body, headers) do
    http_post(url, json: body, headers: headers)
  end

  defp post_text(url, body) do
    http_post(url,
      body: body,
      headers: [{"content-type", "text/plain; version=0.0.4"}]
    )
  end

  defp http_post(url, opts) do
    if Code.ensure_loaded?(Req) do
      case Req.post(url, opts ++ [retry: false, receive_timeout: 5_000]) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, {:http_status, status}}
        {:error, exception} -> {:error, exception}
      end
    else
      {:error, :http_client_unavailable}
    end
  end

  # -- Wire formats --------------------------------------------------------------

  # OTLP/HTTP JSON (opentelemetry-proto MetricsData): one gauge per metric
  # name, one data point per recorded value, each carrying its own
  # timestamp and attributes. Nothing is aggregated away.
  defp format_for_otlp(entries) do
    otlp_metrics =
      entries
      |> Enum.group_by(&{&1.type, &1.name})
      |> Enum.map(fn {{type, name}, group} ->
        %{
          name: metric_name(type, name),
          gauge: %{dataPoints: Enum.map(group, &otlp_data_point/1)}
        }
      end)

    %{
      resourceMetrics: [
        %{
          resource: %{
            attributes: [
              %{key: "service.name", value: %{stringValue: "raxol"}}
            ]
          },
          scopeMetrics: [
            %{
              scope: %{name: "raxol.core.metrics"},
              metrics: otlp_metrics
            }
          ]
        }
      ]
    }
  end

  defp otlp_data_point(entry) do
    %{
      asDouble: entry.value * 1.0,
      timeUnixNano: entry.timestamp * 1_000_000_000,
      attributes:
        Enum.map(entry.tags, fn tag ->
          {key, value} = tag_pair(tag)
          %{key: key, value: %{stringValue: value}}
        end)
    }
  end

  # Datadog v1 series API: one series per {metric, tags} with every point;
  # timestamps in seconds, tags as "key:value" strings.
  defp format_for_datadog(entries) do
    series =
      entries
      |> Enum.group_by(&{&1.type, &1.name, &1.tags})
      |> Enum.map(fn {{type, name, tags}, group} ->
        %{
          metric: metric_name(type, name),
          points: Enum.map(group, fn e -> [e.timestamp, e.value * 1.0] end),
          type: "gauge",
          tags:
            Enum.map(tags, fn tag ->
              {key, value} = tag_pair(tag)
              "#{key}:#{value}"
            end)
        }
      end)

    %{series: series}
  end

  # Prometheus text exposition format for a Pushgateway. The format is a
  # snapshot -- repeating a {name, labels} sample is invalid -- so the most
  # recent value per label set wins (gauge semantics).
  defp format_for_prometheus(entries) do
    entries
    |> Enum.group_by(&{&1.type, &1.name, &1.tags})
    |> Enum.map_join("", fn {{type, name, tags}, group} ->
      entry = List.last(group)

      labels =
        Enum.map_join(tags, ",", fn tag ->
          {key, value} = tag_pair(tag)
          ~s(#{prometheus_name(key)}="#{value}")
        end)

      prom_name = prometheus_name(metric_name(type, name))
      value = entry.value * 1.0

      case labels do
        "" -> "#{prom_name} #{value}\n"
        _ -> "#{prom_name}{#{labels}} #{value}\n"
      end
    end)
  end

  defp metric_name(type, name), do: "raxol.#{type}.#{name}"

  defp prometheus_name(name) do
    String.replace(to_string(name), ~r/[^a-zA-Z0-9_:]/, "_")
  end

  # Tags are either bare flags (`:slow`) or `{key, value}` pairs.
  defp tag_pair({key, value}), do: {to_string(key), to_string(value)}
  defp tag_pair(tag), do: {to_string(tag), "true"}

  # -- Config validation ---------------------------------------------------------

  defp validate_cloud_config(config) do
    config_with_defaults = Map.merge(@default_config, config)

    with :ok <- validate_service(config_with_defaults.service),
         :ok <- validate_endpoint(config_with_defaults.endpoint),
         :ok <- validate_api_key(config_with_defaults.api_key),
         :ok <- validate_batch_size(config_with_defaults.batch_size) do
      validate_flush_interval(config_with_defaults.flush_interval)
    end
  end

  defp validate_service(service)
       when service in [:otlp, :signoz, :datadog, :prometheus],
       do: :ok

  defp validate_service(:cloudwatch), do: {:error, :cloudwatch_not_supported}
  defp validate_service(_), do: {:error, :invalid_service}

  defp validate_endpoint(endpoint) when is_binary(endpoint) and endpoint != "",
    do: :ok

  defp validate_endpoint(_), do: {:error, :invalid_endpoint}

  # api_key is optional (OTLP collectors and pushgateways commonly need
  # none); when present it must be a non-empty string. Datadog enforces
  # presence at send time.
  defp validate_api_key(nil), do: :ok

  defp validate_api_key(api_key) when is_binary(api_key) and api_key != "",
    do: :ok

  defp validate_api_key(_), do: {:error, :invalid_api_key}

  defp validate_batch_size(batch_size)
       when is_integer(batch_size) and batch_size > 0,
       do: :ok

  defp validate_batch_size(_), do: {:error, :invalid_batch_size}

  defp validate_flush_interval(flush_interval)
       when is_integer(flush_interval) and flush_interval > 0,
       do: :ok

  defp validate_flush_interval(_), do: {:error, :invalid_flush_interval}

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_metrics, interval)
  end
end
