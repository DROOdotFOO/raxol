defmodule Raxol.Core.Metrics.Visualizer do
  @moduledoc """
  Visualization system for the Raxol metrics.

  This module handles:
  - Real-time metric visualization
  - Metric data formatting
  - Chart generation
  - Dashboard rendering
  - Export capabilities
  """

  use Raxol.Core.Behaviours.BaseManager

  @type chart_type :: :line | :bar | :gauge | :histogram
  @type chart_options :: %{
          type: chart_type(),
          title: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          color: String.t(),
          show_legend: boolean(),
          show_grid: boolean(),
          time_range: {DateTime.t(), DateTime.t()}
        }

  @default_options %{
    type: :line,
    title: "Metrics Visualization",
    width: 800,
    height: 400,
    color: "#4A90E2",
    show_legend: true,
    show_grid: true,
    time_range: nil
  }

  @doc """
  Creates a new chart with the given metrics and options.
  """
  def create_chart(metrics, options \\ %{}) do
    GenServer.call(__MODULE__, {:create_chart, metrics, options})
  end

  @doc """
  Creates a new chart with the given metrics, data, and options.
  """
  def create_chart(metrics, data, options) do
    # Combine metrics and data for the chart
    combined_metrics = Map.merge(metrics, %{data: data})
    create_chart(combined_metrics, options)
  end

  @doc """
  Updates an existing chart with new metrics.
  """
  def update_chart(chart_id, metrics) do
    GenServer.call(__MODULE__, {:update_chart, chart_id, metrics})
  end

  @doc """
  Gets the current chart data.
  """
  def get_chart(chart_id) do
    GenServer.call(__MODULE__, {:get_chart, chart_id})
  end

  @doc """
  Exports chart data in the specified format.
  """
  def export_chart(chart_id, format) when format in [:json, :csv] do
    GenServer.call(__MODULE__, {:export_chart, chart_id, format})
  end

  @doc """
  Stops the metrics visualizer.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %{
      charts: %{},
      next_chart_id: 1,
      options: Map.merge(@default_options, Map.new(opts))
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:create_chart, metrics, options}, _from, state) do
    chart_id = state.next_chart_id
    chart_options = Map.merge(state.options, options)
    chart_data = prepare_chart_data(metrics, chart_options)

    new_state = %{
      state
      | charts:
          Map.put(state.charts, chart_id, %{
            data: chart_data,
            options: chart_options,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }),
        next_chart_id: chart_id + 1
    }

    {:reply, {:ok, chart_id, chart_data}, new_state}
  end

  @impl GenServer
  def handle_call({:update_chart, chart_id, metrics}, _from, state) do
    case Map.get(state.charts, chart_id) do
      nil ->
        {:reply, {:error, :chart_not_found}, state}

      chart ->
        chart_options = chart.options
        chart_data = prepare_chart_data(metrics, chart_options)

        new_state = %{
          state
          | charts:
              Map.put(state.charts, chart_id, %{
                chart
                | data: chart_data,
                  updated_at: DateTime.utc_now()
              })
        }

        {:reply, {:ok, chart_data}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:get_chart, chart_id}, _from, state) do
    case Map.get(state.charts, chart_id) do
      nil -> {:reply, {:error, :chart_not_found}, state}
      chart -> {:reply, {:ok, chart}, state}
    end
  end

  @impl GenServer
  def handle_call({:export_chart, chart_id, format}, _from, state) do
    case Map.get(state.charts, chart_id) do
      nil ->
        {:reply, {:error, :chart_not_found}, state}

      chart ->
        export_data = export_chart_data(chart, format)
        {:reply, {:ok, export_data}, state}
    end
  end

  defp prepare_chart_data(metrics, options) do
    case options.type do
      :line -> prepare_line_chart(metrics, options)
      :bar -> prepare_bar_chart(metrics, options)
      :gauge -> prepare_gauge_chart(metrics, options)
      :histogram -> prepare_histogram_chart(metrics, options)
    end
  end

  defp prepare_line_chart(metrics, options) do
    %{
      type: "line",
      data: %{
        labels: get_time_labels(metrics, options),
        datasets: [
          %{
            label: options.title,
            data: get_filtered_metric_values(metrics, options),
            borderColor: options.color,
            fill: false,
            tension: 0.4
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{
          legend: %{display: options.show_legend},
          title: %{display: true, text: options.title}
        },
        scales: %{
          x: %{
            type: "time",
            time: %{unit: "minute"},
            grid: %{display: options.show_grid}
          },
          y: %{
            beginAtZero: true,
            grid: %{display: options.show_grid}
          }
        }
      }
    }
  end

  defp prepare_bar_chart(metrics, options) do
    %{
      type: "bar",
      data: %{
        labels: get_time_labels(metrics, options),
        datasets: [
          %{
            label: options.title,
            data: get_filtered_metric_values(metrics, options),
            backgroundColor: options.color,
            borderColor: options.color,
            borderWidth: 1
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{
          legend: %{display: options.show_legend},
          title: %{display: true, text: options.title}
        },
        scales: %{
          x: %{
            grid: %{display: options.show_grid}
          },
          y: %{
            beginAtZero: true,
            grid: %{display: options.show_grid}
          }
        }
      }
    }
  end

  defp prepare_gauge_chart(metrics, options) do
    value = get_latest_metric_value(metrics)
    max_value = get_max_metric_value(metrics)

    %{
      type: "gauge",
      data: %{
        datasets: [
          %{
            value: value,
            data: [0, max_value],
            backgroundColor: [options.color, "#E0E0E0"],
            borderWidth: 0
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{
          title: %{display: true, text: options.title}
        },
        needle: %{
          radiusPercentage: 2,
          widthPercentage: 3.2,
          lengthPercentage: 80,
          color: "rgba(0, 0, 0, 1)"
        },
        valueLabel: %{
          display: true,
          formatter: &format_gauge_value/1,
          color: "rgba(0, 0, 0, 1)",
          backgroundColor: "rgba(0, 0, 0, 0)",
          borderRadius: 5,
          padding: %{top: 10, bottom: 10}
        }
      }
    }
  end

  defp prepare_histogram_chart(metrics, options) do
    values = get_metric_values(metrics)
    buckets = calculate_histogram_buckets(values)

    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, &format_bucket_label/1),
        datasets: [
          %{
            label: options.title,
            data: Enum.map(buckets, & &1.count),
            backgroundColor: options.color,
            borderColor: options.color,
            borderWidth: 1
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{
          legend: %{display: options.show_legend},
          title: %{display: true, text: options.title}
        },
        scales: %{
          x: %{
            grid: %{display: options.show_grid}
          },
          y: %{
            beginAtZero: true,
            grid: %{display: options.show_grid}
          }
        }
      }
    }
  end

  defp get_time_labels(metrics, options) do
    filtered_metrics = filter_metrics_by_time_range(metrics, options.time_range)

    filtered_metrics
    |> Enum.map(& &1.timestamp)
    |> Enum.map(&DateTime.from_unix!(&1, :millisecond))
    |> Enum.map(&format_time_label/1)
  end

  defp get_metric_values(metrics) do
    metrics
    |> Enum.map(& &1.value)
  end

  defp get_filtered_metric_values(metrics, options) do
    filtered_metrics = filter_metrics_by_time_range(metrics, options.time_range)
    get_metric_values(filtered_metrics)
  end

  defp get_latest_metric_value(metrics) do
    metrics
    |> List.first()
    |> Map.get(:value, 0)
  end

  defp get_max_metric_value(metrics) do
    metrics
    |> Enum.map(& &1.value)
    |> Enum.max(fn -> 100 end)
  end

  defp calculate_histogram_buckets(values) do
    min = Enum.min(values, fn -> 0 end)
    max = Enum.max(values, fn -> 100 end)
    bucket_size = (max - min) / 10

    0..9
    |> Enum.map(fn i ->
      bucket_start = min + i * bucket_size
      bucket_end = bucket_start + bucket_size
      count = Enum.count(values, &(&1 >= bucket_start and &1 < bucket_end))
      %{start: bucket_start, end: bucket_end, count: count}
    end)
  end

  @spec filter_metrics_by_time_range(
          Enumerable.t(),
          nil | {DateTime.t(), DateTime.t()}
        ) :: Enumerable.t()
  defp filter_metrics_by_time_range(metrics, nil), do: metrics

  defp filter_metrics_by_time_range(metrics, {start, end_}) do
    # Log.info("DEBUG: Filtering metrics with time range: #{start} to #{end_}")
    # Log.info("DEBUG: Total metrics before filtering: #{length(metrics)}")

    filtered =
      Enum.filter(metrics, fn metric ->
        timestamp = DateTime.from_unix!(metric.timestamp, :millisecond)

        result =
          DateTime.compare(timestamp, start) != :lt and
            DateTime.compare(timestamp, end_) != :gt

        # Log.info(
        #   "DEBUG: Metric timestamp: #{timestamp}, value: #{metric.value}, included: #{result}"
        # )

        result
      end)

    # Log.info("DEBUG: Total metrics after filtering: #{length(filtered)}")
    filtered
  end

  defp format_time_label(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_bucket_label(%{start: start, end: end_}) do
    "#{Float.round(start, 2)} - #{Float.round(end_, 2)}"
  end

  defp format_gauge_value(value) do
    Float.round(value, 2)
  end

  @spec export_chart_data(map(), :json | :csv) :: String.t()
  defp export_chart_data(chart, :json), do: Jason.encode!(chart)
  defp export_chart_data(chart, :csv), do: export_to_csv(chart)

  defp export_to_csv(chart) do
    headers = ["Timestamp", "Value"]

    # Extract data from the chart structure
    # The chart has {data: chart_data, options: ..., created_at: ..., updated_at: ...}
    # where chart_data has {data: %{labels: [...], datasets: [...]}, options: ..., type: ...}
    labels = chart.data.data.labels
    values = chart.data.data.datasets |> List.first() |> Map.get(:data)

    rows =
      Enum.zip(labels, values)
      |> Enum.map(fn {label, value} ->
        [label, to_string(value)]
      end)

    [headers | rows]
    |> Enum.map_join("\n", &Enum.join(&1, ","))
  end
end
