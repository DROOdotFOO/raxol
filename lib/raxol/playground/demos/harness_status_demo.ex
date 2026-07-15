defmodule Raxol.Playground.Demos.HarnessStatusDemo do
  @moduledoc """
  Playground demo: harness status bar, context/spend meters, activity
  indicator, advisory feed, drift indicator, and a toast -- the
  status/observability surface of an agent harness (`docs/proposals/in-flight/harness-spec-frontend.md`).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.{
    ActivityIndicator,
    AdvisoryFeed,
    ContextMeter,
    DriftIndicator,
    SpendMeter,
    StatusBar,
    Toast
  }

  @tick_interval_ms 500
  @context_total 16_000
  @context_step 400
  @spend_cap 5.0
  @spend_step 0.03
  @drift_step 3
  @toast_every_ticks 10
  @toast_ttl_ms 3_000

  @advisory_entries [
    %{
      source: "probe:lint",
      kind: :verdict,
      text: "no unused aliases",
      score: 0.98
    },
    %{
      source: "probe:research",
      kind: :research,
      text: "similar fix landed in #521",
      score: 0.72
    },
    %{
      source: "gate:acp",
      kind: :gate_decision,
      text: "launch liquidity gate: pass",
      score: nil
    }
  ]

  @impl true
  def init(_context) do
    %{
      tick: 0,
      turn_state: :working,
      activity_state: :working,
      since_ms: 0,
      context_used: 500,
      cost: 0.12,
      drift_score: 8,
      toast: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("w") ->
        {%{model | turn_state: :working, activity_state: :working, since_ms: 0},
         []}

      key_match("i") ->
        {%{model | turn_state: :idle, activity_state: :idle, since_ms: 0}, []}

      key_match("h") ->
        {%{model | activity_state: :working, since_ms: 12_000}, []}

      :tick ->
        {tick(model), []}

      _ ->
        {model, []}
    end
  end

  defp tick(model) do
    model
    |> Map.update!(:tick, &(&1 + 1))
    |> Map.update!(:since_ms, &(&1 + @tick_interval_ms))
    |> advance_context()
    |> advance_cost()
    |> advance_drift()
    |> advance_toast()
  end

  defp advance_context(model) do
    %{
      model
      | context_used:
          rem(model.context_used + @context_step, @context_total + 1)
    }
  end

  defp advance_cost(model), do: %{model | cost: model.cost + @spend_step}

  defp advance_drift(model) do
    %{model | drift_score: rem(model.drift_score + @drift_step, 101)}
  end

  defp advance_toast(%{tick: tick} = model)
       when rem(tick, @toast_every_ticks) == 0 do
    %{
      model
      | toast: %{
          message: "Checkpoint saved",
          level: :info,
          shown_at_tick: tick
        }
    }
  end

  defp advance_toast(%{toast: %{shown_at_tick: shown_at}, tick: tick} = model) do
    if (tick - shown_at) * @tick_interval_ms >= @toast_ttl_ms do
      %{model | toast: nil}
    else
      model
    end
  end

  defp advance_toast(model), do: model

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Status Demo", style: [:bold]),
        divider(),
        harness_status_bar(model),
        context_meter(model),
        spend_meter(model),
        activity_row(model),
        divider(),
        advisory_feed(),
        divider(),
        drift_indicator(model),
        toast_row(model),
        text("[w] working  [i] idle  [h] simulate hung", style: [:dim])
      ]
    end
  end

  defp harness_status_bar(model) do
    {:ok, state} =
      StatusBar.init(
        id: :harness_status_bar,
        model: "claude-opus-4-6",
        turn_state: model.turn_state,
        context_pct: model.context_used / @context_total * 100,
        cost: model.cost
      )

    StatusBar.render(state, %{})
  end

  defp context_meter(model) do
    {:ok, state} =
      ContextMeter.init(
        id: :context_meter,
        used: model.context_used,
        total: @context_total,
        width: 24
      )

    ContextMeter.render(state, %{})
  end

  defp spend_meter(model) do
    {:ok, state} =
      SpendMeter.init(
        id: :spend_meter,
        spent: model.cost,
        cap: @spend_cap,
        width: 24
      )

    SpendMeter.render(state, %{})
  end

  defp activity_row(model) do
    {:ok, state} =
      ActivityIndicator.init(
        id: :activity_indicator,
        state: model.activity_state,
        since_ms: model.since_ms,
        frame: model.tick
      )

    ActivityIndicator.render(state, %{})
  end

  defp advisory_feed do
    {:ok, state} =
      AdvisoryFeed.init(id: :advisory_feed, entries: @advisory_entries)

    AdvisoryFeed.render(state, %{})
  end

  defp drift_indicator(model) do
    {:ok, state} =
      DriftIndicator.init(
        id: :drift_indicator,
        score: model.drift_score,
        family: "claude-opus",
        width: 24
      )

    DriftIndicator.render(state, %{})
  end

  defp toast_row(%{toast: nil}), do: text("")

  defp toast_row(%{toast: toast}) do
    {:ok, state} =
      Toast.init(id: :toast, message: toast.message, level: toast.level)

    Toast.render(state, %{})
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end
end
