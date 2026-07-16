defmodule Raxol.Harness.T10StatusStripPropertyTest do
  @moduledoc """
  Property-based coverage for roadmap unit T10 (status strip), sibling
  to `t10_status_strip_test.exs`'s example-based tests.

  Three properties, matching the task brief's test matrix:

    * missing-data matrix (`property "each absent field renders..."`) --
      generated over every subset of `StatusStrip.field_keys/0` rather
      than the four hand-picked cases in the example test file.
    * width degradation (`property "output never exceeds width..."`) --
      random width, random field subset; asserts the hard TextMeasure
      bound plus the priority-nesting invariant (a lower-priority field
      is present only if every higher-priority field is also present).
    * elapsed time-shift invariance (R11) -- shifting both `now` and
      `last_event_at` by the same offset must not change the rendered
      elapsed text. This is the property-test expression of methodology
      R11 ("assert the algorithmic fact... never a time fact"): the
      strip's elapsed display is a function of the *difference* between
      two injected integers, never of their absolute magnitude, so it
      can never be sensitive to wall-clock skew.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.StatusStrip

  @missing "—"

  # -- generators -----------------------------------------------------------

  defp field_value_gen(:context_pct), do: integer(0..100)
  defp field_value_gen(:cost), do: float(min: 0.0, max: 999.0)

  defp field_value_gen(:turn_stage),
    do: member_of([:thinking, :tool_call, :responding])

  defp field_value_gen(:needs_input), do: boolean()

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
  # generated fixture actually exercises the Ctx slot instead of always
  # hitting the turn_completed-gate `—` path.
  defp maybe_add_turn_completed(state) do
    if Map.has_key?(state, :context_pct) do
      Map.put(state, :turn_completed, true)
    else
      state
    end
  end

  # -- missing-data matrix ----------------------------------------------------

  property "each field, present or absent independently, renders its own slot" do
    check all(present_map <- present_fields_gen()) do
      state = state_from_present(present_map)
      [line] = StatusStrip.render(state, 500)

      for key <- StatusStrip.field_keys() do
        slot = slot_text(line, key)

        case Map.get(present_map, key) do
          :absent ->
            assert slot == @missing,
                   "#{key} absent should render #{inspect(@missing)}, got #{inspect(slot)}"

          _present ->
            refute slot == @missing,
                   "#{key} present should not render #{inspect(@missing)}"
        end
      end
    end
  end

  defp slot_text(line, key) do
    label = label_for(key)

    line
    |> String.split(" | ")
    |> Enum.find_value(fn segment ->
      case String.split(segment, "#{label}: ", parts: 2) do
        [_prefix, value] -> value
        [_only] -> nil
      end
    end)
  end

  defp label_for(:needs_input), do: "Input"
  defp label_for(:turn_stage), do: "Stage"
  defp label_for(:context_pct), do: "Ctx"
  defp label_for(:cost), do: "Cost"

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

  property "priority nesting holds: a present lower-priority slot implies every higher-priority slot is present too" do
    check all(
            present_map <- present_fields_gen(),
            width <- integer(0..120)
          ) do
      state = state_from_present(present_map)
      [line] = StatusStrip.render(state, width)

      present_keys =
        StatusStrip.field_keys()
        |> Enum.filter(fn key -> line =~ "#{label_for(key)}:" end)

      # field_keys/0 is already ordered highest-priority first; the set
      # of keys that survived degradation must be a PREFIX of that order
      # (never e.g. Cost present while Stage was dropped).
      assert present_keys ==
               Enum.take(StatusStrip.field_keys(), length(present_keys))
    end
  end

  # -- elapsed time-shift invariance (R11) -----------------------------------

  property "shifting now and last_event_at by the same offset never changes the elapsed display" do
    check all(
            last_event_at <- integer(0..100_000),
            elapsed <- integer(0..120_000),
            shift <- integer(-50_000..50_000),
            stage <- member_of([:thinking, :tool_call, :responding])
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

      assert StatusStrip.stage_value(base) == StatusStrip.stage_value(shifted)
    end
  end
end
