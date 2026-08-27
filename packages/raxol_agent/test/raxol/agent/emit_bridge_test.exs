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
  alias Raxol.Agent.Meta
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

      streamer =
        start_supervised!({SessionStreamer, name: :bridge_test_streamer})

      bridge =
        start_supervised!({EmitBridge, session_id: @session_id, streamer: streamer})

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

      streamer =
        start_supervised!({SessionStreamer, name: :bridge_spoof_streamer})

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
      assert record["actor"] == %{
               "kind" => "system",
               "id" => "bridge-authority"
             }

      assert record["branch_id"] == "feature-x"

      refute record["actor"] == %{"kind" => "human", "id" => "attacker"},
             "a module-invented actor must not bypass the producer-seam stamp"

      :ok = FileStore.close(journal)
    end

    test "a non-default branch_id is written AND round-trips off disk; \"main\" is omitted (I2)",
         %{streamer: streamer, base: base} do
      # Default branch: the record OMITS branch_id (byte-identity preserved).
      main_session = "sess-main-#{System.unique_integer([:positive])}"
      {:ok, main_journal} = FileStore.open(main_session, base_dir: base)

      main_bridge =
        start_supervised!(
          {EmitBridge, session_id: main_session, streamer: streamer, journal: main_journal},
          id: :main_bridge
        )

      _ = :sys.get_state(main_bridge)
      EmitBus.publish(durable_neutral(main_session))
      _ = :sys.get_state(main_bridge)

      {:ok, [main_record]} = FileStore.read(main_journal)

      refute Map.has_key?(main_record, "branch_id"),
             "a default (\"main\") branch_id must stay implicit on disk (I2)"

      assert {:ok, %Event{branch_id: "main"}} = Meta.decode(main_record)
      :ok = FileStore.close(main_journal)

      # Non-default branch: written AND surfaced back onto the decoded Event.
      feat_session = "sess-feat-#{System.unique_integer([:positive])}"
      {:ok, feat_journal} = FileStore.open(feat_session, base_dir: base)

      feat_bridge =
        start_supervised!(
          {EmitBridge,
           session_id: feat_session,
           streamer: streamer,
           journal: feat_journal,
           branch_id: "feature-x"},
          id: :feat_bridge
        )

      _ = :sys.get_state(feat_bridge)
      EmitBus.publish(durable_neutral(feat_session))
      _ = :sys.get_state(feat_bridge)

      {:ok, [feat_record]} = FileStore.read(feat_journal)
      assert feat_record["branch_id"] == "feature-x"

      assert {:ok, %Event{branch_id: "feature-x"}} = Meta.decode(feat_record),
             "a non-default branch_id must round-trip write -> disk -> decode"

      :ok = FileStore.close(feat_journal)
    end
  end

  # ===========================================================================
  # Round-2 fix (🔴): write-generation provenance seam (taint-absorbing meet)
  # ===========================================================================

  describe "write-generation provenance seam (taint-absorbing meet)" do
    setup do
      ensure_registry(EmitBus.registry_name())

      streamer =
        start_supervised!({SessionStreamer, name: :bridge_prov_streamer})

      base =
        Path.join(
          System.tmp_dir!(),
          "bridge_prov_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      %{streamer: streamer, base: base}
    end

    test "a tainted generation force-taints a module OMISSION (laundering-by-omission closed)",
         %{streamer: streamer, base: base} do
      session = "sess-prov-omit-#{System.unique_integer([:positive])}"
      {:ok, journal} = FileStore.open(session, base_dir: base)

      bridge =
        start_supervised!(
          {EmitBridge,
           session_id: session,
           streamer: streamer,
           journal: journal,
           provenance: %{source: :primary, trust: :tainted}},
          id: :prov_omit_bridge
        )

      _ = :sys.get_state(bridge)

      # The neutral map carries NO provenance — the exact omission that would
      # otherwise land as the trusted grandfather default and launder a taint
      # source (the review's write-side finding).
      EmitBus.publish(durable_neutral(session))
      _ = :sys.get_state(bridge)

      {:ok, [record]} = FileStore.read(journal)

      assert record["provenance"] == %{
               "source" => "primary",
               "trust" => "tainted"
             },
             "a tainted write generation must stamp taint onto an omitted provenance"

      assert {:ok, %Event{provenance: %{trust: :tainted}}} = Meta.decode(record)
      :ok = FileStore.close(journal)
    end

    test "a module-supplied :tainted is NEVER overwritten by the generation stamp (no upgrade path)",
         %{streamer: streamer, base: base} do
      session = "sess-prov-keep-#{System.unique_integer([:positive])}"
      {:ok, journal} = FileStore.open(session, base_dir: base)

      # The generation context says trusted — an unconditional Map.put stamp
      # (the actor pattern) would LAUNDER the module's honest :tainted.
      bridge =
        start_supervised!(
          {EmitBridge,
           session_id: session,
           streamer: streamer,
           journal: journal,
           provenance: %{source: :primary, trust: :trusted}},
          id: :prov_keep_bridge
        )

      _ = :sys.get_state(bridge)

      tainted_neutral =
        session
        |> durable_neutral()
        |> Map.put(:provenance, %{source: :primary, trust: :tainted})

      EmitBus.publish(tainted_neutral)
      _ = :sys.get_state(bridge)

      {:ok, [record]} = FileStore.read(journal)

      assert record["provenance"] == %{
               "source" => "primary",
               "trust" => "tainted"
             },
             "the taint-absorbing meet must never upgrade :tainted -> :trusted"

      :ok = FileStore.close(journal)
    end

    test "no generation context + module omission: the frozen default stays IMPLICIT on disk (I2)",
         %{streamer: streamer, base: base} do
      session = "sess-prov-default-#{System.unique_integer([:positive])}"
      {:ok, journal} = FileStore.open(session, base_dir: base)

      bridge =
        start_supervised!(
          {EmitBridge, session_id: session, streamer: streamer, journal: journal},
          id: :prov_default_bridge
        )

      _ = :sys.get_state(bridge)
      EmitBus.publish(durable_neutral(session))
      _ = :sys.get_state(bridge)

      {:ok, [record]} = FileStore.read(journal)

      # Anti-tautology guard: the seam must not disturb the grandfather clause —
      # a default event's on-disk bytes stay byte-identical to pre-U11 (I2).
      refute Map.has_key?(record, "provenance"),
             "a default provenance must stay implicit on disk"

      assert {:ok, %Event{provenance: %{source: :primary, trust: :trusted}}} =
               Meta.decode(record)

      :ok = FileStore.close(journal)
    end
  end

  # ===========================================================================
  # Adjacent fix: approval_requested / woken are forced durable
  # ===========================================================================

  describe "approval_requested is forced durable (resume-bracket)" do
    setup do
      ensure_registry(EmitBus.registry_name())

      streamer =
        start_supervised!({SessionStreamer, name: :bridge_approval_streamer})

      base =
        Path.join(
          System.tmp_dir!(),
          "bridge_approval_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      %{streamer: streamer, base: base}
    end

    test "an approval_requested emitted with ephemeral tier still lands durable (journaled)",
         %{streamer: streamer, base: base} do
      session = "sess-approval-#{System.unique_integer([:positive])}"
      {:ok, journal} = FileStore.open(session, base_dir: base)

      bridge =
        start_supervised!({EmitBridge, session_id: session, streamer: streamer, journal: journal})

      _ = :sys.get_state(bridge)
      SessionStreamer.subscribe(session, streamer)

      # Deliberately sent ephemeral — the resume-bracket must NOT honour it.
      ephemeral_approval = %{
        session_id: session,
        family: :loop,
        type: :approval_requested,
        tier: :ephemeral,
        turn_id: "t1",
        payload: %{request: "confirm?"},
        ts: 1
      }

      EmitBus.publish(ephemeral_approval)
      _ = :sys.get_state(bridge)

      # It was journaled (durable) despite being sent ephemeral — the resume
      # point is now recoverable on replay.
      {:ok, [record]} = FileStore.read(journal)
      assert record["type"] == "approval_requested"
      assert record["tier"] == "durable"

      # ...and the live event carries a real journal offset, tier :durable.
      assert_receive {:session_event, ^session,
                      %Event{type: :approval_requested, tier: :durable, id: id}},
                     1_000

      assert id >= 1, "a journaled durable event must carry a real offset"

      :ok = FileStore.close(journal)
    end
  end

  defp durable_neutral(session) do
    %{
      session_id: session,
      family: :loop,
      type: :app_update,
      tier: :durable,
      turn_id: "t1",
      payload: %{message: :hi},
      ts: 1
    }
  end

  defp ensure_registry(name) do
    case Registry.start_link(keys: :duplicate, name: name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
