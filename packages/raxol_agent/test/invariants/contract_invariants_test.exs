defmodule Raxol.Agent.Invariants.ContractInvariantsTest do
  @moduledoc """
  Tier-1 invariant I9 — the contract only grows, DEEP (see
  `docs/harness/architecture.md`'s "The contract only grows" rule).

  `fixtures/contract_snapshot.json` is the checked-in floor: per-type payload
  shapes, enum values, field requiredness, tier assignments, and the neutral →
  contract mapping. This module re-produces every snapshotted shape through the
  REAL producers (`Contract.pump/3` and the Dispatcher→EmitBridge path) and
  fails on removal, rename, type-narrowing, required→optional flip, tier flip,
  enum-value removal, or event-type removal. Additions never fail — growth is
  legal without touching the snapshot.

  `fixtures/golden/v<version>/` holds one REAL journal per `schema_version`,
  written by the Writer that was current when the version was — the corpus
  seed for future upcast-on-read properties: every future schema version must
  still open, replay, and validate these journals. A version is frozen once and
  never edited (`scripts/freeze_golden_journal.exs`); `MANIFEST.json` pins the
  bytes and `scripts/check_journal_goldens.exs` enforces that a bump arrives
  with a fixture for the version it leaves behind.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  @fixtures Path.join(__DIR__, "fixtures")
  @snapshot @fixtures
            |> Path.join("contract_snapshot.json")
            |> File.read!()
            |> Jason.decode!()
  @golden Path.join(@fixtures, "golden/v1.0.0/golden-v1")

  # The corpus for whatever the Writer currently defaults to, resolved through
  # the same manifest `scripts/check_journal_goldens.exs` enforces — so a
  # `schema_version` bump that skips freezing fails here too, not only in CI
  # (`raxol_agent` is a local gate, not a per-PR CI package).
  @manifest @fixtures
            |> Path.join("golden/MANIFEST.json")
            |> File.read!()
            |> Jason.decode!()
  @current_version Raxol.Agent.Journal.FileStore.Writer.default_schema_version()
  @current_session get_in(@manifest, ["versions", @current_version, "session"])
  @current_golden Path.join([
                    @fixtures,
                    "golden/v#{@current_version}",
                    @current_session || ""
                  ])

  setup do
    FaultJournal.ensure_registry(:duplicate, EmitBus.registry_name())

    FaultJournal.ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    # pump/3 emits into the NAMED SessionStreamer.
    start_supervised!(Raxol.Agent.SessionStreamer)

    base =
      Path.join(
        System.tmp_dir!(),
        "raxol_inv_contract_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # ===========================================================================
  # Envelope: the Event struct may only grow
  # ===========================================================================

  describe "I9 — envelope" do
    test "every snapshotted envelope field still exists on Contract.Event (removal/rename breaks the contract)" do
      struct_keys =
        %Event{} |> Map.from_struct() |> Map.keys() |> MapSet.new(&to_string/1)

      required = MapSet.new(@snapshot["envelope"]["required"])

      missing = MapSet.difference(required, struct_keys)

      assert MapSet.size(missing) == 0,
             "Contract.Event lost envelope field(s): #{inspect(MapSet.to_list(missing))} — " <>
               "the contract may only grow"
    end

    test "envelope defaults are stable" do
      defaults = @snapshot["envelope"]["defaults"]
      e = %Event{}
      assert e.v == defaults["v"]
      assert to_string(e.family) == defaults["family"]
      assert to_string(e.tier) == defaults["tier"]
    end

    test "every snapshotted tier and family enum value is still accepted by the neutral seam" do
      for tier <- @snapshot["enums"]["tier"] do
        # EmitBus.build guards the tier — a removed enum value raises here.
        event =
          EmitBus.build("s", :app_update, String.to_existing_atom(tier), %{})

        assert to_string(event.tier) == tier
      end

      for family <- @snapshot["enums"]["family"] do
        event =
          EmitBus.build("s", :app_update, :durable, %{}, family: String.to_existing_atom(family))

        assert to_string(event.family) == family
      end
    end
  end

  # ===========================================================================
  # Producer 1: Contract.pump — every snapshotted shape still producible
  # ===========================================================================

  describe "I9 — pump producer" do
    test "a scripted stream reproduces every snapshotted event type + item_type variant with all required payload fields" do
      session_id = "inv-contract-pump-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "chunk one"},
        {:tool_use, %{name: "read_file", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "read_file", result: "contents"}},
        {:turn_complete, %{iteration: 1, usage: %{input_tokens: 1}}},
        {:done, %{content: "final answer", usage: %{output_tokens: 2}}}
      ]

      task =
        Task.async(fn -> Contract.pump(session_id, stream, prompt: "p") end)

      assert {:ok, %{content: "final answer"}} = Task.await(task)

      events = collect_events(session_id)
      producers = @snapshot["producers"]["pump"]

      # Event-type removal check: every snapshotted type (except :error,
      # covered below) came out of the pipe.
      seen_types = events |> Enum.map(&to_string(&1.type)) |> MapSet.new()

      for type <- @snapshot["enums"]["type"], type != "error" do
        assert type in seen_types,
               "pump can no longer produce #{type} — event-type removal"
      end

      # Tier assignment per snapshot (tier flips break replay semantics).
      for e <- events do
        expected_tier = @snapshot["event_types"][to_string(e.type)]["tier"]
        assert to_string(e.tier) == expected_tier, "#{e.type} flipped tier"
      end

      # item_type enum: every snapshotted variant still producible.
      seen_item_types =
        for %Event{type: :item_completed, payload: %{item_type: it}} <- events,
            into: MapSet.new(),
            do: to_string(it)

      for it <- @snapshot["enums"]["item_type"] do
        assert it in seen_item_types,
               "item_completed lost item_type variant #{it}"
      end

      # Required payload fields per producer shape (removal / rename /
      # required→optional all surface as a missing key on a produced event).
      for e <- events do
        key = pump_shape_key(e)
        required = producers[key]["payload_required"] || []

        for field <- required do
          assert Map.has_key?(e.payload, String.to_existing_atom(field)),
                 "pump #{key} lost required payload field #{field}: #{inspect(e.payload)}"
        end
      end

      # Field-type stability (narrowing check) on the envelope.
      for e <- events do
        assert is_integer(e.id) and e.id >= 0
        assert is_integer(e.ts)
        assert is_atom(e.family) and is_atom(e.type) and is_atom(e.tier)
        assert is_map(e.payload)
        assert e.session_id == session_id
        assert is_binary(e.turn_id)
      end
    end

    test "the pump error shape is stable" do
      session_id = "inv-contract-pumperr-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      task =
        Task.async(fn ->
          Contract.pump(session_id, [{:error, :kaboom}], prompt: "p")
        end)

      assert {:error, :kaboom} = Task.await(task)

      events = collect_events(session_id)
      error = Enum.find(events, &(&1.type == :error))
      assert error, "pump lost the :error event type"
      assert to_string(error.tier) == @snapshot["event_types"]["error"]["tier"]

      for field <- @snapshot["producers"]["pump"]["error"]["payload_required"] do
        assert Map.has_key?(error.payload, String.to_existing_atom(field))
      end
    end
  end

  # ===========================================================================
  # Producer 2: Dispatcher -> EmitBridge — mapping + journal record shape
  # ===========================================================================

  describe "I9 — dispatcher/bridge producer" do
    test "the neutral→contract mapping and journal record shape match the snapshot",
         %{base: base} do
      session_id = "inv-contract-bridge-#{System.unique_integer([:positive])}"
      {:ok, streamer} = SessionStreamer.start_link(name: nil)

      {:ok, bridge} =
        EmitBridge.start_link(
          session_id: session_id,
          streamer: streamer,
          journal_opts: [base_dir: base]
        )

      :ok = SessionStreamer.subscribe(session_id, streamer)

      # One neutral event per snapshotted mapping entry (durables mirror the
      # Dispatcher's real tier choices; command_result is the ephemeral leg).
      neutral_payloads = %{
        "turn_started" => %{message: "prompt"},
        "app_update" => %{message: "folded"},
        "command_result" => %{message: "delta"},
        "turn_completed" => %{},
        "error" => %{reason: "boom"},
        "_fallback" => %{message: "unknown"}
      }

      mapping = @snapshot["neutral_to_contract"]

      produced =
        for {neutral, contract} <- mapping do
          {neutral_type, tier} =
            case neutral do
              "command_result" -> {:command_result, :ephemeral}
              "_fallback" -> {:some_future_neutral_type, :durable}
              other -> {String.to_atom(other), :durable}
            end

          payload = Map.fetch!(neutral_payloads, neutral)

          EmitBus.publish(EmitBus.build(session_id, neutral_type, tier, payload, turn_id: "t1"))

          ev = await_event!(session_id)

          assert to_string(ev.type) == contract,
                 "neutral #{neutral} now maps to #{ev.type}, snapshot says #{contract} — " <>
                   "mapping rename/removal"

          ev
        end

      # Journal record shape: every durable record carries the full snapshotted
      # key set (writer-injected fields included) and the durable-only tier.
      dir = Path.join(base, session_id)
      required = @snapshot["journal_record"]["required"]

      for record <- FaultJournal.raw_records!(dir) do
        for key <- required do
          assert Map.has_key?(record, key),
                 "journal record lost required key #{key}: #{inspect(record)}"
        end

        assert record["tier"] == @snapshot["journal_record"]["tier_always"]
        assert record["schema_version"] == @snapshot["schema_version"]
      end

      # Ephemerals never journaled (the wall, re-checked at the contract level).
      journal_types = FaultJournal.raw_records!(dir) |> Enum.map(& &1["type"])
      refute "item_delta" in journal_types

      _ = produced
      GenServer.stop(bridge)
      GenServer.stop(streamer)
    end

    test "the bridge failure signal shape is stable", %{base: base} do
      session_id = "inv-contract-fail-#{System.unique_integer([:positive])}"
      {:ok, streamer} = SessionStreamer.start_link(name: nil)

      {:ok, bridge} =
        EmitBridge.start_link(
          session_id: session_id,
          streamer: streamer,
          journal_opts: [base_dir: base]
        )

      :ok = SessionStreamer.subscribe(session_id, streamer)

      # Open, then kill the writer to force the append-failure signal.
      EmitBus.publish(EmitBus.build(session_id, :turn_started, :durable, %{message: "p"}))

      _started = await_event!(session_id)

      %{journal: %FileStore{writer: writer}} = :sys.get_state(bridge)
      GenServer.stop(writer)

      EmitBus.publish(EmitBus.build(session_id, :app_update, :durable, %{message: "lost"}))

      failure = await_event!(session_id)

      spec = @snapshot["producers"]["bridge_failure_signal"]
      assert to_string(failure.type) == spec["type"]
      assert to_string(failure.tier) == spec["tier"]

      for field <- spec["payload_required"] do
        assert Map.has_key?(failure.payload, String.to_existing_atom(field))
      end

      assert to_string(failure.payload.reason) in @snapshot["enums"][
               "journal_failure_reason"
             ]

      GenServer.stop(bridge)
      GenServer.stop(streamer)
    end
  end

  # ===========================================================================
  # Golden journal corpus (the upcast seed)
  # ===========================================================================

  describe "I9 — golden journal fixture v1.0.0" do
    test "the checked-in golden journal opens, replays fully, validates against the snapshot, and accepts appends",
         %{base: base} do
      # Work on a COPY — the fixture itself is immutable history.
      File.cp_r!(@golden, Path.join(base, "golden-v1"))

      {:ok, j} = FileStore.open("golden-v1", base_dir: base)
      assert {:ok, records} = FileStore.read(j)
      assert FileStore.status(j) == :ok

      n = length(records)

      assert n == 8,
             "golden corpus changed size — regenerate deliberately, never accidentally"

      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..n)

      for record <- records do
        for key <- @snapshot["journal_record"]["required"] do
          assert Map.has_key?(record, key),
                 "current reader dropped required key #{key} from a v1.0.0 record"
        end

        assert record["type"] in @snapshot["enums"]["type"]
        assert record["tier"] == "durable"
        assert record["family"] in @snapshot["enums"]["family"]
        assert record["schema_version"] == "1.0.0"
        assert is_integer(record["ts"]) and is_map(record["payload"])
      end

      # Every event type present in the corpus (so a future upcast that drops a
      # type cannot pass by luck). Exemptions: item_delta is ephemeral (never
      # journaled), and item_started postdates the v1.0.0 corpus (pump grew
      # the item lifecycle in 2026-07; grow-only, so a journal written before
      # the growth stays valid history -- the grandfather clause).
      corpus_types = records |> Enum.map(& &1["type"]) |> MapSet.new()

      for type <- @snapshot["enums"]["type"],
          type not in ["item_delta", "item_started"] do
        assert type in corpus_types, "golden corpus is missing #{type}"
      end

      # The current writer continues the historical sequence.
      assert {:ok, 9} = FileStore.append(j, %{"type" => "chunk", "n" => 9})
      :ok = FileStore.close(j)
    end
  end

  describe "I9 — golden journal fixture for the current schema_version" do
    test "the writer's current default has a frozen corpus the manifest pins" do
      assert @current_session,
             "the Writer defaults to schema_version #{@current_version} but " <>
               "fixtures/golden/MANIFEST.json pins no corpus for it — freeze one " <>
               "(packages/raxol_agent/scripts/freeze_golden_journal.exs) before the " <>
               "version moves on and the material becomes unrecoverable"

      assert @manifest["current_schema_version"] == @current_version
      assert File.dir?(@current_golden)
    end

    test "the frozen corpus opens, replays, and carries every shape the version added",
         %{base: base} do
      File.cp_r!(@current_golden, Path.join(base, @current_session))

      {:ok, j} = FileStore.open(@current_session, base_dir: base)
      assert {:ok, records} = FileStore.read(j)
      assert FileStore.status(j) == :ok

      n = length(records)
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..n)

      for record <- records do
        for key <- @snapshot["journal_record"]["required"] do
          assert Map.has_key?(record, key),
                 "current reader dropped required key #{key} from a #{@current_version} record"
        end

        assert record["type"] in @snapshot["enums"]["type"]
        assert record["tier"] == "durable"
        assert record["family"] in @snapshot["enums"]["family"]
        assert record["schema_version"] == @current_version
        assert is_integer(record["ts"]) and is_map(record["payload"])
      end

      # item_delta is ephemeral and never journaled; everything else must be
      # in the corpus, so a future upcast cannot skip a type by luck.
      corpus_types = records |> Enum.map(& &1["type"]) |> MapSet.new()

      for type <- @snapshot["enums"]["type"], type != "item_delta" do
        assert type in corpus_types,
               "the #{@current_version} corpus is missing #{type}"
      end

      corpus_item_types =
        for %{"type" => "item_completed", "payload" => %{"item_type" => it}} <-
              records,
            into: MapSet.new(),
            do: it

      for it <- @snapshot["enums"]["item_type"] do
        assert it in corpus_item_types,
               "the #{@current_version} corpus is missing item_type #{it}"
      end

      assert {:ok, _next} =
               FileStore.append(j, %{"type" => "chunk", "n" => n + 1})

      :ok = FileStore.close(j)
    end

    test "the corpus carries all three evidence states, and each one decodes",
         %{base: base} do
      File.cp_r!(@current_golden, Path.join(base, @current_session))
      {:ok, j} = FileStore.open(@current_session, base_dir: base)
      {:ok, records} = FileStore.read(j)

      dones =
        Enum.filter(records, fn r ->
          r["type"] == "turn_completed" and r["payload"]["final"] == true
        end)

      statuses = Map.new(dones, &{Contract.evidence_status(&1["payload"]), &1})

      # The 1.1.0 marker's whole point: a rejected done and a never-offered
      # done stopped being wire-identical. A corpus that cannot tell them
      # apart is not test material for the upcast that has to preserve them.
      for state <- [:accepted, :rejected, :absent] do
        assert Map.has_key?(statuses, state),
               "the #{@current_version} corpus has no turn_completed decoding as #{state} — " <>
                 "it cannot exercise the marker it was frozen to preserve"
      end

      # accepted: refs is untouched as the carrier, and names real records.
      accepted = statuses[:accepted]
      assert is_list(accepted["payload"]["refs"])
      assert accepted["payload"]["refs"] != []

      by_id = Map.new(records, &{&1["id"], &1})

      for ref <- accepted["payload"]["refs"] do
        cited = Map.fetch!(by_id, ref)

        assert cited["payload"]["item_type"] == "tool_result",
               "an accepted ref must name evidence, not a self-report"

        assert cited["turn_id"] == accepted["turn_id"],
               "an accepted ref must belong to the claiming turn"
      end

      # rejected: the verdict is flattened onto the wire, never inspect/1'd.
      detail = statuses[:rejected]["payload"]["evidence_rejected"]
      assert %{"refs" => refs, "reason" => reason, "ref" => ref} = detail
      assert is_list(refs) and is_integer(ref)
      refute reason =~ "{"
      refute reason =~ ":"

      assert Map.has_key?(by_id, ref),
             "the offending ref must name a real record"

      # absent: no detail, no refs — the turn offered nothing.
      absent = statuses[:absent]["payload"]
      refute Map.has_key?(absent, "refs")
      refute Map.has_key?(absent, "evidence_rejected")

      :ok = FileStore.close(j)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp pump_shape_key(%Event{type: :item_completed, payload: %{item_type: it}}),
    do: "item_completed.#{it}"

  defp pump_shape_key(%Event{type: type}), do: to_string(type)

  defp collect_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = ev} ->
        collect_events(session_id, acc ++ [ev])
    after
      200 -> acc
    end
  end

  defp await_event!(session_id) do
    receive do
      {:session_event, ^session_id, %Event{} = ev} -> ev
    after
      2_000 -> flunk("no event arrived for #{session_id}")
    end
  end
end
