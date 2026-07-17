defmodule Raxol.Harness.T10StatusStripPropertyTest do
  @moduledoc """
  Property-based coverage for roadmap unit T10 (status strip,
  charged-minimum form), sibling to `t10_status_strip_test.exs`'s
  example-based tests.

  Four properties:

    * charged-minimum absence (`property "an absent field renders
      nothing..."`) -- generated over every subset of the three
      segments: an absent field contributes NO text (and in particular
      never an em dash -- the banned void), a present field's segment
      appears verbatim at ample width.
    * width degradation (`property "output never exceeds width..."`) --
      random width, random field subset; asserts the hard TextMeasure
      bound plus the priority-nesting invariant (a lower-priority
      segment is present only if every higher-priority present segment
      also survived).
    * elapsed time-shift invariance (R11) -- shifting both `now` and
      `last_event_at` by the same offset must not change the rendered
      line. This is the property-test expression of methodology R11:
      the elapsed display is a function of the *difference* between two
      injected integers, never of their absolute magnitude.
    * ctx staleness gate (`property "context_pct renders numerically
      iff turn_completed is exactly true"`) -- `turn_completed` is
      generated independently of `context_pct`; any combination other
      than {number, true} renders NOTHING (charged minimum), never a
      stale %.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.StatusStrip

  # -- generators -----------------------------------------------------------

  defp field_value_gen(:context_pct), do: integer(0..100)
  defp field_value_gen(:cost), do: float(min: 0.0, max: 999.0)

  # Live loop-event stages only -- the phase mapping is total over the
  # frozen vocabulary; custom stages are covered in the example suite.
  defp field_value_gen(:turn_stage),
    do: member_of([:turn_started, :item_started, :item_delta, :error])

  defp present_fields_gen do
    StatusStrip.field_keys()
    |> Enum.map(&{&1, one_of([constant(:absent), field_value_gen(&1)])})
    |> fixed_map()
  end

  defp state_from_present(present_map) do
    present_map
    |> Enum.reject(fn {_key, value} -> value == :absent end)
    |> Map.new()
    |> maybe_add_turn_completed()
  end

  # `turn_completed: true` whenever context_pct is present, so the
  # generated fixture actually exercises the ctx segment instead of
  # always hitting the staleness gate's absence path.
  defp maybe_add_turn_completed(state) do
    if Map.has_key?(state, :context_pct) do
      Map.put(state, :turn_completed, true)
    else
      state
    end
  end

  # The exact segment text a present field contributes at ample width
  # -- one source of truth per segment, shared by the absence and
  # nesting properties.
  defp segment_text(state, :turn_stage), do: StatusStrip.phase_value(state)
  defp segment_text(state, :context_pct), do: StatusStrip.context_value(state)
  defp segment_text(state, :cost), do: StatusStrip.cost_value(state)

  # -- charged-minimum absence ------------------------------------------------

  property "an absent field renders nothing; a present field's segment appears verbatim" do
    check all(present_map <- present_fields_gen()) do
      state = state_from_present(present_map)
      [line] = StatusStrip.render(state, 500)

      refute line =~ "—", "em-dash voids are banned, got #{inspect(line)}"

      for key <- StatusStrip.field_keys() do
        case Map.get(present_map, key) do
          :absent ->
            assert segment_text(state, key) == nil

          _present ->
            segment = segment_text(state, key)

            # :turn_stage's phase can legitimately be nil only for
            # terminal stages, which the generator excludes.
            assert segment != nil

            assert line =~ segment,
                   "#{key} present: expected #{inspect(segment)} in #{inspect(line)}"
        end
      end
    end
  end

  # -- ctx staleness gate (turn_completed generated independently) ----------

  property "context_pct renders numerically iff turn_completed is exactly true" do
    check all(
            context_pct <- one_of([constant(:absent), integer(0..100)]),
            turn_completed <- member_of([:absent, false, true])
          ) do
      state =
        %{}
        |> maybe_put(:context_pct, context_pct)
        |> maybe_put(:turn_completed, turn_completed)

      value = StatusStrip.context_value(state)

      case {context_pct, turn_completed} do
        {pct, true} when pct != :absent ->
          assert value == "ctx #{pct}%",
                 "context_pct #{inspect(pct)} with turn_completed: true " <>
                   "should render the number, got #{inspect(value)}"

        _ ->
          assert value == nil,
                 "context_pct #{inspect(context_pct)} with turn_completed " <>
                   "#{inspect(turn_completed)} should render nothing " <>
                   "(never a stale %), got #{inspect(value)}"
      end
    end
  end

  defp maybe_put(map, _key, :absent), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- width degradation -------------------------------------------------

  property "a rendered line never exceeds its requested width" do
    check all(
            present_map <- present_fields_gen(),
            width <- integer(0..120)
          ) do
      state = state_from_present(present_map)
      [line] = StatusStrip.render(state, width)

      assert Raxol.UI.TextMeasure.display_width(line) <= width
    end
  end

  property "priority nesting holds: a surviving lower-priority segment implies every higher-priority present segment survived too" do
    check all(
            present_map <- present_fields_gen(),
            width <- integer(0..120)
          ) do
      state = state_from_present(present_map)
      [line] = StatusStrip.render(state, width)

      # Of the fields PRESENT in state (priority order), which segments
      # survived degradation into the line?
      survived =
        StatusStrip.field_keys()
        |> Enum.filter(fn key -> segment_text(state, key) != nil end)
        |> Enum.map(fn key -> line =~ segment_text(state, key) end)

      # The survivors must be a PREFIX of the present list -- never
      # e.g. cost surviving while the phase was dropped.
      refute [false, true] in Enum.chunk_every(survived, 2, 1, :discard),
             "a dropped higher-priority segment left a lower one behind: " <>
               inspect(line)
    end
  end

  # -- elapsed time-shift invariance (R11) -----------------------------------

  property "shifting now and last_event_at by the same offset never changes the rendered line" do
    check all(
            last_event_at <- integer(0..100_000),
            elapsed <- integer(0..120_000),
            shift <- integer(-50_000..50_000),
            stage <- member_of([:turn_started, :item_delta, :item_started])
          ) do
      now = last_event_at + elapsed
      shifted_last = last_event_at + shift
      shifted_now = now + shift

      base = %{turn_stage: stage, last_event_at: last_event_at, now: now}

      shifted = %{
        turn_stage: stage,
        last_event_at: shifted_last,
        now: shifted_now
      }

      assert StatusStrip.render(base, 200) == StatusStrip.render(shifted, 200)
    end
  end
end
