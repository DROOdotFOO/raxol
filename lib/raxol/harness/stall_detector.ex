defmodule Raxol.Harness.StallDetector do
  @moduledoc """
  The stall / doom-loop detector: a pure supervision instrument that
  tells the human "the agent you're watching has wedged" instead of
  letting a lying spinner run.

  ## Design laws

  1. **Pure detection policy.** Feed it observations, get a verdict.
     No processes, no timers, no clocks in here -- the caller owns time
     and passes timestamps in (`observe/2`) or polls with its own clock
     (`check/2`). Identical inputs always produce identical outputs.

  2. **Independent budget.** The escalation budget (`escalations_left`)
     is this detector's own counter for *quality* alarms. It is
     completely separate from any transport/error retry counting a
     caller may also keep -- a flaky network and a wedged agent are
     different failure classes and must never share a budget.

  3. **Never auto-recover.** The detector takes no corrective action on
     the agent -- no interrupt, no resample, no retry. Its entire public
     surface is construction and observation; judgment over visible
     output belongs to the human it reports to.

  4. **Hard graceful terminal.** Each distinct `:stalled`/`:looping`
     alarm spends one unit of the escalation budget. Once the budget is
     spent, further alarms are returned with `standing_by: true` -- the
     verdict still tells the truth (class + current evidence), but is
     never presented as a fresh escalation again. Deterministic
     termination, no alert fatigue. A repeat of the *same* alarm never
     spends budget either (it is flagged `standing_by` as "already
     reported"). The budget never refills within a detector instance;
     callers that want per-turn budgets construct a detector per turn.

  5. **Honesty floor.** No verdict without evidence: every non-`:ok`
     verdict carries the reason, the structured detail, and a
     human-readable `summary` naming exactly what triggered it. A fresh
     or insufficient observation window is `:ok` -- never
     suspect-by-default. False alarms erode trust in the instrument.

  ## Signals

  * **Repetition** -- the same tool called with byte-identical
    arguments `@default_repetition_threshold` times within the recent
    call window (`:looping`); the count just below that is `:suspect`.
  * **Ping-pong** -- two distinct calls alternating A,B,A,B for
    `@default_ping_pong_threshold` full cycles (`:looping`); one cycle
    short of that is `:suspect`. Cycle lengths 1 and 2 only, exact
    argument match -- deliberately simple.
  * **No-progress elapse** -- a working agent with no new events for
    longer than a threshold. The thresholds default to the status
    strip's shipped hung heuristic
    (`Raxol.Harness.StatusStrip.default_warn_after_ms/0` /
    `default_hung_after_ms/0`) rather than a parallel set of constants:
    past warn is `:suspect`, past hung is `:stalled`.

  When a call-pattern signal and a time signal fire simultaneously the
  most severe wins (`:looping` > `:stalled` > `:suspect`), with the
  pattern signal breaking ties -- its evidence names the concrete
  wedge, which is more actionable than a bare elapsed number.

  The detector is always-on by construction: it has no enabled flag.
  Whether to consult it at all is the caller's decision, made simply by
  constructing one (or not).

  ## Wiring

  The one shipped consumer is the status strip: pass the latest verdict
  as the strip's optional `:stall_verdict` state key and a
  `:stalled`/`:looping` verdict renders as a highest-priority `ALERT:`
  notice naming the evidence. `observation_from_event/1` maps harness
  fixture/journal events (the `Raxol.Harness.Fixture.Event` shape) to
  observations, converting microsecond event timestamps to the
  millisecond domain the thresholds live in -- the same µs -> ms
  convention `Raxol.UI.Components.Harness.Block` uses for durations.
  """

  alias Raxol.Harness.StatusStrip

  defmodule Verdict do
    @moduledoc """
    One detector verdict. `class` is the four-state answer; `evidence`
    is nil exactly when `class` is `:ok` (the honesty floor), otherwise
    a map always carrying `:reason` and a human-readable `:summary`
    plus reason-specific detail. `standing_by: true` marks a verdict
    that is NOT a fresh escalation: either a repeat of an
    already-reported alarm, or an alarm raised after the escalation
    budget was spent.
    """

    defstruct class: :ok, evidence: nil, standing_by: false

    @type class :: :ok | :suspect | :stalled | :looping

    @type evidence :: %{
            :reason => :repetition | :ping_pong | :no_progress,
            :summary => String.t(),
            optional(:tool) => term(),
            optional(:count) => pos_integer(),
            optional(:tools) => {term(), term()},
            optional(:cycles) => pos_integer(),
            optional(:elapsed_ms) => non_neg_integer()
          }

    @type t :: %__MODULE__{
            class: class(),
            evidence: evidence() | nil,
            standing_by: boolean()
          }
  end

  # Four byte-identical calls: an agent legitimately re-reads a file two
  # or three times while working on it (read, edit, re-check); a fourth
  # identical call in the recent window is where legitimate re-checking
  # ends. Conservative on purpose -- a false loop alarm costs more trust
  # than a one-call-late true one.
  @default_repetition_threshold 4

  # Three full A,B cycles (six calls): alternating between two calls
  # once or twice is a normal investigate-compare shape; a third full
  # round trip with identical arguments is not.
  @default_ping_pong_threshold 3

  # Three distinct fresh alarms name the problem; a fourth re-alarm on a
  # human who has not intervened after three is fatigue, not
  # information.
  @default_escalation_budget 3

  @enforce_keys [
    :repetition_threshold,
    :ping_pong_threshold,
    :warn_after_ms,
    :hung_after_ms,
    :escalations_left,
    :max_history
  ]
  defstruct [
    :repetition_threshold,
    :ping_pong_threshold,
    :warn_after_ms,
    :hung_after_ms,
    :escalations_left,
    :max_history,
    calls: [],
    last_activity_at: nil,
    last_alarm: nil
  ]

  @typedoc """
  Observations are the detector's whole input vocabulary:

  * `{:tool_call, name, arguments, at_ms}` -- the agent invoked a tool.
  * `{:progress, at_ms}` -- any other observable activity (deltas,
    results, messages). Progress feeds the no-progress clock but never
    resets the call window: tool results always interleave tool calls,
    so a loop must stay visible through them.
  """
  @type observation ::
          {:tool_call, name :: term(), arguments :: term(), at_ms :: integer()}
          | {:progress, at_ms :: integer()}

  @type t :: %__MODULE__{
          repetition_threshold: pos_integer(),
          ping_pong_threshold: pos_integer(),
          warn_after_ms: pos_integer(),
          hung_after_ms: pos_integer(),
          escalations_left: non_neg_integer(),
          max_history: pos_integer(),
          calls: [{term(), term()}],
          last_activity_at: integer() | nil,
          last_alarm: tuple() | nil
        }

  @doc """
  Builds a detector. Options (all with documented defaults above):
  `:repetition_threshold`, `:ping_pong_threshold`, `:warn_after_ms`,
  `:hung_after_ms`, `:escalation_budget`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    repetition_threshold =
      Keyword.get(opts, :repetition_threshold, @default_repetition_threshold)

    ping_pong_threshold =
      Keyword.get(opts, :ping_pong_threshold, @default_ping_pong_threshold)

    %__MODULE__{
      repetition_threshold: repetition_threshold,
      ping_pong_threshold: ping_pong_threshold,
      warn_after_ms:
        Keyword.get(opts, :warn_after_ms, StatusStrip.default_warn_after_ms()),
      hung_after_ms:
        Keyword.get(opts, :hung_after_ms, StatusStrip.default_hung_after_ms()),
      escalations_left:
        Keyword.get(opts, :escalation_budget, @default_escalation_budget),
      # Just enough history to decide both call-pattern signals; nothing
      # in the verdict ever looks further back, so nothing older is kept
      # (bounded state, observation count can't grow the detector).
      max_history: max(repetition_threshold, 2 * ping_pong_threshold)
    }
  end

  @doc """
  Feeds one observation, returning `{verdict, detector}`. An
  observation IS activity, so the no-progress clock resets here; only
  the call-pattern signals can fire from `observe/2`.
  """
  @spec observe(t(), observation()) :: {Verdict.t(), t()}
  def observe(%__MODULE__{} = detector, {:tool_call, name, arguments, at}) do
    detector = %{
      detector
      | calls:
          Enum.take([{name, arguments} | detector.calls], detector.max_history),
        last_activity_at: at
    }

    resolve(detector, pattern_detection(detector))
  end

  def observe(%__MODULE__{} = detector, {:progress, at}) do
    detector = %{detector | last_activity_at: at}
    resolve(detector, pattern_detection(detector))
  end

  @doc """
  Polls the detector against the caller's clock (same millisecond
  domain the observations used), returning `{verdict, detector}`. This
  is where the no-progress signal can fire; an active call-pattern
  alarm also stays visible here (a clock tick must never clear a loop
  verdict). With no activity ever observed the window is insufficient:
  `:ok`, per the honesty floor.
  """
  @spec check(t(), integer()) :: {Verdict.t(), t()}
  def check(%__MODULE__{} = detector, now) when is_integer(now) do
    detection =
      most_severe(pattern_detection(detector), time_detection(detector, now))

    resolve(detector, detection)
  end

  @doc """
  Maps one harness event (a `Raxol.Harness.Fixture.Event` struct or an
  event-shaped map: atom top-level keys, string payload keys,
  microsecond `ts`) to an observation, or `nil` when the event is not
  an observation (meta family, or no usable timestamp). A completed
  `tool_use` item becomes a `:tool_call`; every other loop-family event
  is `:progress`.
  """
  @spec observation_from_event(map()) :: observation() | nil
  def observation_from_event(event) when is_map(event) do
    ts = Map.get(event, :ts)
    payload = Map.get(event, :payload) || %{}

    cond do
      Map.get(event, :family) != :loop or not is_integer(ts) ->
        nil

      Map.get(event, :type) == :item_completed and
          Map.get(payload, "item_type") == "tool_use" ->
        {:tool_call, Map.get(payload, "name"), Map.get(payload, "arguments"),
         us_to_ms(ts)}

      true ->
        {:progress, us_to_ms(ts)}
    end
  end

  # Event timestamps are microseconds (see the fixture schema); the
  # detector's thresholds live in milliseconds, matching the status
  # strip. Same conversion Block uses for durations.
  defp us_to_ms(ts), do: div(ts, 1000)

  # -- detection: call patterns ------------------------------------------

  # Returns nil or {class, signature, evidence}. The signature is the
  # alarm's stable identity for budget/dedup purposes: it excludes
  # anything that grows while the SAME wedge continues (counts, cycle
  # totals, elapsed), so a persisting alarm is one escalation, not many.
  defp pattern_detection(%__MODULE__{calls: calls} = detector) do
    run = leading_run(calls)
    cycles = leading_cycles(calls)

    cond do
      run >= detector.repetition_threshold ->
        repetition(:looping, calls, run)

      cycles >= detector.ping_pong_threshold ->
        ping_pong(:looping, calls, cycles)

      run == detector.repetition_threshold - 1 ->
        repetition(:suspect, calls, run)

      cycles == detector.ping_pong_threshold - 1 ->
        ping_pong(:suspect, calls, cycles)

      true ->
        nil
    end
  end

  defp repetition(class, [{name, arguments} | _rest], count) do
    lead = if class == :looping, do: "possible loop", else: "repeated call"

    {class, {:repetition, class, name, arguments},
     %{
       reason: :repetition,
       tool: name,
       count: count,
       summary: "#{lead}: #{name} x#{count} same args"
     }}
  end

  defp ping_pong(class, [later, earlier | _rest], cycles) do
    {earlier_name, _args} = earlier
    {later_name, _args} = later
    lead = if class == :looping, do: "possible loop", else: "alternating calls"

    {class, {:ping_pong, class, Enum.sort([earlier, later])},
     %{
       reason: :ping_pong,
       tools: {earlier_name, later_name},
       cycles: cycles,
       summary: "#{lead}: #{earlier_name}<->#{later_name} x#{cycles}"
     }}
  end

  # Length of the identical prefix of the call window (newest first).
  defp leading_run([]), do: 0

  defp leading_run([head | rest]) do
    1 + Enum.count(Enum.take_while(rest, &(&1 == head)))
  end

  # Full A,B cycles at the head of the window: the longest prefix in
  # which every entry equals the entry two positions before it, with the
  # first two entries distinct (pure repetition is the cycle-1 signal,
  # never counted here). Six alternating entries = three full cycles.
  defp leading_cycles([first, second | _rest] = calls) when first != second do
    div(alternating_prefix(calls), 2)
  end

  defp leading_cycles(_calls), do: 0

  defp alternating_prefix([first, second | rest]) do
    # Beyond the first two entries, position i must repeat position
    # i - 2 -- i.e. match the infinite alternation first,second,first,...
    matched =
      rest
      |> Enum.zip(Stream.cycle([first, second]))
      |> Enum.take_while(fn {entry, expected} -> entry == expected end)
      |> length()

    2 + matched
  end

  defp time_detection(%__MODULE__{last_activity_at: nil}, _now), do: nil

  defp time_detection(%__MODULE__{last_activity_at: last} = detector, now) do
    elapsed = max(now - last, 0)

    cond do
      elapsed >= detector.hung_after_ms ->
        {:stalled, {:no_progress, :stalled},
         %{
           reason: :no_progress,
           elapsed_ms: elapsed,
           summary: "no output for #{format_elapsed(elapsed)}"
         }}

      elapsed >= detector.warn_after_ms ->
        {:suspect, {:no_progress, :suspect},
         %{
           reason: :no_progress,
           elapsed_ms: elapsed,
           summary: "quiet for #{format_elapsed(elapsed)}"
         }}

      true ->
        nil
    end
  end

  # Same rendering the status strip uses for elapsed values, so the
  # detector's evidence and the strip's Stage ticker read alike.
  defp format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  defp format_elapsed(ms) do
    total_s = div(ms, 1000)
    seconds = rem(total_s, 60)
    padded = if seconds < 10, do: "0#{seconds}", else: "#{seconds}"
    "#{div(total_s, 60)}m#{padded}s"
  end

  # -- severity + budget resolution -----------------------------------------

  @severity %{looping: 3, stalled: 2, suspect: 1}

  # Pattern first: on a severity tie its evidence (the concrete wedge)
  # beats a bare elapsed number.
  defp most_severe(nil, time), do: time
  defp most_severe(pattern, nil), do: pattern

  defp most_severe({p_class, _, _} = pattern, {t_class, _, _} = time) do
    if @severity[t_class] > @severity[p_class], do: time, else: pattern
  end

  # No detection: the honest all-clear. Clearing forgets the last alarm,
  # so the SAME wedge recurring later is a new incident (and, budget
  # permitting, a fresh escalation) -- flapping is bounded by the budget,
  # never by suppression.
  defp resolve(detector, nil) do
    {%Verdict{}, %{detector | last_alarm: nil}}
  end

  defp resolve(%__MODULE__{last_alarm: sig} = detector, {class, sig, evidence}) do
    # The same alarm persisting: already reported, never a fresh
    # escalation, never a budget spend.
    {%Verdict{class: class, evidence: evidence, standing_by: true}, detector}
  end

  defp resolve(detector, {:suspect, signature, evidence}) do
    # Pre-alarms are free: they are hints the caller may consult, not
    # escalations (the strip does not even render them).
    {%Verdict{class: :suspect, evidence: evidence},
     %{detector | last_alarm: signature}}
  end

  defp resolve(
         %__MODULE__{escalations_left: 0} = detector,
         {class, signature, evidence}
       ) do
    # Terminal: reported, standing by. Evidence stays current and
    # honest; the standing_by flag is what guarantees no re-alarm.
    {%Verdict{class: class, evidence: evidence, standing_by: true},
     %{detector | last_alarm: signature}}
  end

  defp resolve(detector, {class, signature, evidence}) do
    {%Verdict{class: class, evidence: evidence},
     %{
       detector
       | last_alarm: signature,
         escalations_left: detector.escalations_left - 1
     }}
  end
end
