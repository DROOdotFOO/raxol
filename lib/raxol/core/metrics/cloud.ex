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

  OTLP and Datadog export every recorded data point (nanosecond
  timestamps). Prometheus is a snapshot format (repeating a
  `{name, labels}` sample is invalid), so it exports the latest value per
  rendered label set.

  ## Ingestion and flushing

  Metrics enter through `record/4` (or the equivalent
  `{:metrics, type, name, value, tags}` message), which
  `Raxol.Core.Metrics.MetricsCollector.record_metric/4` forwards
  automatically whenever this process is running. Only numeric values are
  exported; non-numeric values (the collector also accepts maps) are
  dropped at ingestion rather than crashing the exporter at flush time.

  Automatic exports — the batch-size trigger and the periodic timer — run
  in a monitored helper process, so a slow or unreachable collector never
  blocks metric ingestion, and a crash in export code cannot take the
  exporter down. At most one export is in flight at a time. After a failed
  export the batch is retained (capped at #{10} batches) and the batch-size
  trigger backs off; the periodic timer is the retry cadence, so an outage
  costs one attempt per `flush_interval`, not one per metric.

  `flush_metrics/0` is the manual/synchronous path (tests, shutdown
  hooks): it exports in the server and returns the transport result, or
  `{:error, :export_in_flight}` if an async export is running.

  HTTP transport is `Req`, an optional dependency; without it every export
  returns `{:error, :http_client_unavailable}`.

  Crash reports redact `api_key` (see `format_status/1`).

  CloudWatch is not supported: it needs SigV4 request signing, which means
  an AWS dependency this library does not take; it is rejected at
  configuration time rather than silently dropping metrics.
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
  # this many batches (newest kept).
  @max_buffered_batches 10

  @doc """
  Records a metric for cloud export. A no-op returning `:ok` when the
  Cloud process is not running or the value is not a number, so producers
  can call it unconditionally.
  """
  @spec record(atom(), atom() | String.t(), term(), list()) :: :ok
  def record(type, name, value, tags \\ [])

  def record(type, name, value, tags) when is_number(value) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Kernel.send(pid, {:metrics, type, name, value, tags})
    end

    :ok
  end

  def record(_type, _name, _value, _tags), do: :ok

  @doc """
  Configures the cloud metrics service. The new keys are validated against
  the configuration that would result (current config merged with the
  changes), not against defaults.
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
  Flushes buffered metrics to the cloud service now, synchronously in the
  server. Returns the export result: `:ok` (also for an empty buffer),
  `{:error, :export_in_flight}` when an async export is running, or the
  transport error.
  """
  @spec flush_metrics() :: :ok | {:error, term()}
  def flush_metrics do
    GenServer.call(__MODULE__, :flush_metrics, 15_000)
  end

  @impl true
  def init_manager(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    case validate_cloud_config(config) do
      :ok ->
        state = %{
          config: config,
          metrics_buffer: [],
          buffer_count: 0,
          inflight: nil,
          last_failure_ms: nil
        }

        schedule_flush(config.flush_interval)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:invalid_cloud_config, reason}}
    end
  end

  # Redact the API key from crash reports and :sys.get_status output.
  @impl GenServer
  def format_status(status) do
    redact = fn
      %{config: %{} = config} = state ->
        %{state | config: Map.replace(config, :api_key, "[REDACTED]")}

      other ->
        other
    end

    Map.update(status, :state, nil, redact)
  end

  @impl true
  def handle_manager_call({:configure, new_config}, _from, state) do
    merged = Map.merge(state.config, new_config)

    case validate_cloud_config(merged) do
      :ok -> {:reply, :ok, %{state | config: merged}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_manager_call(:flush_metrics, _from, state) do
    cond do
      state.inflight != nil ->
        {:reply, {:error, :export_in_flight}, state}

      state.metrics_buffer == [] ->
        {:reply, :ok, state}

      true ->
        entries = Enum.reverse(state.metrics_buffer)

        case send_metrics_to_cloud(entries, state.config) do
          :ok ->
            {:reply, :ok, clear_buffer(%{state | last_failure_ms: nil})}

          {:error, _reason} = error ->
            # Clear BEFORE retaining: retain_after_failure appends the
            # failed entries to whatever is buffered, and here they are
            # the same list -- without the clear each failed manual flush
            # would double every retained entry.
            {:reply, error,
             retain_after_failure(
               clear_buffer(state),
               state.metrics_buffer,
               error
             )}
        end
    end
  end

  @impl true
  def handle_manager_info(:flush_metrics, state) do
    state =
      if state.inflight == nil and state.metrics_buffer != [] do
        start_export(state)
      else
        state
      end

    schedule_flush(state.config.flush_interval)
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:metrics, type, name, value, tags}, state)
      when is_number(value) do
    metric = %{
      type: type,
      name: name,
      value: value,
      tags: normalize_tags(tags),
      timestamp: System.system_time(:nanosecond)
    }

    state = %{
      state
      | metrics_buffer: [metric | state.metrics_buffer],
        buffer_count: state.buffer_count + 1
    }

    # Batch-size trigger: only when no export is in flight and we are not
    # backing off after a failure -- otherwise a dead collector would turn
    # every metric into an export attempt. The periodic timer retries.
    if state.buffer_count >= state.config.batch_size and
         state.inflight == nil and backoff_elapsed?(state) do
      {:noreply, start_export(state)}
    else
      {:noreply, state}
    end
  end

  # Non-numeric values (maps etc.) are dropped: the collector's local ETS
  # store accepts them, the wire formats do not.
  @impl true
  def handle_manager_info({:metrics, _type, _name, _value, _tags}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_manager_info(
        {:export_result, pid, result},
        %{inflight: %{pid: pid}} = state
      ) do
    Process.demonitor(state.inflight.mref, [:flush])

    case result do
      :ok ->
        {:noreply, %{state | inflight: nil, last_failure_ms: nil}}

      {:error, _reason} = error ->
        {:noreply,
         retain_after_failure(
           %{state | inflight: nil},
           state.inflight.snapshot,
           error
         )}
    end
  end

  @impl true
  def handle_manager_info(
        {:DOWN, mref, :process, pid, reason},
        %{inflight: %{mref: mref, pid: pid}} = state
      ) do
    {:noreply,
     retain_after_failure(
       %{state | inflight: nil},
       state.inflight.snapshot,
       {:error, {:export_crashed, reason}}
     )}
  end

  # Stray messages (e.g. a DOWN for an export whose result was already
  # consumed) must not crash the exporter.
  @impl true
  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Export orchestration ------------------------------------------------------

  # Run the export in a monitored helper process: a slow endpoint never
  # blocks ingestion, and a crash in formatting/transport is contained
  # (reported back as a failed export via :DOWN).
  defp start_export(state) do
    snapshot = state.metrics_buffer
    entries = Enum.reverse(snapshot)
    config = state.config
    parent = self()

    {pid, mref} =
      spawn_monitor(fn ->
        result = send_metrics_to_cloud(entries, config)
        Kernel.send(parent, {:export_result, self(), result})
      end)

    clear_buffer(%{
      state
      | inflight: %{pid: pid, mref: mref, snapshot: snapshot}
    })
  end

  defp clear_buffer(state), do: %{state | metrics_buffer: [], buffer_count: 0}

  defp retain_after_failure(state, failed_entries, {:error, reason}) do
    Log.warning(
      "[Metrics.Cloud] export to #{state.config.service} failed: #{inspect(reason)}; " <>
        "retaining #{length(failed_entries)} metrics for retry"
    )

    # Newer entries (recorded during the export) stay in front; the failed
    # snapshot is older. Cap keeps the newest.
    combined =
      Enum.take(
        state.metrics_buffer ++ failed_entries,
        @max_buffered_batches * state.config.batch_size
      )

    %{
      state
      | metrics_buffer: combined,
        buffer_count: length(combined),
        last_failure_ms: System.monotonic_time(:millisecond)
    }
  end

  defp backoff_elapsed?(%{last_failure_ms: nil}), do: true

  defp backoff_elapsed?(state) do
    System.monotonic_time(:millisecond) - state.last_failure_ms >=
      state.config.flush_interval
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
      case Req.post(
             url,
             opts ++
               [
                 retry: false,
                 receive_timeout: 5_000,
                 connect_options: [timeout: 5_000]
               ]
           ) do
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
      timeUnixNano: entry.timestamp,
      attributes:
        Enum.map(entry.tags, fn {key, value} ->
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
          points:
            Enum.map(group, fn e ->
              [div(e.timestamp, 1_000_000_000), e.value * 1.0]
            end),
          type: "gauge",
          tags: Enum.map(tags, fn {key, value} -> "#{key}:#{value}" end)
        }
      end)

    %{series: series}
  end

  # Prometheus text exposition format for a Pushgateway. The format is a
  # snapshot -- repeating a {name, labels} sample is invalid -- so entries
  # are grouped by their RENDERED name+labels (tag terms that render
  # identically must not produce duplicate samples) and the most recent
  # value per group wins.
  defp format_for_prometheus(entries) do
    entries
    |> Enum.map(fn entry ->
      name = prometheus_name(metric_name(entry.type, entry.name))

      labels =
        Enum.map_join(entry.tags, ",", fn {key, value} ->
          ~s(#{prometheus_label_name(key)}="#{escape_label_value(value)}")
        end)

      {{name, labels}, entry}
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, entry} -> entry end)
    |> Enum.map_join("", fn {{name, labels}, group} ->
      entry = List.last(group)
      value = entry.value * 1.0

      case labels do
        "" -> "#{name} #{value}\n"
        _ -> "#{name}{#{labels}} #{value}\n"
      end
    end)
  end

  defp metric_name(type, name), do: "raxol.#{type}.#{name}"

  # Metric names allow [a-zA-Z_:][a-zA-Z0-9_:]*.
  defp prometheus_name(name) do
    to_string(name)
    |> String.replace(~r/[^a-zA-Z0-9_:]/, "_")
    |> prefix_if_leading_digit()
  end

  # Label names are STRICTER than metric names: no colon, no leading digit
  # ([a-zA-Z_][a-zA-Z0-9_]*). A label name in metric-name charset gets the
  # whole push rejected by the gateway.
  defp prometheus_label_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> prefix_if_leading_digit()
  end

  defp prefix_if_leading_digit(<<digit, _::binary>> = name)
       when digit in ?0..?9,
       do: "_" <> name

  defp prefix_if_leading_digit(name), do: name

  # Label VALUES are quoted strings in the exposition format; backslash,
  # double quote, and newline must be escaped or a hostile value injects
  # arbitrary samples into the push body.
  defp escape_label_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  # Tags are normalized ONCE at ingestion into a sorted list of
  # {string_key, string_value} pairs: formatters can never crash on a tag
  # term, duplicate keys collapse (last wins), and the canonical order
  # makes grouping/dedupe stable under caller tag reordering. A non-list
  # tags argument becomes [].
  defp normalize_tags(tags) when is_list(tags) do
    tags |> Enum.map(&tag_pair/1) |> Map.new() |> Enum.sort()
  end

  defp normalize_tags(_tags), do: []

  # A tag is either a bare flag (`:slow`) or a `{key, value}` pair. Terms
  # without a String.Chars implementation are inspected rather than
  # crashing the export.
  defp tag_pair({key, value}), do: {safe_string(key), safe_string(value)}
  defp tag_pair(tag), do: {safe_string(tag), "true"}

  defp safe_string(term) when is_binary(term), do: term

  defp safe_string(term) when is_atom(term) or is_number(term),
    do: to_string(term)

  defp safe_string(term), do: inspect(term)

  # -- Config validation ---------------------------------------------------------

  # Validates a COMPLETE config map (defaults or current config merged with
  # changes) -- callers do the merge, so validation always judges the
  # configuration that would actually apply.
  defp validate_cloud_config(config) do
    with :ok <- validate_service(config.service),
         :ok <- validate_endpoint(config.endpoint),
         :ok <- validate_api_key(config.api_key),
         :ok <- validate_batch_size(config.batch_size) do
      validate_flush_interval(config.flush_interval)
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
