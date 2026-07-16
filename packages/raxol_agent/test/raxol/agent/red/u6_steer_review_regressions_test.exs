defmodule Raxol.Agent.Red.U6SteerReviewRegressionsTest do
  @moduledoc """
  Regressions from the PR #573 adversarial review of `Raxol.Agent.Steer`.

  Each test pins a fix (or a load-bearing property the review showed was
  prose-only). These are NOT contours — they drive the shipped implementation
  directly, and several assert its resource shape, which the reference oracle
  and injectors deliberately do not share (differential testing keeps them
  naive and independent).

  Findings covered (review comment on PR #573):

    * HIGH resource-exhaustion: the dedup index must not retain client-sized
      text, and accepts must not be O(n) in the log (prepend + monotone
      counter, never `length/1` + `++`).
    * MEDIUM rebuild coherence: `rebuild/1` keeps only steer records in `log`,
      and the post-restart offset continues the STEER sequence — never
      `length(whole mixed journal) + 1`.
    * MEDIUM ABA-via-persisted-token: a swap token is structurally
      unjournalable (a tuple — the Jason Writer refuses it), so "MUST NOT
      persist a swap token" is enforced by the wire format, not prose.
    * LOW payload nil-vs-absent: a payload key explicitly present with a `nil`
      value must NOT fall through to a top-level value of the same name.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Steer
  alias Raxol.Agent.Steer.{Request, TurnState}

  @turn "turn-A"

  defp initial, do: %TurnState{turn_id: @turn, seen: %{}, log: []}

  describe "dedup index is bounded per entry (HIGH: client-controlled memory)" do
    test "the seen entry for a large text retains a constant-size fingerprint, never the text" do
      big = String.duplicate("x", 1_000_000)
      req = %Request{expected_turn_id: @turn, client_msg_id: "m-big", text: big}

      {{:ok, {:accepted, _ref}}, next} = Steer.resolve(initial(), req)

      entry = Map.fetch!(next.seen, "m-big")

      # The durable event still carries the full text (the journal is the
      # record of what was said) — only the dedup INDEX must not.
      assert hd(next.log).payload.text == big

      big_binaries =
        entry
        |> collect_binaries()
        |> Enum.filter(&(byte_size(&1) > 64))

      assert big_binaries == [],
             "the dedup index retained a client-sized binary (#{length(big_binaries)} found) — " <>
               "an adversarial client streaming large texts grows resident memory by its own payload size"
    end

    test "dedup and reuse-reject still fire on large texts (fingerprint equality stands in for text equality)" do
      big = String.duplicate("y", 500_000)
      req = %Request{expected_turn_id: @turn, client_msg_id: "m-fp", text: big}

      {{:ok, {:accepted, ref}}, next} = Steer.resolve(initial(), req)

      assert {{:ok, {:duplicate, ^ref}}, ^next} = Steer.resolve(next, req)

      reuse = %Request{expected_turn_id: @turn, client_msg_id: "m-fp", text: big <> "!"}
      assert {{:error, :client_msg_id_reuse}, ^next} = Steer.resolve(next, reuse)
    end
  end

  describe "accepts are O(1) over the log (HIGH: quadratic amortization)" do
    test "the log is prepend-ordered (newest first) and offsets come from a monotone counter" do
      state = initial()

      {_results, final} =
        Enum.map_reduce(1..50, state, fn i, s ->
          req = %Request{expected_turn_id: s.turn_id, client_msg_id: "m-#{i}", text: "t-#{i}"}
          {{:ok, {:accepted, ref}}, s2} = Steer.resolve(s, req)
          assert ref.offset == i, "offsets must be the monotone steer sequence 1..N"
          {ref, s2}
        end)

      assert final.last_offset == 50

      # Newest first: hd/1 is the most recent accept, O(1) prepends — a
      # `log ++ [event]` implementation (O(n) per accept, O(n²) per session)
      # would put the OLDEST event at the head and fail here.
      assert hd(final.log).payload.text == "t-50"
      assert List.last(final.log).payload.text == "t-1"
    end
  end

  describe "rebuild coherence over a mixed journal (MEDIUM)" do
    # A realistic scanned journal: turn brackets and other families interleaved
    # with steer records, string-keyed as the FileStore Reader returns them.
    defp mixed_journal do
      [
        %{"type" => "turn_started", "id" => 1, "payload" => %{}},
        %{
          "type" => "steer",
          "id" => 2,
          "turn_id" => "turn-old",
          "offset" => 1,
          "payload" => %{"client_msg_id" => "m-old-1", "text" => "left"}
        },
        %{"type" => "model_delta", "id" => 3, "payload" => %{"chunk" => "…"}},
        %{
          "type" => "steer",
          "id" => 4,
          "turn_id" => "turn-old",
          "offset" => 2,
          "payload" => %{"client_msg_id" => "m-old-2", "text" => "right"}
        },
        %{"type" => "turn_ended", "id" => 5, "payload" => %{}}
      ]
    end

    test "rebuild keeps ONLY steer records in log, newest first" do
      rebuilt = Steer.rebuild(mixed_journal())

      assert length(rebuilt.log) == 2,
             "log must hold steer records only, got #{length(rebuilt.log)} (the whole mixed journal?)"

      assert Enum.map(rebuilt.log, & &1["offset"]) == [2, 1]
    end

    test "a post-restart accept continues the steer sequence, not length(mixed journal) + 1" do
      rebuilt = %{Steer.rebuild(mixed_journal()) | turn_id: "turn-new"}

      req = %Request{expected_turn_id: "turn-new", client_msg_id: "m-new", text: "up"}
      {{:ok, {:accepted, ref}}, next} = Steer.resolve(rebuilt, req)

      # Two steers landed before the restart, so the next steer is #3. The
      # pre-fix positional guess over the whole 5-record journal gave 6.
      assert ref.offset == 3,
             "post-restart offset must continue the STEER sequence (3), got #{ref.offset}"

      assert next.last_offset == 3

      # And the rebuilt dedup refs stay coherent with the same sequence.
      assert next.seen["m-old-2"].ref.offset == 2
    end
  end

  describe "swap tokens are structurally unjournalable (MEDIUM: ABA via persisted token)" do
    test "the post-accept turn_id cannot be encoded by the Jason journal Writer" do
      req = %Request{expected_turn_id: @turn, client_msg_id: "m-tok", text: "go"}
      {{:ok, {:accepted, _}}, next} = Steer.resolve(initial(), req)

      # The moduledoc invariant "MUST NOT persist a swap token as a CAS target"
      # is enforced by the wire format: the token is a tuple, and Jason refuses
      # tuples — journaling one fails LOUDLY. A refactor to a Jason-encodable
      # token space (string/integer) would silently re-open the post-restart
      # ABA window Drew flagged, and must trip this pin first.
      assert_raise Protocol.UndefinedError, fn -> Jason.encode!(next.turn_id) end
    end

    test "rebuild never revives a token: turn_id is nil until the runtime installs the journal-bracket turn" do
      req = %Request{expected_turn_id: @turn, client_msg_id: "m-nil", text: "go"}
      {{:ok, {:accepted, _}}, next} = Steer.resolve(initial(), req)

      assert Steer.rebuild(next.log).turn_id == nil
    end
  end

  describe "payload key present-with-nil vs absent (LOW)" do
    test "an explicit nil payload text does NOT fall through to a top-level decoy value" do
      # A record whose payload EXPLICITLY carries text: nil (a legal nil-text
      # steer), with a same-named top-level field. The tolerant reader must
      # honour the payload's nil, not leak the top-level value.
      record = %{
        "type" => "steer",
        "id" => 1,
        "turn_id" => "turn-old",
        "offset" => 1,
        "text" => "DECOY — never the payload's value",
        "payload" => %{"client_msg_id" => "m-niltext", "text" => nil}
      }

      rebuilt = %{Steer.rebuild([record]) | turn_id: "turn-new"}

      # Re-delivery of the original (nil-text) command → duplicate.
      dup = %Request{expected_turn_id: "turn-new", client_msg_id: "m-niltext", text: nil}
      assert {{:ok, {:duplicate, _}}, _} = Steer.resolve(rebuilt, dup)

      # Re-delivery carrying the decoy text → reuse reject. The pre-fix reader
      # (nil falls through to top level) had these two INVERTED.
      reuse = %Request{
        expected_turn_id: "turn-new",
        client_msg_id: "m-niltext",
        text: "DECOY — never the payload's value"
      }

      assert {{:error, :client_msg_id_reuse}, _} = Steer.resolve(rebuilt, reuse)
    end
  end

  # Every binary reachable inside a term (for the retention check).
  defp collect_binaries(term) when is_binary(term), do: [term]
  defp collect_binaries(term) when is_list(term), do: Enum.flat_map(term, &collect_binaries/1)

  defp collect_binaries(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&collect_binaries/1)

  defp collect_binaries(term) when is_map(term) do
    Enum.flat_map(term, fn {k, v} -> collect_binaries(k) ++ collect_binaries(v) end)
  end

  defp collect_binaries(_term), do: []
end
