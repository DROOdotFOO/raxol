defmodule Raxol.Agent.ContractTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event

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

    # S1 (PR #631, Drew's reproduction) — the decoder must be TOTAL. The
    # `evidence` enum is grow-only (AD-11 upcast-on-read): a reader on 1.1.0
    # WILL meet a future 1.2.0 journal carrying a 4th value, and a corrupt or
    # forged line can carry anything. Before the fix `normalize_evidence/1` had
    # exactly three clauses and raised `FunctionClauseError` on the replay
    # surface. Every unrecognized value must degrade to `:unknown`, never crash,
    # never `:accepted`.
    test "a future/unknown string enum value decodes to :unknown (Drew's exact repro), never crashes" do
      # Drew's reproduction: a 1.2.0 journal's 4th evidence value replayed as a
      # JSON string on a 1.1.0 reader.
      assert Contract.evidence_status(%{"evidence" => "verified_v2"}) == :unknown
    end

    test "a future/unknown atom enum value decodes to :unknown" do
      assert Contract.evidence_status(%{evidence: :verified_v2}) == :unknown
    end

    test "a garbage-typed evidence value decodes to :unknown, never crashes" do
      for garbage <- [42, nil, true, %{}, [1, 2, 3], {:tuple, :val}, 3.14] do
        assert Contract.evidence_status(%{evidence: garbage}) == :unknown,
               "garbage evidence value #{inspect(garbage)} did not decode :unknown"

        assert Contract.evidence_status(%{"evidence" => garbage}) == :unknown,
               "string-keyed garbage evidence #{inspect(garbage)} did not decode :unknown"
      end
    end

    test "an unrecognized authoritative marker never launders to :accepted, even with refs present" do
      # S2 hardening face: the `evidence` key IS present (not a legacy record),
      # so the refs-grandfather arm must never be consulted — a forged/unknown
      # marker value sitting atop a refs list decodes :unknown, NOT :accepted.
      assert Contract.evidence_status(%{"evidence" => "bogus", "refs" => [3]}) ==
               :unknown

      refute Contract.evidence_status(%{"evidence" => "bogus", "refs" => [3]}) ==
               :accepted

      assert Contract.evidence_status(%{evidence: :forged, refs: [1, 2]}) ==
               :unknown
    end
  end
end
