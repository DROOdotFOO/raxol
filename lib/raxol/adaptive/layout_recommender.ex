defmodule Raxol.Adaptive.LayoutRecommender do
  @moduledoc """
  Rule-based layout recommendation engine.

  Subscribes to BehaviorTracker aggregates and applies heuristic
  rules to suggest layout changes. Emits recommendations to
  subscribers when confidence exceeds threshold and cooldown
  has elapsed.

  Cold start design: pure rule-based. No Nx dependency.
  Swap in an Nx model later by replacing `apply_rules/1`.
  """

  use GenServer

  @compile {:no_warn_undefined, Raxol.Adaptive.NxModel}

  alias Raxol.Adaptive.TrendDetector

  require Logger

  @default_confidence_threshold 0.7
  @default_cooldown_ms 30_000

  @type change :: %{
          pane_id: atom(),
          action: :hide | :show | :expand | :shrink,
          params: map()
        }

  @type recommendation :: %{
          id: binary(),
          layout_changes: [change()],
          confidence: float(),
          reasoning: String.t(),
          timestamp: integer()
        }

  @default_override_suppress_windows 3

  @type context :: %{
          terminal_width: pos_integer(),
          terminal_height: pos_integer(),
          visible_pane_count: non_neg_integer(),
          hidden_panes: [atom()]
        }

  @type t :: %__MODULE__{
          confidence_threshold: float(),
          recommendation_cooldown_ms: pos_integer(),
          last_recommendation_at: integer() | nil,
          last_recommendation: recommendation() | nil,
          subscribers: MapSet.t(pid()),
          pane_ids: [atom()],
          model_params: map() | nil,
          suppress_remaining: non_neg_integer(),
          context: context() | nil,
          tracker_server: GenServer.server() | nil
        }

  defstruct confidence_threshold: @default_confidence_threshold,
            recommendation_cooldown_ms: @default_cooldown_ms,
            last_recommendation_at: nil,
            last_recommendation: nil,
            subscribers: MapSet.new(),
            pane_ids: [],
            model_params: nil,
            suppress_remaining: 0,
            context: nil,
            tracker_server: nil

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_last_recommendation(GenServer.server()) :: recommendation() | nil
  def get_last_recommendation(server \\ __MODULE__) do
    GenServer.call(server, :get_last_recommendation)
  end

  @spec set_pane_ids(GenServer.server(), [atom()]) :: :ok
  def set_pane_ids(server \\ __MODULE__, pane_ids) do
    GenServer.cast(server, {:set_pane_ids, pane_ids})
  end

  @spec set_model_params(GenServer.server(), map()) :: :ok
  def set_model_params(server \\ __MODULE__, params) do
    GenServer.cast(server, {:set_model_params, params})
  end

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @spec set_context(GenServer.server(), context()) :: :ok
  def set_context(server \\ __MODULE__, context) do
    GenServer.cast(server, {:set_context, context})
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      confidence_threshold:
        Keyword.get(opts, :confidence_threshold, @default_confidence_threshold),
      recommendation_cooldown_ms:
        Keyword.get(opts, :recommendation_cooldown_ms, @default_cooldown_ms),
      pane_ids: Keyword.get(opts, :pane_ids, [])
    }

    case Keyword.get(opts, :subscribe_to) do
      nil -> {:ok, state}
      target -> {:ok, state, {:continue, {:subscribe_to, target}}}
    end
  end

  @impl true
  def handle_continue({:subscribe_to, target}, %__MODULE__{} = state) do
    Raxol.Adaptive.BehaviorTracker.subscribe(target)
    {:noreply, %__MODULE__{state | tracker_server: target}}
  end

  @impl true
  def handle_call(:get_last_recommendation, _from, %__MODULE__{} = state) do
    {:reply, state.last_recommendation, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)

    {:reply, :ok,
     %__MODULE__{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:set_pane_ids, pane_ids}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | pane_ids: pane_ids}}
  end

  @impl true
  def handle_cast({:set_model_params, params}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | model_params: params}}
  end

  @impl true
  def handle_cast({:set_context, context}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | context: context}}
  end

  @impl true
  def handle_info({:behavior_aggregate, aggregate}, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    # Check if user manual overrides should suppress recommendations
    override_count = Map.get(aggregate, :layout_override_count, 0)

    state =
      if override_count > 2 do
        %__MODULE__{
          state
          | suppress_remaining: @default_override_suppress_windows
        }
      else
        state
      end

    cond do
      state.suppress_remaining > 0 ->
        {:noreply,
         %__MODULE__{state | suppress_remaining: state.suppress_remaining - 1}}

      on_cooldown?(state, now) ->
        {:noreply, state}

      true ->
        handle_behavior_aggregate(aggregate, state, now)
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply,
     %__MODULE__{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(msg, %__MODULE__{} = state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: Behavior Aggregate Processing --

  defp handle_behavior_aggregate(aggregate, %__MODULE__{} = state, now) do
    case apply_rules(aggregate, state) do
      {:recommend, changes, confidence, reasoning}
      when confidence >= state.confidence_threshold ->
        rec =
          %{
            id: generate_id(),
            layout_changes: changes,
            confidence: confidence,
            reasoning: reasoning,
            timestamp: now
          }
          |> maybe_attach_features(aggregate, state)

        notify_subscribers(state.subscribers, rec)

        new_state = %__MODULE__{
          state
          | last_recommendation: rec,
            last_recommendation_at: now
        }

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  defp notify_subscribers(subscribers, rec) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:layout_recommendation, rec})
    end)
  end

  # -- Private: Rules --

  # Internal type for rule candidates before selecting the best one.
  @typep candidate :: %{
           change: change(),
           confidence: float(),
           reasoning: String.t()
         }

  defp apply_rules(aggregate, state) do
    dwell_times = aggregate.pane_dwell_times
    total_dwell = dwell_times |> Map.values() |> Enum.sum()

    if total_dwell == 0 do
      :no_recommendation
    else
      case apply_nx_model(aggregate, state) do
        {:recommend, _, _, _} = result ->
          result

        _ ->
          trends = compute_trends(state.tracker_server)

          apply_rule_heuristics(
            dwell_times,
            total_dwell,
            aggregate,
            state.context,
            trends
          )
      end
    end
  end

  defp apply_nx_model(aggregate, %__MODULE__{
         model_params: params,
         pane_ids: pane_ids
       })
       when not is_nil(params) and pane_ids != [] do
    if Code.ensure_loaded?(Raxol.Adaptive.NxModel) do
      {features, ids} =
        Raxol.Adaptive.NxModel.extract_features(aggregate, pane_ids)

      predictions = Raxol.Adaptive.NxModel.predict(params, features)

      case Raxol.Adaptive.NxModel.interpret_predictions(predictions, ids) do
        [{pane_id, action, confidence} | _] ->
          change = %{
            pane_id: pane_id,
            action: action,
            params: %{source: :nx_model}
          }

          {:recommend, [change], confidence, "Nx model: #{action} #{pane_id}"}

        [] ->
          :no_recommendation
      end
    else
      :no_recommendation
    end
  end

  defp apply_nx_model(_aggregate, _state), do: :no_recommendation

  @max_candidates 3

  defp apply_rule_heuristics(
         dwell_times,
         total_dwell,
         aggregate,
         context,
         trends
       ) do
    case find_best_candidates(
           dwell_times,
           total_dwell,
           aggregate,
           context,
           trends
         ) do
      [] ->
        :no_recommendation

      selected ->
        changes = Enum.map(selected, & &1.change)

        avg_confidence =
          selected
          |> Enum.map(& &1.confidence)
          |> then(fn confs -> Enum.sum(confs) / length(confs) end)

        reasoning =
          Enum.map_join(selected, "; ", & &1.reasoning)

        {:recommend, changes, avg_confidence, reasoning}
    end
  end

  @spec find_best_candidates(
          map(),
          float(),
          map(),
          context() | nil,
          TrendDetector.trends()
        ) ::
          [candidate()]
  defp find_best_candidates(
         dwell_times,
         total_dwell,
         aggregate,
         context,
         trends
       ) do
    candidates =
      hide_candidates(dwell_times, total_dwell) ++
        expand_candidates(dwell_times, total_dwell) ++
        shrink_candidates(dwell_times, total_dwell) ++
        alert_candidates(aggregate) ++
        scroll_candidates(aggregate) ++
        command_candidates(aggregate) ++
        takeover_candidates(aggregate)

    candidates
    |> apply_context_guards(context)
    |> apply_trend_guards(trends)
    |> Enum.sort_by(& &1.confidence, :desc)
    |> select_non_conflicting(@max_candidates)
  end

  defp compute_trends(nil), do: %{}

  defp compute_trends(tracker_server) do
    aggregates =
      Raxol.Adaptive.BehaviorTracker.get_aggregates(tracker_server, 5)

    TrendDetector.compute(aggregates)
  catch
    :exit, _ -> %{}
  end

  defp apply_trend_guards(candidates, trends) when map_size(trends) == 0,
    do: candidates

  defp apply_trend_guards(candidates, trends) do
    Enum.reject(candidates, fn c ->
      # Don't hide a pane whose dwell is trending upward
      c.change.action == :hide and
        TrendDetector.rising?(trends, c.change.pane_id)
    end)
  end

  defp apply_context_guards(candidates, nil), do: candidates

  defp apply_context_guards(candidates, context) do
    visible = context.visible_pane_count
    hidden = context.hidden_panes

    Enum.reject(candidates, fn c ->
      pane_id = c.change.pane_id
      action = c.change.action

      cond do
        # Don't hide if only 2 panes visible
        action == :hide and visible <= 2 -> true
        # Don't show a pane that isn't actually hidden
        action == :show and pane_id not in hidden -> true
        true -> false
      end
    end)
  end

  # Carries the running count rather than calling `length/1` per candidate, and
  # accumulates in reverse: both the count and the append were O(n) inside the
  # fold. `conflicts_with_any?/2` only ever asks "does any", so it does not care
  # which order it sees them in.
  defp select_non_conflicting(candidates, max) do
    candidates
    |> Enum.reduce({[], 0}, fn candidate, {selected, count} = acc ->
      cond do
        count >= max -> acc
        conflicts_with_any?(candidate, selected) -> acc
        true -> {[candidate | selected], count + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp conflicts_with_any?(candidate, selected) do
    pane_id = candidate.change.pane_id
    action = candidate.change.action

    Enum.any?(selected, fn s ->
      s.change.pane_id == pane_id or
        (action in [:expand, :show] and s.change.action in [:hide, :shrink] and
           s.change.pane_id == pane_id) or
        (action in [:hide, :shrink] and s.change.action in [:expand, :show] and
           s.change.pane_id == pane_id)
    end)
  end

  defp hide_candidates(dwell_times, total_dwell) do
    Enum.flat_map(dwell_times, fn {pane_id, dwell} ->
      pct = dwell / total_dwell

      if pct < 0.05 do
        dwell_pct = Float.round(pct * 100, 1)

        [
          %{
            change: %{
              pane_id: pane_id,
              action: :hide,
              params: %{dwell_pct: dwell_pct}
            },
            confidence: 0.8,
            reasoning: "Pane #{pane_id} used <5% of session (#{dwell_pct}%)"
          }
        ]
      else
        []
      end
    end)
  end

  defp expand_candidates(dwell_times, total_dwell) do
    Enum.flat_map(dwell_times, fn {pane_id, dwell} ->
      pct = dwell / total_dwell

      if pct > 0.40 do
        dwell_pct = Float.round(pct * 100, 1)

        [
          %{
            change: %{
              pane_id: pane_id,
              action: :expand,
              params: %{dwell_pct: dwell_pct}
            },
            confidence: 0.85,
            reasoning: "Pane #{pane_id} used >40% of session (#{dwell_pct}%)"
          }
        ]
      else
        []
      end
    end)
  end

  defp alert_candidates(%{
         avg_alert_response_ms: avg_ms,
         least_used_panes: least_used
       })
       when avg_ms > 5000 do
    Enum.map(least_used, fn pane_id ->
      %{
        change: %{
          pane_id: pane_id,
          action: :show,
          params: %{avg_response_ms: Float.round(avg_ms, 0)}
        },
        confidence: 0.9,
        reasoning: "Alert response >5s (#{round(avg_ms)}ms), showing #{pane_id}"
      }
    end)
  end

  defp alert_candidates(_aggregate), do: []

  defp shrink_candidates(dwell_times, total_dwell) do
    has_dominant =
      Enum.any?(dwell_times, fn {_, dwell} -> dwell / total_dwell > 0.40 end)

    if has_dominant do
      Enum.flat_map(dwell_times, fn {pane_id, dwell} ->
        pct = dwell / total_dwell

        if pct >= 0.15 and pct <= 0.25 do
          dwell_pct = Float.round(pct * 100, 1)

          [
            %{
              change: %{
                pane_id: pane_id,
                action: :shrink,
                params: %{dwell_pct: dwell_pct}
              },
              confidence: 0.75,
              reasoning:
                "Pane #{pane_id} at #{dwell_pct}% while another dominates, shrink to give space"
            }
          ]
        else
          []
        end
      end)
    else
      []
    end
  end

  defp scroll_candidates(aggregate) do
    scroll_freq = Map.get(aggregate, :scroll_frequency, %{})
    scroll_vel = Map.get(aggregate, :scroll_velocity, %{})

    if map_size(scroll_freq) == 0 do
      []
    else
      max_freq = scroll_freq |> Map.values() |> Enum.max(fn -> 0 end)
      threshold = max(max_freq * 0.75, 1)

      Enum.flat_map(scroll_freq, fn {pane_id, freq} ->
        vel = Map.get(scroll_vel, pane_id, 0.0)

        if freq >= threshold and vel > 3.0 do
          [
            %{
              change: %{
                pane_id: pane_id,
                action: :expand,
                params: %{scroll_freq: freq, scroll_vel: Float.round(vel, 1)}
              },
              confidence: 0.8,
              reasoning:
                "Pane #{pane_id} scrolled heavily (#{freq}x, avg delta #{Float.round(vel, 1)})"
            }
          ]
        else
          []
        end
      end)
    end
  end

  defp command_candidates(aggregate) do
    concentration = Map.get(aggregate, :command_concentration, %{})
    total_cmds = concentration |> Map.values() |> Enum.sum()

    if total_cmds == 0 do
      []
    else
      Enum.flat_map(concentration, fn {pane_id, count} ->
        pct = count / total_cmds

        if pct > 0.60 do
          cmd_pct = Float.round(pct * 100, 1)

          [
            %{
              change: %{
                pane_id: pane_id,
                action: :expand,
                params: %{command_pct: cmd_pct}
              },
              confidence: 0.7,
              reasoning:
                "Pane #{pane_id} receives #{cmd_pct}% of commands, expand for workflow"
            }
          ]
        else
          []
        end
      end)
    end
  end

  defp takeover_candidates(aggregate) do
    takeover_ms = Map.get(aggregate, :takeover_duration_ms, %{})
    total_ms = takeover_ms |> Map.values() |> Enum.sum()

    if total_ms == 0 do
      []
    else
      Enum.flat_map(takeover_ms, fn {pane_id, duration} ->
        pct = duration / total_ms

        if pct > 0.50 do
          [
            %{
              change: %{
                pane_id: pane_id,
                action: :expand,
                params: %{takeover_pct: Float.round(pct * 100, 1)}
              },
              confidence: 0.85,
              reasoning:
                "Pane #{pane_id} in takeover >50% of window (#{Float.round(pct * 100, 1)}%)"
            }
          ]
        else
          []
        end
      end)
    end
  end

  defp on_cooldown?(%__MODULE__{last_recommendation_at: nil}, _now), do: false

  defp on_cooldown?(%__MODULE__{} = state, now) do
    now - state.last_recommendation_at < state.recommendation_cooldown_ms
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp maybe_attach_features(rec, aggregate, %__MODULE__{pane_ids: pane_ids})
       when pane_ids != [] do
    if Code.ensure_loaded?(Raxol.Adaptive.NxModel) do
      {features, _ids} =
        Raxol.Adaptive.NxModel.extract_features(aggregate, pane_ids)

      Map.put(rec, :features, features)
    else
      rec
    end
  end

  defp maybe_attach_features(rec, _aggregate, _state), do: rec
end
