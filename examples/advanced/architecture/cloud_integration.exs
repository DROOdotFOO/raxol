# Cloud Integration Demo
#
# Demonstrates a hypothetical cloud status dashboard using the TEA pattern.
# Shows how you might structure an app that polls multiple service endpoints
# and displays their status in a terminal dashboard.
#
# Usage:
#   mix run examples/advanced/architecture/cloud_integration.exs

defmodule CloudIntegrationDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @services [
    %{name: "API Gateway", region: "us-east-1", port: 443},
    %{name: "Auth Service", region: "us-east-1", port: 8080},
    %{name: "Database", region: "us-west-2", port: 5432},
    %{name: "Cache (Redis)", region: "us-west-2", port: 6379},
    %{name: "Message Queue", region: "eu-west-1", port: 5672},
    %{name: "Object Store", region: "eu-west-1", port: 9000}
  ]

  @impl true
  def init(_context) do
    %{
      services: Enum.map(@services, &Map.put(&1, :status, :unknown)),
      tick: 0,
      selected: 0,
      last_check: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        services =
          Enum.map(model.services, fn svc ->
            # Simulate random health check results
            status =
              case :rand.uniform(10) do
                n when n <= 7 -> :healthy
                n when n <= 9 -> :degraded
                _ -> :down
              end

            latency = :rand.uniform(200) + 5

            svc
            |> Map.put(:status, status)
            |> Map.put(:latency, latency)
          end)

        {%{
           model
           | services: services,
             tick: model.tick + 1,
             last_check: DateTime.utc_now()
         }, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        {%{model | selected: max(0, model.selected - 1)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        max_idx = length(model.services) - 1
        {%{model | selected: min(model.selected + 1, max_idx)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    healthy = Enum.count(model.services, &(&1.status == :healthy))
    total = length(model.services)

    column style: %{padding: 1, gap: 1} do
      [
        text("Cloud Service Dashboard", style: [:bold]),
        text(
          "Health: #{healthy}/#{total} services healthy  |  " <>
            "Check ##{model.tick}  |  " <>
            "Last: #{format_time(model.last_check)}"
        ),
        box title: "Services", style: %{border: :single, padding: 1} do
          column do
            header =
              text(
                String.pad_trailing("Service", 20) <>
                  String.pad_trailing("Region", 14) <>
                  String.pad_trailing("Status", 12) <>
                  "Latency",
                style: [:bold]
              )

            rows =
              model.services
              |> Enum.with_index()
              |> Enum.map(fn {svc, idx} ->
                prefix = if idx == model.selected, do: "> ", else: "  "
                sty = if idx == model.selected, do: [:bold], else: []

                status_str =
                  case svc.status do
                    :healthy -> "[OK]"
                    :degraded -> "[WARN]"
                    :down -> "[DOWN]"
                    :unknown -> "[?]"
                  end

                latency_str =
                  case Map.get(svc, :latency) do
                    nil -> "—"
                    ms -> "#{ms}ms"
                  end

                text(
                  prefix <>
                    String.pad_trailing(svc.name, 18) <>
                    String.pad_trailing(svc.region, 14) <>
                    String.pad_trailing(status_str, 12) <>
                    latency_str,
                  style: sty
                )
              end)

            [header | rows]
          end
        end,
        text("Up/Down: select  |  q: quit")
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(2000, :tick)]
  end

  defp format_time(nil), do: "—"

  defp format_time(dt) do
    "#{dt.hour}:#{String.pad_leading("#{dt.minute}", 2, "0")}:" <>
      String.pad_leading("#{dt.second}", 2, "0")
  end
end

Raxol.Core.Runtime.Log.info("CloudIntegrationDemo: Starting...")
{:ok, pid} = Raxol.start_link(CloudIntegrationDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
