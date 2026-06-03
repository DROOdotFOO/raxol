defmodule Raxol.Core.Metrics.AlertManager do
  @moduledoc """
  Alert management system for the Raxol metrics.

  This module handles:
  - Alert rule definition and management
  - Metric threshold monitoring
  - Alert state tracking
  - Alert notifications
  - Alert history
  """

  alias Raxol.Core.Metrics.{Aggregator, MetricsCollector}
  alias Raxol.Core.Runtime.Log
  use Raxol.Core.Behaviours.BaseManager

  @type alert_condition :: :above | :below | :equals | :not_equals
  @type alert_severity :: :info | :warning | :error | :critical
  @type alert_rule :: %{
          name: String.t(),
          description: String.t(),
          metric_name: String.t(),
          condition: alert_condition(),
          threshold: number(),
          severity: alert_severity(),
          tags: map(),
          group_by: [String.t()],
          # seconds
          cooldown: pos_integer(),
          notification_channels: [String.t()]
        }

  @default_options %{
    # 1 minute in seconds
    check_interval: 60,
    history_size: Raxol.Core.Defaults.history_limit(),
    # 5 minutes in seconds
    default_cooldown: 300,
    default_severity: :warning
  }

  # Helper function to get the process name
  defp process_name(pid) when is_pid(pid), do: pid
  defp process_name(name) when is_atom(name), do: name
  defp process_name(_), do: __MODULE__

  # BaseManager provides start_link/1 which handles GenServer initialization
  # Usage: Raxol.Core.Metrics.AlertManager.start_link(name: __MODULE__, ...)

  @doc """
  Adds a new alert rule.
  """
  def add_rule(rule, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:add_rule, rule})
  end

  @doc """
  Gets all alert rules.
  """
  def get_rules(process \\ __MODULE__) do
    GenServer.call(process_name(process), :get_rules)
  end

  @doc """
  Gets the current alert state for a rule.
  """
  def get_alert_state(rule_id, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:get_alert_state, rule_id})
  end

  @doc """
  Gets the alert history.
  """
  def get_alert_history(rule_id, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:get_alert_history, rule_id})
  end

  @doc """
  Acknowledges an alert.
  """
  def acknowledge_alert(rule_id, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:acknowledge_alert, rule_id})
  end

  @doc """
  Stops the alert manager.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(process_name(pid))
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %{
      rules: %{},
      next_rule_id: 1,
      alert_states: %{},
      alert_history: %{},
      options: Map.merge(@default_options, Map.new(opts))
    }

    schedule_check()
    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:add_rule, rule}, _from, state) do
    rule_id = state.next_rule_id
    validated_rule = validate_rule(rule)

    new_state = %{
      state
      | rules: Map.put(state.rules, rule_id, validated_rule),
        alert_states:
          Map.put(state.alert_states, rule_id, %{
            active: false,
            last_triggered: nil,
            acknowledged: false,
            current_value: nil
          }),
        alert_history: Map.put(state.alert_history, rule_id, []),
        next_rule_id: rule_id + 1
    }

    {:reply, {:ok, rule_id}, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_rules, _from, state) do
    {:reply, {:ok, state.rules}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_alert_state, rule_id}, _from, state) do
    case Map.get(state.alert_states, rule_id) do
      nil -> {:reply, {:error, :rule_not_found}, state}
      alert_state -> {:reply, {:ok, alert_state}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_alert_history, rule_id}, _from, state) do
    case Map.get(state.alert_history, rule_id) do
      nil -> {:reply, {:error, :rule_not_found}, state}
      history -> {:reply, {:ok, history}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:acknowledge_alert, rule_id}, _from, state) do
    case Map.get(state.alert_states, rule_id) do
      nil ->
        {:reply, {:error, :rule_not_found}, state}

      alert_state ->
        new_alert_state = %{alert_state | acknowledged: true}

        new_state = %{
          state
          | alert_states: Map.put(state.alert_states, rule_id, new_alert_state)
        }

        {:reply, {:ok, new_alert_state}, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:check_alerts, _timer_id}, state) do
    new_state = check_all_alerts(state)
    schedule_check()
    {:noreply, new_state}
  end

  @spec validate_rule(map()) :: %{
          name: String.t(),
          description: String.t(),
          metric_name: any(),
          condition: atom(),
          threshold: any(),
          severity: atom(),
          tags: map(),
          group_by: list(),
          cooldown: integer(),
          notification_channels: list()
        }
  defp validate_rule(rule) do
    %{
      name: Map.get(rule, :name, "Unnamed Alert"),
      description: Map.get(rule, :description, ""),
      metric_name: Map.get(rule, :metric_name),
      condition: Map.get(rule, :condition, :above),
      threshold: Map.get(rule, :threshold),
      severity: Map.get(rule, :severity, @default_options.default_severity),
      tags: Map.get(rule, :tags, %{}),
      group_by: Map.get(rule, :group_by, []),
      cooldown: Map.get(rule, :cooldown, @default_options.default_cooldown),
      notification_channels: Map.get(rule, :notification_channels, [])
    }
  end

  defp check_all_alerts(state) do
    Enum.reduce(state.rules, state, fn {rule_id, rule}, acc_state ->
      check_alert(rule_id, rule, acc_state)
    end)
  end

  defp check_alert(rule_id, rule, state) do
    {:ok, metrics} = fetch_metrics_for_rule(rule)
    current_value = resolve_current_value(metrics, rule.group_by)

    {new_alert_state, should_trigger} =
      evaluate_alert(current_value, rule, state.alert_states[rule_id])

    apply_alert_result(
      should_trigger,
      rule_id,
      rule,
      current_value,
      new_alert_state,
      state
    )
  end

  defp fetch_metrics_for_rule(%{group_by: [], metric_name: name, tags: tags}),
    do: MetricsCollector.get_metrics(name, tags)

  defp fetch_metrics_for_rule(%{metric_name: name}),
    do: MetricsCollector.get_metrics(name, %{})

  defp resolve_current_value(metrics, []), do: get_single_value(metrics)

  defp resolve_current_value(metrics, group_by) do
    case get_grouped_values(metrics, group_by) do
      [] -> nil
      values -> extract_and_get_max_value(values)
    end
  end

  defp apply_alert_result(
         true,
         rule_id,
         rule,
         current_value,
         _alert_state,
         state
       ),
       do: trigger_alert(rule_id, rule, current_value, state)

  defp apply_alert_result(
         false,
         rule_id,
         _rule,
         _current_value,
         new_alert_state,
         state
       ),
       do: %{
         state
         | alert_states: Map.put(state.alert_states, rule_id, new_alert_state)
       }

  defp get_single_value(metrics) do
    case List.first(metrics) do
      nil -> nil
      metric -> Map.get(metric, :value)
    end
  end

  defp get_grouped_values(metrics, group_by) do
    metrics
    |> Enum.group_by(fn metric ->
      Enum.map_join(group_by, ":", fn key ->
        Map.get(metric.tags, key) || lookup_atom_tag(metric.tags, key)
      end)
    end)
    |> Enum.map(fn {group, group_metrics} ->
      values = Enum.map(group_metrics, & &1.value)
      {group, Aggregator.calculate_aggregation(values, :mean)}
    end)
  end

  # Looks up tags by atom key when given a string key. Uses
  # String.to_existing_atom so external telemetry sources can't mint new
  # atoms; unknown keys resolve to nil and fall through to the next branch.
  defp lookup_atom_tag(tags, key) when is_binary(key) do
    Map.get(tags, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp lookup_atom_tag(_tags, _key), do: nil

  defp evaluate_alert(current_value, rule, alert_state) do
    now = DateTime.utc_now()

    in_cooldown =
      in_cooldown?(alert_state.last_triggered, rule.cooldown, now)

    should_trigger =
      evaluate_condition(rule.condition, current_value, rule.threshold)

    new_alert_state = %{
      alert_state
      | current_value: current_value,
        active: should_trigger and not in_cooldown
    }

    {new_alert_state, should_trigger and not in_cooldown}
  end

  defp in_cooldown?(last_triggered, cooldown, now) do
    case last_triggered do
      nil -> false
      triggered -> DateTime.diff(now, triggered) < cooldown
    end
  end

  defp evaluate_condition(condition, value, threshold) do
    case {condition, value, threshold} do
      {_, nil, _} -> false
      {:above, val, thresh} when val > thresh -> true
      {:below, val, thresh} when val < thresh -> true
      {:equals, val, thresh} when val == thresh -> true
      {:not_equals, val, thresh} when val != thresh -> true
      _ -> false
    end
  end

  defp trigger_alert(rule_id, rule, current_value, state) do
    now = DateTime.utc_now()

    alert = %{
      rule_id: rule_id,
      rule_name: rule.name,
      severity: rule.severity,
      current_value: current_value,
      threshold: rule.threshold,
      condition: rule.condition,
      triggered_at: now,
      acknowledged: false
    }

    # Update alert state
    new_alert_state = %{
      active: true,
      last_triggered: now,
      acknowledged: false,
      current_value: current_value
    }

    # Add to history
    history = [alert | state.alert_history[rule_id]]
    history = Enum.take(history, state.options.history_size)

    # Send notifications
    send_notifications(alert, rule.notification_channels)

    %{
      state
      | alert_states: Map.put(state.alert_states, rule_id, new_alert_state),
        alert_history: Map.put(state.alert_history, rule_id, history)
    }
  end

  defp send_notifications(alert, channels) do
    Enum.each(channels, fn channel ->
      case channel do
        "email" -> send_email_notification(alert)
        "slack" -> send_slack_notification(alert)
        "webhook" -> send_webhook_notification(alert)
        _ -> :ok
      end
    end)
  end

  defp send_email_notification(alert) do
    Raxol.Core.Runtime.Log.info(
      "Alert: #{alert.rule_name} - #{alert.severity} threshold exceeded",
      %{
        rule_id: alert.rule_id,
        current_value: alert.current_value,
        threshold: alert.threshold,
        condition: alert.condition,
        channel: "email"
      }
    )
  end

  defp send_slack_notification(alert) do
    Raxol.Core.Runtime.Log.info(
      "Alert: #{alert.rule_name} - #{alert.severity} threshold exceeded",
      %{
        rule_id: alert.rule_id,
        current_value: alert.current_value,
        threshold: alert.threshold,
        condition: alert.condition,
        channel: "slack"
      }
    )
  end

  defp send_webhook_notification(alert) do
    Raxol.Core.Runtime.Log.info(
      "Alert: #{alert.rule_name} - #{alert.severity} threshold exceeded",
      %{
        rule_id: alert.rule_id,
        current_value: alert.current_value,
        threshold: alert.threshold,
        condition: alert.condition,
        channel: "webhook"
      }
    )
  end

  defp schedule_check do
    timer_id = System.unique_integer([:positive])

    Process.send_after(
      self(),
      {:check_alerts, timer_id},
      @default_options.check_interval * 1000
    )
  end

  defp extract_and_get_max_value(values) do
    metric_values = values |> Enum.map(fn {_, v} -> v end)
    get_max_metric_value(metric_values)
  end

  defp get_max_metric_value(metric_values) do
    case metric_values do
      [] -> nil
      vals -> Enum.max(vals)
    end
  end
end
