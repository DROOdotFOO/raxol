# Adaptive UI

The adaptive subsystem watches how you interact with the interface (which panes you focus on, what commands you run, how long you dwell) and suggests layout changes based on patterns. Accept or reject its suggestions, and it gets better over time.

## Architecture

```elixir
BehaviorTracker (records interactions)
    |
    v
LayoutRecommender (produces layout change suggestions)
    |
    v
FeedbackLoop (tracks accept/reject, optional Nx retraining)
```

Three GenServers under `Raxol.Adaptive.Supervisor` (`:one_for_one`). BehaviorTracker feeds windowed aggregates to LayoutRecommender, which emits suggestions. FeedbackLoop records whether you accepted or rejected them, and can retrain an Nx model if available.

## Quick start

```elixir
{:ok, _} = Raxol.Adaptive.Supervisor.start_link()

# Record what the user does
Raxol.Adaptive.BehaviorTracker.record(:pane_focus, %{pane: :logs})
Raxol.Adaptive.BehaviorTracker.record(:command_issued, %{command: :deploy})

# Get notified when the system has a suggestion
Raxol.Adaptive.LayoutRecommender.subscribe()
# Receive: {:layout_recommendation, %{action: :expand, target: :logs, ...}}

# Tell it whether the suggestion was good
Raxol.Adaptive.FeedbackLoop.accept(recommendation_id)
Raxol.Adaptive.FeedbackLoop.reject(recommendation_id)
```

## Behavior tracking

`Raxol.Adaptive.BehaviorTracker` logs timestamped events and computes windowed aggregates: pane dwell times, command frequency, that sort of thing.

```elixir
BehaviorTracker.record(:pane_focus, %{pane: :metrics})
BehaviorTracker.record(:pane_dwell, %{pane: :logs, duration_ms: 5000})
BehaviorTracker.record(:command_issued, %{command: :restart})
BehaviorTracker.record(:scroll_pattern, %{pane: :logs, direction: :down})

aggregates = BehaviorTracker.get_aggregates(5)  # last 5 windows
events = BehaviorTracker.get_recent_events(20)

BehaviorTracker.enable()
BehaviorTracker.disable()

# Real-time aggregate stream
BehaviorTracker.subscribe()
# Receive: {:behavior_aggregate, aggregate}
```

Event types: `:pane_focus`, `:pane_dwell`, `:command_issued`, `:alert_response`, `:scroll_pattern`, `:takeover_start`, `:takeover_end`, `:layout_override`.

## Layout recommendations

`Raxol.Adaptive.LayoutRecommender` looks at behavior aggregates and suggests layout changes. Uses rule-based logic by default, with optional Nx model support for learned recommendations.

```elixir
rec = LayoutRecommender.get_last_recommendation()
# => %{action: :expand, target: :logs, confidence: 0.85, ...}

LayoutRecommender.subscribe()
# Receive: {:layout_recommendation, recommendation}

# Nx model support (optional)
LayoutRecommender.set_pane_ids([:metrics, :logs, :alerts])
LayoutRecommender.set_model_params(trained_params)
```

Actions it can recommend: `:hide`, `:show`, `:expand`, `:shrink`.

## Feedback loop

`Raxol.Adaptive.FeedbackLoop` keeps a sliding window of accept/reject decisions so you can track how well the recommendations are doing.

```elixir
FeedbackLoop.submit_recommendation(recommendation)

FeedbackLoop.accept(recommendation_id)
FeedbackLoop.reject(recommendation_id)

accuracy = FeedbackLoop.get_accuracy()  # 0.0 - 1.0
history = FeedbackLoop.get_history(20)

# Retrain if Nx is available
{:ok, :trained, params} = FeedbackLoop.force_retrain()
# Without Nx:
{:ok, :rule_based_mode} = FeedbackLoop.force_retrain()
```

## Layout transitions

`Raxol.Adaptive.LayoutTransition` animates between layouts with easing. Pure functions, no GenServer. Call `tick/2` each frame.

```elixir
alias Raxol.Adaptive.LayoutTransition

transition = LayoutTransition.start(
  %{logs: %{height: 10}, metrics: %{height: 20}},   # from
  %{logs: %{height: 20}, metrics: %{height: 10}},   # to
  duration_ms: 300,
  easing: :ease_in_out
)

# Each frame:
case LayoutTransition.tick(transition, elapsed_ms) do
  {:in_progress, layout, transition} -> render(layout)
  {:done, final_layout} -> render(final_layout)
end

# Bail out mid-transition
current_layout = LayoutTransition.cancel(transition)
```

Easing: `:linear`, `:ease_in_out`, `:ease_out`.

## Example

```bash
mix run examples/subsystems/adaptive_ui_demo.exs
```
