defmodule Raxol.Agent.ContractTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  defp mock_stream(response) do
    Raxol.Agent.Stream.run("prompt",
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [response: response]
    )
  end

  describe "pump/3" do
    test "maps a completed run onto the v0 vocabulary, in order" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      assert {:ok, %{content: content}} =
               Contract.pump(session_id, mock_stream("Hello!"), prompt: "hi")

      assert content =~ "Hello"

      events = drain_events(session_id)
      types = Enum.map(events, & &1.type)

      assert List.first(types) == :turn_started
      assert List.last(types) == :turn_completed
      assert :item_completed in types

      # the final turn_completed closes the run
      assert %Event{payload: %{final: true}} = List.last(events)

      # ids are monotonic from 1
      assert Enum.map(events, & &1.id) == Enum.to_list(1..length(events))

      # one turn: every event shares session and turn ids
      assert Enum.uniq(Enum.map(events, & &1.session_id)) == [session_id]
      assert [_turn_id] = Enum.uniq(Enum.map(events, & &1.turn_id))
    end

    test "text deltas are ephemeral; completed items are durable" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      {:ok, _} = Contract.pump(session_id, mock_stream("chunky"), prompt: "hi")

      events = drain_events(session_id)

      for %Event{type: :item_delta} = event <- events do
        assert event.tier == :ephemeral
      end

      for %Event{type: type} = event <- events, type != :item_delta do
        assert event.tier == :durable
      end
    end

    test "the done gate is consulted on the real done path: independent postdating evidence closes gated with refs" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # A tool_use (mutation) followed by a tool_result of a DIFFERENT tool
      # name — an independent verification output that postdates the mutation
      # and is not its own echo. The gate accepts, so the final turn_completed
      # carries the evidence ref (offset 3: turn_started=1, tool_use=2, result=3).
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.type == :turn_completed
      assert final.payload.final == true
      assert final.payload.refs == [3]
    end

    test "a mutation's own result echo is rejected: done closes fail-open with rejected_evidence telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "u21-rejected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :rejected_evidence],
        fn _e, _m, metadata, _c -> send(test_pid, {:rejected_evidence, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # The only tool_result postdating the mutation is that same call's echo
      # (same tool name) — the gate rejects it as :mutation_echo. Completion
      # stays fail-open: still final: true, no refs, plus telemetry.
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:rejected_evidence, %{reason: {:mutation_echo, _}}}
    end

    test "a zero-tool turn closes ungated (parked policy) and emits done-gate telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "u21-ungated-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :ungated_done],
        fn _e, _m, metadata, _c -> send(test_pid, {:ungated_done, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = Contract.pump(session_id, mock_stream("plain answer"), prompt: "hi")

      final = session_id |> drain_events() |> List.last()

      # Parked zero-tool policy preserved: still final: true, no refs attached.
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:ungated_done, %{turn_id: turn_id}}
      assert is_binary(turn_id)
    end

    test "an error stream yields an :error event and error return" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      error_stream = [{:error, {:http, 500, "boom"}}]

      assert {:error, {:http, 500, "boom"}} =
               Contract.pump(session_id, error_stream, prompt: "hi")

      events = drain_events(session_id)
      assert Enum.any?(events, &(&1.type == :error))
    end
  end

  describe "U21 evidence tri-state wire marker (#619 residual)" do
    # Before the marker: a REJECTED done (evidence offered, gate refused it)
    # and a NEVER-OFFERED done (:evidence_required — no refs at all) both
    # close with the exact same payload shape: `%{usage, final: true}`, no
    # `refs`, no other discriminator. Telemetry distinguishes them live, but
    # telemetry is not journaled, so a replayed/attached surface (the UI
    # lane's T19 renderer) cannot tell "rejected" from "absent" after the
    # fact. These two payloads pin that gap and must stop matching once the
    # marker lands.
    test "a rejected done and a never-offered done are indistinguishable without the marker" do
      session_id = "u21-marker-rejected-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # Rejected arm: the only postdating tool_result is the mutation's own
      # echo (:mutation_echo) — evidence was offered and refused.
      rejected_stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, rejected_stream, prompt: "p")
      rejected_final = session_id |> drain_events() |> List.last()

      # Absent arm: a zero-tool turn — no evidence ever offered.
      absent_session_id = "u21-marker-absent-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(absent_session_id)

      {:ok, _} = Contract.pump(absent_session_id, mock_stream("plain answer"), prompt: "hi")
      absent_final = absent_session_id |> drain_events() |> List.last()

      # Both close `final: true` with no `refs` — the wire-identical shape
      # this marker exists to break.
      assert rejected_final.payload.final == true
      assert absent_final.payload.final == true
      refute Map.has_key?(rejected_final.payload, :refs)
      refute Map.has_key?(absent_final.payload, :refs)

      # The marker: once stamped, these must diverge.
      assert rejected_final.payload[:evidence] == :rejected
      assert absent_final.payload[:evidence] == :absent
      assert rejected_final.payload[:evidence] != absent_final.payload[:evidence]
    end

    test "accepted done carries evidence: :accepted alongside the untouched refs carrier" do
      session_id = "u21-marker-accepted-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      assert final.payload.evidence == :accepted
      assert final.payload.refs == [3]
      refute Map.has_key?(final.payload, :evidence_rejected)
    end

    test "rejected done carries evidence_rejected with the DoneGate reason flattened onto the wire, never inspect-stringified" do
      session_id = "u21-marker-detail-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      assert final.payload.evidence == :rejected

      assert %{"refs" => offered_refs, "reason" => reason, "ref" => offending_ref} =
               final.payload.evidence_rejected

      assert is_list(offered_refs)
      assert reason == "mutation_echo"
      assert is_integer(offending_ref)

      # Never `inspect/1`-stringified (that would look like "{:mutation_echo, 3}").
      refute reason =~ "{"
      refute reason =~ ":"

      # Survives a real JSON round-trip (the actual wire path).
      line = final |> Contract.encode_line() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert decoded["payload"]["evidence"] == "rejected"

      assert decoded["payload"]["evidence_rejected"] == %{
               "refs" => offered_refs,
               "reason" => "mutation_echo",
               "ref" => offending_ref
             }
    end

    test "absent done (:evidence_required) carries evidence: :absent and no evidence_rejected detail" do
      session_id = "u21-marker-absent-detail-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      {:ok, _} = Contract.pump(session_id, mock_stream("plain answer"), prompt: "hi")
      final = session_id |> drain_events() |> List.last()

      assert final.payload.evidence == :absent
      refute Map.has_key?(final.payload, :evidence_rejected)
      refute Map.has_key?(final.payload, :refs)
    end

    test "the DoneGate reject reason is not observable on the wire before the marker (telemetry-only today)" do
      # This test pins the CURRENT payload shape's ceiling: nothing about
      # *why* the gate rejected survives onto `final.payload` apart from the
      # new `evidence_rejected` detail this PR adds. It guards against a
      # future regression that puts the raw verdict tuple (or an
      # `inspect/1` rendering of it) directly under an unexpected key.
      session_id = "u21-marker-reason-shape-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      allowed_keys = MapSet.new([:usage, :final, :evidence, :evidence_rejected])
      assert MapSet.new(Map.keys(final.payload)) |> MapSet.subset?(allowed_keys)

      refute Map.has_key?(final.payload, :reason)
      refute Map.has_key?(final.payload, :ref)
    end
  end

  describe "evidence_status/1 (grandfather decode rule)" do
    test "an authoritative marker key wins outright" do
      assert Contract.evidence_status(%{evidence: :accepted}) == :accepted
      assert Contract.evidence_status(%{evidence: :rejected, refs: []}) == :rejected
      assert Contract.evidence_status(%{evidence: :absent}) == :absent

      # String-keyed / string-valued (as replayed off the journal via
      # Jason.decode).
      assert Contract.evidence_status(%{"evidence" => "accepted"}) == :accepted
      assert Contract.evidence_status(%{"evidence" => "rejected"}) == :rejected
      assert Contract.evidence_status(%{"evidence" => "absent"}) == :absent
    end

    test "legacy record (no evidence key) with refs present grandfathers to :accepted" do
      assert Contract.evidence_status(%{final: true, refs: [3]}) == :accepted
      assert Contract.evidence_status(%{"final" => true, "refs" => [3]}) == :accepted
    end

    test "legacy record (no evidence key, no refs) is genuinely unknown — never guessed as :absent" do
      assert Contract.evidence_status(%{final: true, usage: %{}}) == :unknown
      assert Contract.evidence_status(%{"final" => true, "usage" => %{}}) == :unknown

      # In particular it must NOT be `:absent`: that would launder a
      # historical rejection into a false "never offered" claim.
      refute Contract.evidence_status(%{final: true, usage: %{}}) == :absent
    end
  end

  describe "encode_line/1" do
    test "produces one decodable JSON line per event" do
      event = %Event{
        id: 1,
        session_id: "s",
        turn_id: "t",
        ts: 123,
        type: :turn_started,
        payload: %{prompt: "hi"}
      }

      line = event |> Contract.encode_line() |> IO.iodata_to_binary()
      assert String.ends_with?(line, "\n")

      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert decoded["type"] == "turn_started"
      assert decoded["payload"]["prompt"] == "hi"
      assert decoded["tier"] == "durable"
    end

    test "sanitizes non-JSON payload terms instead of crashing" do
      event = %Event{
        id: 1,
        session_id: "s",
        turn_id: "t",
        ts: 123,
        type: :error,
        payload: %{reason: {:http, 500, {:nested, :tuple}}}
      }

      line = event |> Contract.encode_line() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert is_binary(decoded["payload"]["reason"])
      assert decoded["payload"]["reason"] =~ "http"
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = event} ->
        drain_events(session_id, [event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
