defmodule Raxol.Agent.EmitBridgeTest do
  @moduledoc """
  Proves the bridge translates neutral `Raxol.Core.Runtime.EmitBus` maps into
  `Raxol.Agent.Contract.Event` structs and re-emits them through
  `Raxol.Agent.SessionStreamer`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  @session_id "sess-bridge-test"

  describe "map_event/3 (pure mapping)" do
    test "command_result -> ephemeral :item_delta" do
      neutral = %{
        session_id: @session_id,
        family: :loop,
        type: :command_result,
        tier: :ephemeral,
        turn_id: nil,
        payload: %{message: {:command_result, :chunk}},
        ts: 1234
      }

      assert %Event{
               id: 7,
               session_id: @session_id,
               family: :loop,
               type: :item_delta,
               tier: :ephemeral,
               ts: 1234,
               payload: %{message: {:command_result, :chunk}}
             } = EmitBridge.map_event(neutral, 7, @session_id)
    end

    test "app_update -> durable :item_completed" do
      neutral = %{
        session_id: @session_id,
        family: :loop,
        type: :app_update,
        tier: :durable,
        turn_id: "turn-1",
        payload: %{message: :tick},
        ts: 99
      }

      assert %Event{
               type: :item_completed,
               tier: :durable,
               turn_id: "turn-1",
               family: :loop
             } = EmitBridge.map_event(neutral, 1, @session_id)
    end
  end

  describe "process wiring (EmitBus -> bridge -> SessionStreamer)" do
    setup do
      ensure_registry(EmitBus.registry_name())
      streamer = start_supervised!({SessionStreamer, name: :bridge_test_streamer})

      bridge =
        start_supervised!(
          {EmitBridge, session_id: @session_id, streamer: streamer}
        )

      # Give the bridge a moment to register its EmitBus subscription.
      _ = :sys.get_state(bridge)
      %{streamer: streamer}
    end

    test "a neutral EmitBus event arrives at SessionStreamer as a Contract.Event",
         %{streamer: streamer} do
      SessionStreamer.subscribe(@session_id, streamer)

      EmitBus.publish(
        EmitBus.build(@session_id, :command_result, :ephemeral, %{
          message: {:command_result, "hi"}
        })
      )

      assert_receive {:session_event, @session_id, %Event{} = event}, 1_000
      assert event.type == :item_delta
      assert event.tier == :ephemeral
      assert event.family == :loop
      assert event.id == 1
    end
  end

  defp ensure_registry(name) do
    case Registry.start_link(keys: :duplicate, name: name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
