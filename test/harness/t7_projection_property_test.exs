defmodule Raxol.Harness.T7ProjectionPropertyTest do
  @moduledoc """
  Property-based tests for roadmap unit T7's generator inventory
  (`Raxol.Harness.Fixture.Gen` would be a natural shared home for these;
  they are kept local to this test file to respect T7's write-set --
  see `t7_projection_test.exs`'s moduledoc for the fixture-format
  deviations this unit made).

  Generators build event lists shaped exactly like the fixture wire
  format (string-keyed payloads, atom top-level fields) rather than
  Block's looser "any atom-keyed map" tolerance, so what's tested here
  matches what a real recorded session looks like.

  ## Noise construction is realism-constrained

  `id` is a monotonic journal offset (protocol §3) -- an append-only
  log never renumbers an already-assigned id just because more events
  showed up later. So "insert noise, then compare" is built as: bake
  the noise INTO one session at construction time (ids assigned once,
  in final order), then derive the noise-free comparison variant by
  FILTERING it back out (ids of the surviving events untouched, now
  with gaps) -- exactly the pattern `P-TIER-03` in `t7_projection_test.exs`
  already uses for stripped deltas. Retrofitting noise into an
  already-numbered compact session and renumbering everything
  afterward was tried first and rejected: it shifts unrelated durable
  events' ids, which cannot happen to a real journal and made the
  property fail for the wrong reason.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.Projection

  @sessions_dir "test/fixtures/harness/sessions"
  @golden_names ~w(simple-chat multi-tool-turn long-folds unicode-heavy taint-propagation)

  defp load!(name),
    do: Fixture.load(Path.join(@sessions_dir, name <> ".jsonl")) |> elem(1)

  # -- generators -------------------------------------------------------------

  defp item_kind_gen, do: member_of([:message, :reasoning, :tool_pair])

  defp item_kinds_gen,
    do: list_of(item_kind_gen(), min_length: 1, max_length: 4)

  defp new_state, do: %{events: [], id: 1, ts: 1000}

  defp emit(state, turn_id, type, payload, tier \\ :durable) do
    event = %{
      id: state.id,
      turn_id: turn_id,
      ts: state.ts,
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }

    %{
      state
      | events: [event | state.events],
        id: state.id + 1,
        ts: state.ts + 10
    }
  end

  # `extra_delta_count` is baked into every :message item at
  # construction time (ids assigned once, in order) -- see moduledoc.
  defp build_item(state, turn_id, :message, label, extra_delta_count) do
    item_id = "msg-#{label}"

    state =
      emit(state, turn_id, :item_started, %{
        "item_id" => item_id,
        "item_type" => "message"
      })

    state =
      Enum.reduce(1..extra_delta_count//1, state, fn n, acc ->
        emit(
          acc,
          turn_id,
          :item_delta,
          %{"item_id" => item_id, "chunk" => "chunk-#{n}"},
          :ephemeral
        )
      end)

    emit(state, turn_id, :item_completed, %{
      "item_id" => item_id,
      "item_type" => "message",
      "content" => "message-content-#{label}"
    })
  end

  defp build_item(state, turn_id, :reasoning, label, _extra_delta_count) do
    item_id = "reason-#{label}"

    state
    |> emit(turn_id, :item_started, %{
      "item_id" => item_id,
      "item_type" => "reasoning"
    })
    |> emit(turn_id, :item_completed, %{
      "item_id" => item_id,
      "item_type" => "reasoning",
      "content" => "reasoning-content-#{label}"
    })
  end

  defp build_item(state, turn_id, :tool_pair, label, _extra_delta_count) do
    use_id = "use-#{label}"
    result_id = "result-#{label}"

    state
    |> emit(turn_id, :item_started, %{
      "item_id" => use_id,
      "item_type" => "tool_use"
    })
    |> emit(turn_id, :item_completed, %{
      "item_id" => use_id,
      "item_type" => "tool_use",
      "name" => "tool-#{label}",
      "arguments" => %{"n" => label}
    })
    |> emit(turn_id, :item_started, %{
      "item_id" => result_id,
      "item_type" => "tool_result"
    })
    |> emit(turn_id, :item_completed, %{
      "item_id" => result_id,
      "item_type" => "tool_result",
      "name" => "tool-#{label}",
      "content" => "tool-result-#{label}"
    })
  end

  # `meta_count` events, always appended AFTER turn_completed (a probe
  # observation about the wrapped-up session) -- pure append, so no
  # existing id ever shifts.
  defp build_session(item_kinds, extra_delta_count \\ 0, meta_count \\ 0) do
    state = new_state() |> emit("t1", :turn_started, %{})

    final =
      item_kinds
      |> Enum.with_index()
      |> Enum.reduce(state, fn {kind, idx}, acc ->
        build_item(acc, "t1", kind, idx, extra_delta_count)
      end)
      |> emit("t1", :turn_completed, %{})

    events = Enum.reverse(final.events)
    events ++ meta_noise_tail(length(events) + 1, meta_count)
  end

  defp meta_noise_tail(_start_id, 0), do: []

  defp meta_noise_tail(start_id, count) do
    for offset <- 0..(count - 1) do
      %{
        id: start_id + offset,
        turn_id: nil,
        ts: 9000 + offset,
        family: :meta,
        type: :gate_decision,
        tier: :durable,
        payload: %{"gate" => "noise-#{offset}"}
      }
    end
  end

  # -- properties ---------------------------------------------------------

  # P-DET-04, the generalized offset-replay property (06-projection §3.1:
  # "for all valid offsets k"). This is the property that actually backs
  # reattach/seek-from-arbitrary-offset: replaying from any DURABLE block
  # boundary yields the tail-consistent block list, i.e.
  #   identity(project(Session.range(from k)))  ==  drop-first-i(identity(project(full)))
  # where block i is the first block whose events all live at offset ≥ k.
  #
  # k ranges over the block-boundary lattice (each block's min source
  # offset, plus one past the end for the empty tail). That IS the set of
  # "valid offsets" for reattach: you reattach at a durable event, never
  # mid-item -- a cut between an item_started and its item_completed would
  # orphan the item (a DIFFERENT, separately-tested recovery, N-ADV-04),
  # not a clean tail. Goldens have strictly sequential items, so every
  # block boundary is such a clean cut.
  property "P-DET-04: replay from any durable block-boundary offset yields the tail-consistent block list" do
    check all(
            name <- member_of(@golden_names),
            raw_k <- integer(0..1_000),
            max_runs: 120
          ) do
      session = load!(name)
      full = Projection.project(session)
      {full_blocks, _fold_defaults} = Projection.identity(full)

      boundaries = block_boundary_offsets(session, full)
      last = List.last(session.envelopes).offset

      # map the generated integer onto a boundary index 0..n (n = the
      # past-the-end empty cut)
      n = length(boundaries)
      i = rem(raw_k, n + 1)

      cut_offset = if i == n, do: last + 1, else: Enum.at(boundaries, i)

      suffix_events =
        session |> Session.range(cut_offset, last) |> Enum.map(& &1.body)

      {suffix_blocks, _} =
        Projection.identity(Projection.project(suffix_events))

      assert suffix_blocks == Enum.drop(full_blocks, i)
    end
  end

  # The min source-event offset of each block in `full`, in block order.
  # event_refs are journal ids; map each to its physical line offset.
  defp block_boundary_offsets(session, full) do
    id_to_offset = Map.new(session.envelopes, &{&1.body.id, &1.offset})

    Enum.map(full.blocks, fn block ->
      block.event_refs
      |> Enum.map(&Map.fetch!(id_to_offset, &1))
      |> Enum.min()
    end)
  end

  # The reattach-resume contract T18 depends on and nothing else tested:
  # two surfaces attaching at DIFFERENT offsets of the same journal
  # converge. Split the golden at a durable block boundary k, project
  # [0..k) and [k..end) independently, concat their transcript block
  # lists, and assert the concat equals the whole-journal transcript.
  # This is split-merge CONVERGENCE (distinct from P-DET-04's
  # restricted-tail equality: that dropped a prefix, this reassembles
  # two independently-projected halves). Uses transcript_identity/1 --
  # the actual reattach key -- so a per-surface fold_defaults difference
  # or a recovery re-annotation can never make it spuriously diverge.
  property "P-ASM (assembly): two surfaces attaching at different offsets converge to one transcript" do
    check all(
            name <- member_of(@golden_names),
            raw_k <- integer(0..1_000),
            max_runs: 120
          ) do
      session = load!(name)
      full = Projection.project(session)

      boundaries = block_boundary_offsets(session, full)
      last = List.last(session.envelopes).offset
      n = length(boundaries)
      i = rem(raw_k, n + 1)
      k = if i == n, do: last + 1, else: Enum.at(boundaries, i)

      before_events =
        session.envelopes
        |> Enum.filter(&(&1.offset < k))
        |> Enum.map(& &1.body)

      from_events = session |> Session.from_offset(k) |> Enum.map(& &1.body)

      merged =
        Projection.transcript_identity(Projection.project(before_events)) ++
          Projection.transcript_identity(Projection.project(from_events))

      assert merged == Projection.transcript_identity(full)
    end
  end

  property "P-DET-03: project/1 is invariant across N replays for any generated valid session" do
    check all(item_kinds <- item_kinds_gen(), max_runs: 50) do
      events = build_session(item_kinds)

      identities =
        for _ <- 1..3, do: Projection.identity(Projection.project(events))

      assert Enum.uniq(identities) |> length() == 1
    end
  end

  property "P-DET-05: ephemeral-shuffle invariance -- stripping/adding item_delta events never changes identity" do
    check all(
            item_kinds <- item_kinds_gen(),
            extra_delta_count <- integer(0..4),
            max_runs: 50
          ) do
      with_deltas = build_session(item_kinds, extra_delta_count)

      without_deltas =
        Enum.reject(with_deltas, &(Map.get(&1, :tier) == :ephemeral))

      identity_with = Projection.identity(Projection.project(with_deltas))
      identity_without = Projection.identity(Projection.project(without_deltas))

      assert identity_with == identity_without
    end
  end

  property "P-DET-06: meta-noise invariance -- interleaving meta events never changes durable_block_list, and 0 blocks derive from meta" do
    check all(
            item_kinds <- item_kinds_gen(),
            meta_count <- integer(0..3),
            max_runs: 50
          ) do
      with_meta = build_session(item_kinds, 0, meta_count)
      without_meta = Enum.reject(with_meta, &(&1.family == :meta))

      proj_with = Projection.project(with_meta)
      proj_without = Projection.project(without_meta)

      assert Projection.identity(proj_with) == Projection.identity(proj_without)

      meta_event_ids =
        with_meta
        |> Enum.filter(&(&1.family == :meta))
        |> Enum.map(& &1.id)
        |> MapSet.new()

      block_event_ids =
        proj_with.blocks |> Enum.flat_map(& &1.event_refs) |> MapSet.new()

      assert MapSet.disjoint?(meta_event_ids, block_event_ids)
    end
  end

  property "N-FWD-01: any out-of-vocabulary item_type renders an opaque block, never crashes, deterministically" do
    check all(
            unknown_type <- string(:alphanumeric, min_length: 1, max_length: 10),
            unknown_type not in [
              "message",
              "reasoning",
              "tool_use",
              "tool_result"
            ],
            max_runs: 50
          ) do
      events = [
        %{
          id: 1,
          turn_id: "t1",
          ts: 100,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 110,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => unknown_type}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 120,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => unknown_type,
            "content" => "opaque payload"
          }
        },
        %{
          id: 4,
          turn_id: "t1",
          ts: 130,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{}
        }
      ]

      proj1 = Projection.project(events)
      proj2 = Projection.project(events)

      assert Projection.identity(proj1) == Projection.identity(proj2)
      assert [block] = proj1.blocks
      assert block.kind == :opaque
      assert block.raw_kind == unknown_type
      assert block.content.text == "opaque payload"
    end
  end

  property "N-SEAL-02: sealed content equals item_completed.content regardless of where a late delta lands" do
    check all(
            gap <- integer(0..3),
            chunk <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 50
          ) do
      base = [
        %{
          id: 1,
          turn_id: "t1",
          ts: 100,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 110,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 120,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => "sealed forever"
          }
        }
      ]

      filler =
        for n <- 1..gap//1 do
          %{
            id: 3 + n,
            turn_id: "t1",
            ts: 120 + n,
            family: :loop,
            type: :item_started,
            tier: :durable,
            payload: %{"item_id" => "filler-#{n}", "item_type" => "reasoning"}
          }
        end

      late_delta_id = 4 + gap
      marker = "LATE-MARKER-" <> chunk

      late_delta = %{
        id: late_delta_id,
        turn_id: "t1",
        ts: 999,
        family: :loop,
        type: :item_delta,
        tier: :ephemeral,
        payload: %{"item_id" => "i1", "chunk" => marker}
      }

      events = base ++ filler ++ [late_delta]
      proj = Projection.project(events)

      block = Enum.find(proj.blocks, &(2 in &1.event_refs))
      assert block.content.text == "sealed forever"
      refute block.content.text =~ marker

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :late_delta_after_seal and
                   &1.event_id == late_delta_id)
             )
    end
  end
end
