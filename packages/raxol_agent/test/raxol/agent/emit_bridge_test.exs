defmodule Raxol.Agent.EmitBridgeTest do
  @moduledoc """
  Proves the bridge translates neutral `Raxol.Core.Runtime.EmitBus` maps into
  `Raxol.Agent.Contract.Event` structs and re-emits them through
  `Raxol.Agent.SessionStreamer`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Journal.FileStore
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
      # Ephemeral events are never journaled; their id carries the last durable
      # offset (0 here — no durable event has been journaled yet), never a fresh
      # offset that could masquerade as a journal id.
      assert event.id == 0
    end
  end

  # ===========================================================================
  # Adversarial fix (🔴): producer-seam stamping is not spoofable
  # ===========================================================================

  describe "producer-seam stamping is not spoofable (actor/branch_id)" do
    setup do
      ensure_registry(EmitBus.registry_name())
      streamer = start_supervised!({SessionStreamer, name: :bridge_spoof_streamer})

      base =
        Path.join(
          System.tmp_dir!(),
          "bridge_spoof_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      %{streamer: streamer, base: base}
    end

    test "a module-supplied actor/branch_id in the neutral map does NOT override the bridge stamp",
         %{streamer: streamer, base: base} do
      session = "sess-spoof-#{System.unique_integer([:positive])}"
      {:ok, journal} = FileStore.open(session, base_dir: base)

      authority = %{kind: :system, id: "bridge-authority"}

      bridge =
        start_supervised!(
          {EmitBridge,
           session_id: session,
           streamer: streamer,
           journal: journal,
           actor: authority,
           branch_id: "feature-x"}
        )

      # Flush the EmitBus subscription registration.
      _ = :sys.get_state(bridge)

      # A hostile neutral map inventing its OWN actor + branch_id — exactly the
      # producer-seam bypass §2.1 forbids ("modules never invent it").
      spoof = %{
        session_id: session,
        family: :loop,
        type: :app_update,
        tier: :durable,
        turn_id: "t1",
        payload: %{message: :hi},
        ts: 1,
        actor: %{kind: :human, id: "attacker"},
        branch_id: "attacker-branch"
      }

      EmitBus.publish(spoof)
      # get_state queues AFTER the emit_bus info, so the append has happened.
      _ = :sys.get_state(bridge)

      {:ok, [record]} = FileStore.read(journal)

      # The bridge's write-generation values WIN; the spoofed ones never land.
      assert record["actor"] == %{"kind" => "system", "id" => "bridge-authority"}
      assert record["branch_id"] == "feature-x"

      refute record["actor"] == %{"kind" => "human", "id" => "attacker"},
             "a module-invented actor must not bypass the producer-seam stamp"

      :ok = FileStore.close(journal)
    end
  end

  defp ensure_registry(name) do
    case Registry.start_link(keys: :duplicate, name: name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
