defmodule Raxol.Property.DemoUpdateTotalityTest do
  @moduledoc """
  Property: every demo's `update/2` is a total function.

  For each demo in `Raxol.Playground.Catalog`, and any randomly-generated
  sequence of key events, folding `update/2` across the sequence must:

    * never raise
    * always return `{model, commands}` where `commands` is a list

  This catches state-machine edge cases that example tests miss:

    * Cursor that walks off the end of a list (`Enum.at` returning nil,
      then arithmetic on it later)
    * Toggling a boolean with a key sequence that exposes an unhandled
      transition
    * Backspace into an empty string
    * Tick events arriving while in a state that didn't subscribe to them
    * Negative indices, unicode characters, special-key spam

  All existing demo tests in `demos_test.exs` exercise specific keys for
  specific assertions. This one exercises arbitrary sequences and only
  checks the function-shape contract, which is exactly the safety net the
  state-machine code needs.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.Catalog

  @max_sequence_length 30

  # Keep the runs-per-demo modest since we iterate across all ~30 demos
  # and each run plays back a sequence of up to 30 events. The total
  # search is large enough to surface edge cases without inflating the
  # suite runtime.
  @runs_per_demo 50

  # ---------------------------------------------------------------------------
  # Properties — one per demo so failure messages name the offender
  # ---------------------------------------------------------------------------

  for component <- Catalog.list_components() do
    @component component

    @tag demo: @component.name
    property "#{@component.name}: update/2 never raises for any key sequence" do
      module = @component.module
      initial = module.init(nil)

      check all(events <- event_sequence(), max_runs: @runs_per_demo) do
        try do
          final =
            Enum.reduce(events, initial, fn event, model ->
              # A non-{model, list} shape raises CaseClauseError, caught and
              # reported by the rescue below (the shape contract this property
              # guards).
              case module.update(event, model) do
                {new_model, commands} when is_list(commands) ->
                  new_model
              end
            end)

          # If the fold completed, the property holds. Sanity-check the
          # final model is still a map so downstream view/1 has something
          # to inspect.
          assert is_map(final),
                 "#{@component.name}: final model is not a map after #{length(events)} events: #{inspect(final)}"
        rescue
          exception ->
            flunk("""
            #{@component.name}: update/2 raised #{inspect(exception.__struct__)}.

            Message: #{Exception.message(exception)}

            Sequence (#{length(events)} events):
            #{format_events(events)}

            Stack:
            #{Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 800)}
            """)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp event_sequence do
    list_of(event_gen(), min_length: 0, max_length: @max_sequence_length)
  end

  defp event_gen do
    # Mix character-key events with special-key events. The proportions
    # are tuned to surface edge cases — heavy on chars (they're the
    # densest input), enough specials to hit branch coverage.
    frequency([
      {7, char_event()},
      {3, special_event()},
      {1, tick_event()},
      {1, modifier_event()}
    ])
  end

  defp char_event do
    gen all(char <- printable_char()) do
      %Event{type: :key, data: %{key: :char, char: char}}
    end
  end

  defp printable_char do
    # Single-character strings drawn from a-z, A-Z, 0-9, space, and a
    # handful of punctuation that demos look for (e.g. '?', '/', '=').
    member_of(
      Enum.map(?a..?z, &<<&1>>) ++
        Enum.map(?A..?Z, &<<&1>>) ++
        Enum.map(?0..?9, &<<&1>>) ++
        [" ", "?", "/", "=", "-", "+", ".", ":", "!", ";"]
    )
  end

  defp special_event do
    gen all(key <- special_key()) do
      %Event{type: :key, data: %{key: key}}
    end
  end

  defp special_key do
    member_of([
      :enter,
      :escape,
      :backspace,
      :tab,
      :space,
      :up,
      :down,
      :left,
      :right,
      :home,
      :end,
      :page_up,
      :page_down,
      :delete
    ])
  end

  defp tick_event do
    # Many demos handle :tick atoms as a refresh signal alongside key
    # events. Folding a few of these in surfaces demos that crash when
    # tick arrives while they're not subscribed to it.
    constant(:tick)
  end

  defp modifier_event do
    # Chars with ctrl/alt/shift modifiers; demos shouldn't crash on
    # these even when they don't bind a handler.
    gen all(
          char <- printable_char(),
          mod <- member_of([:ctrl, :alt, :shift])
        ) do
      data = Map.put(%{key: :char, char: char}, mod, true)
      %Event{type: :key, data: data}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_events(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {ev, i} ->
      "  #{String.pad_leading(Integer.to_string(i), 2)}. #{format_event(ev)}"
    end)
  end

  defp format_event(:tick), do: ":tick"

  defp format_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: c} -> "char #{inspect(c)}"
      %{key: key} -> "special #{inspect(key)}"
      other -> inspect(other)
    end
  end

  defp format_event(other), do: inspect(other)
end
