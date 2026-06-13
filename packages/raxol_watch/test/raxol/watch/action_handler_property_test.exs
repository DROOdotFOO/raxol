defmodule Raxol.Watch.ActionHandlerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Watch.ActionHandler

  describe "handle_action/2 default map" do
    @key_action_keys ActionHandler.default_action_map()
                     |> Enum.filter(fn {_, v} -> match?({:key, _}, v) end)
                     |> Enum.map(fn {k, _} -> k end)

    @all_event_keys ActionHandler.default_action_map()
                    |> Enum.reject(fn {_, v} -> is_nil(v) end)
                    |> Enum.map(fn {k, _} -> k end)

    property "every key that maps to a {:key, _} tuple produces a :key Event" do
      check all(action_id <- member_of(@key_action_keys)) do
        event = ActionHandler.handle_action(action_id)
        assert event.type == :key
      end
    end

    property "every non-nil default key produces an Event of the matching type" do
      check all(action_id <- member_of(@all_event_keys)) do
        {type, _data} = ActionHandler.default_action_map()[action_id]
        event = ActionHandler.handle_action(action_id)
        assert event.type == type
      end
    end

    property "any action ID not present in the map returns nil" do
      check all(
              action_id <- string(:alphanumeric, min_length: 1),
              action_id not in Map.keys(ActionHandler.default_action_map())
            ) do
        assert ActionHandler.handle_action(action_id) == nil
      end
    end
  end

  describe "handle_action/2 merge semantics" do
    property "custom keys not in defaults produce events from the custom map" do
      check all(
              action_id <- string(:alphanumeric, min_length: 1),
              action_id not in Map.keys(ActionHandler.default_action_map()),
              char <- string(:alphanumeric, length: 1)
            ) do
        custom = %{action_id => {:key, %{key: :char, char: char}}}
        event = ActionHandler.handle_action(action_id, action_map: custom)
        assert event.type == :key
        assert event.data.char == char
      end
    end

    property "custom map overrides default keys" do
      check all(char <- string(:alphanumeric, length: 1)) do
        # "pause" in the default map maps to space; override it.
        custom = %{"pause" => {:key, %{key: :char, char: char}}}
        event = ActionHandler.handle_action("pause", action_map: custom)
        assert event.data.char == char
      end
    end

    property "default keys are preserved when not overridden by the custom map" do
      check all(
              action_id <- member_of(@all_event_keys),
              # Build a custom map that doesn't touch this key.
              other_key <- string(:alphanumeric, min_length: 1),
              other_key != action_id
            ) do
        custom = %{other_key => {:key, %{key: :enter}}}
        default_event = ActionHandler.handle_action(action_id)
        merged_event = ActionHandler.handle_action(action_id, action_map: custom)
        # Compare semantic fields only; Event.timestamp shifts between calls.
        assert default_event.type == merged_event.type
        assert default_event.data == merged_event.data
      end
    end

    property "a malformed :action_map option falls back to defaults" do
      check all(
              malformed <-
                one_of([
                  constant(nil),
                  integer(),
                  string(:alphanumeric),
                  list_of(atom(:alphanumeric))
                ])
            ) do
        # Whatever junk we throw at it, "details" must still resolve to enter.
        event = ActionHandler.handle_action("details", action_map: malformed)
        assert event.type == :key
        assert event.data.key == :enter
      end
    end
  end

  describe "dispatch/2 invariants" do
    setup do
      on_exit(fn -> Application.delete_env(:raxol_watch, :action_dispatcher) end)
      :ok
    end

    property "actions that handle_action returns nil for, dispatch returns {:ok, nil}" do
      # Build a sentinel set: known "dismiss" + any action ID not in defaults.
      check all(
              action_id <-
                one_of([
                  constant("dismiss"),
                  string(:alphanumeric, min_length: 1)
                ]),
              # Exclude the known-good action keys
              ActionHandler.handle_action(action_id) == nil
            ) do
        assert ActionHandler.dispatch(action_id, to: self()) == {:ok, nil}
        refute_received {:watch_action, _}
      end
    end

    property "every default key that produces an event delivers {:watch_action, event} to a pid dispatcher" do
      check all(action_id <- member_of(@all_event_keys)) do
        assert {:ok, event} = ActionHandler.dispatch(action_id, to: self())
        assert_received {:watch_action, ^event}
      end
    end
  end
end
