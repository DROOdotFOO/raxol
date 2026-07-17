defmodule Raxol.Harness.T7ProjectionTest do
  @moduledoc """
  Acceptance tests for roadmap unit T7 (journal-fold projection):
  P-DET (determinism), P-TIER (two-tier separation), P-FOLD (identity
  leak-guards), N-ADV (the adversarial fixture through the recovery
  policy table), N-DORM (the Dormammu/FI-12-mirrored tip guard),
  N-SEAL (delta-after-seal), N-FWD (forward-compat opaque render).

  Every assertion below anchors on real fixture CONTENT (a specific
  string/value from the `.jsonl` payload), never presence-only asserts
  (`assert length(blocks) == N` alone) -- the anti-stub discipline
  P-E2E later depends on at the T13a layer.

  ## Deviations from the original test-design wording (documented)

  * **No new `.blocks.json` golden snapshots.** T4/TF already pin
    `Raxol.Harness.Fixture.Projectors.Identity` as the bless-task
    default and `test/harness/tf_fixture_test.exs` asserts the checked-in
    snapshots' `"projector"` field against it by name -- swapping the
    bless default to this module would break that suite (an explicit
    "must not break" constraint on this unit). This suite chooses
    **direct content assertions** over new snapshot files instead: every
    property/example below asserts on literal fixture content, which is
    a stronger regression signal than a snapshot diff for a projection
    this young, and avoids a second snapshot format to maintain.
  * **P-TIER-01's literal count identity does not hold for `:tool_call`
    blocks**, by design: a well-formed `tool_use` + `tool_result` pair
    merges into ONE block from TWO `item_completed` events (Block has
    no separate `:tool_result` kind -- see
    `Raxol.Harness.Projection.BlockBuilder`'s moduledoc). The property
    below asserts the *documented* relationship instead: block count
    equals `item_completed` count for non-merging kinds
    (`message`/`reasoning`), and is *at most* the `item_completed` count
    for the merging pair, with the exact merge arithmetic checked
    directly against known fixture shapes.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.Block

  @sessions_dir "test/fixtures/harness/sessions"
  @golden_names ~w(simple-chat multi-tool-turn long-folds unicode-heavy markdown-stream taint-propagation evidence-done)

  defp load!(name),
    do: Fixture.load(Path.join(@sessions_dir, name <> ".jsonl")) |> elem(1)

  # Mirrors the pattern already established in
  # test/raxol/ui/components/harness/block_test.exs -- both Block's own
  # internal rescues and this projection layer's recoveries fire the
  # SAME telemetry event by design (see Recovery's moduledoc).
  defp attach_recovered_handler do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:raxol, :harness, :projection, :recovered],
      fn event, _measurements, metadata, _config ->
        send(parent, {ref, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp raw_events(%Session{envelopes: envelopes}),
    do: Enum.map(envelopes, & &1.body)

  # The frozen-snapshot shape: the projection IDENTITY (durable block
  # list + fold_defaults), the exact thing determinism is defined over
  # (06-projection §2), wrapped with schema + projector tags for the
  # drift assertion. Blocks carry only identity fields (no mutable
  # `fold`), so a UI toggle can never churn the snapshot.
  defp t7_snapshot(session) do
    projection = Projection.project(session)
    {blocks, fold_defaults} = Projection.identity(projection)

    %{
      schema: "harness-t7blocks/1",
      projector: "Raxol.Harness.Projection",
      fold_defaults: fold_defaults,
      blocks: blocks
    }
  end

  # -- P-DET: determinism ----------------------------------------------------

  describe "P-DET: determinism" do
    test "P-DET-01: project/1 is a pure function of its input across all six goldens" do
      for name <- @golden_names do
        session = load!(name)
        first = Projection.project(session)
        second = Projection.project(session)

        assert Projection.identity(first) == Projection.identity(second),
               "#{name}: two projections of the same session diverged"
      end
    end

    test "P-DET-01b: project/1 called N times on the same events yields byte-identical identity" do
      session = load!("multi-tool-turn")
      events = raw_events(session)

      identities =
        for _ <- 1..5, do: Projection.identity(Projection.project(events))

      assert Enum.uniq(identities) |> length() == 1
    end

    test "P-DET-04: replay from any turn boundary matches the tail of a full replay (long-folds, 6 turns)" do
      session = load!("long-folds")
      full = Projection.project(session)

      # turn 4 starts at id 19 (offset 20, per the fixture dump); the
      # first three turns produced exactly 3 tool_call blocks (one
      # well-formed tool_use+tool_result pair per turn).
      turn4_start_offset = 20
      last_offset = List.last(session.envelopes).offset

      suffix_events =
        session
        |> Session.range(turn4_start_offset, last_offset)
        |> Enum.map(& &1.body)

      suffix_projection = Projection.project(suffix_events)

      assert length(full.blocks) == 6
      assert length(suffix_projection.blocks) == 3

      full_identity = Projection.identity(full) |> elem(0)
      suffix_identity = Projection.identity(suffix_projection) |> elem(0)

      assert suffix_identity == Enum.drop(full_identity, 3)
    end

    test "P-DET-04b: replaying from offset 0 reproduces the whole session identically" do
      session = load!("simple-chat")
      full_events = raw_events(session)

      assert Projection.identity(Projection.project(full_events)) ==
               Projection.identity(Projection.project(session))
    end
  end

  # -- P-DET-02: T7-owned frozen snapshot tripwire ---------------------------
  #
  # A drift net for the identity block-list per golden, in a SEPARATE
  # namespace (`<name>.t7blocks.json`) from TF's `<name>.blocks.json`
  # (which is pinned to `Projectors.Identity` by `tf_fixture_test.exs`
  # and must not move). This is the P-DET-02 equivalent T13a leans on:
  # if a golden's PROJECTED output legitimately changes, re-bless with
  # `BLESS_T7=1 mix test test/harness/t7_projection_test.exs` and the
  # snapshot diff is the deliberate review gate. Frozen bytes + the
  # regenerable projection are the regression anchor (06-projection §1.2).

  describe "P-DET-02: checked-in .t7blocks.json snapshots match a fresh projection" do
    for name <- @golden_names do
      test "#{name}.t7blocks.json is current (T7 drift tripwire)" do
        name = unquote(name)
        session = load!(name)
        fresh = t7_snapshot(session)
        snapshot_path = Path.join(@sessions_dir, name <> ".t7blocks.json")

        if System.get_env("BLESS_T7") do
          File.write!(snapshot_path, Jason.encode!(fresh, pretty: true) <> "\n")
        end

        checked_in = Jason.decode!(File.read!(snapshot_path))
        assert checked_in["schema"] == "harness-t7blocks/1"
        assert checked_in["projector"] == "Raxol.Harness.Projection"

        # Round-trip the fresh projection through JSON so its atoms meet
        # the snapshot's strings on equal terms. A failure here means the
        # projection changed without re-blessing (or a snapshot was
        # hand-edited): re-bless with BLESS_T7=1 and review the diff.
        assert Jason.decode!(Jason.encode!(fresh)) == checked_in
      end
    end
  end

  # -- P-TIER: two-tier separation --------------------------------------------

  describe "P-TIER: two-tier separation" do
    test "P-TIER-01: message/reasoning block counts equal their item_completed counts; tool_call merges 2:1" do
      session = load!("multi-tool-turn")
      proj = Projection.project(session)

      completed =
        Session.by_type(session, :item_completed) |> Enum.map(& &1.body)

      message_completions =
        Enum.count(completed, &(&1.payload["item_type"] == "message"))

      reasoning_completions =
        Enum.count(completed, &(&1.payload["item_type"] == "reasoning"))

      tool_completions =
        Enum.count(
          completed,
          &(&1.payload["item_type"] in ["tool_use", "tool_result"])
        )

      kinds = Enum.map(proj.blocks, & &1.kind)
      assert Enum.count(kinds, &(&1 == :message)) == message_completions
      assert Enum.count(kinds, &(&1 == :reasoning)) == reasoning_completions
      # documented merge arithmetic: 2 tool_use+tool_result item_completed
      # events fold into 1 :tool_call block per well-formed pair
      assert Enum.count(kinds, &(&1 == :tool_call)) == div(tool_completions, 2)
    end

    test "P-TIER-02: sealed content is sourced from item_completed.content, not the concatenated deltas" do
      session = load!("simple-chat")
      proj = Projection.project(session)

      [block] = proj.blocks
      assert block.kind == :message
      # the deltas concatenate to "Hello!" too here, but the block's
      # content must come from item_completed.content specifically
      # (asserted independently via P-TIER-03's delta-stripped replay)
      assert block.content.text == "Hello!"
    end

    test "P-TIER-03: stripping all item_delta events leaves durable_block_list unchanged" do
      session = load!("multi-tool-turn")
      with_deltas = raw_events(session)

      without_deltas =
        Enum.reject(with_deltas, &(Map.get(&1, :tier) == :ephemeral))

      identity_with =
        Projection.identity(Projection.project(with_deltas)) |> elem(0)

      identity_without =
        Projection.identity(Projection.project(without_deltas)) |> elem(0)

      assert identity_with == identity_without
    end

    test "P-TIER-04: sealed content never contains a bare mid-stream delta fragment" do
      session = load!("markdown-stream")
      proj = Projection.project(session)

      [block] = proj.blocks

      deltas =
        Session.ephemeral(session) |> Enum.map(& &1.body.payload["chunk"])

      full_text = Enum.join(deltas, "")

      assert block.content.text == full_text
      # a lone early delta chunk, on its own, is not the sealed content
      refute block.content.text == hd(deltas)
    end

    test "P-TIER-05: source_events retains no :ephemeral event, and refolding is identical to the original" do
      session = load!("multi-tool-turn")
      proj = Projection.project(session)

      refute Enum.any?(proj.source_events, &(Map.get(&1, :tier) == :ephemeral))

      refolded = Projection.refold(proj)
      assert Projection.identity(refolded) == Projection.identity(proj)
    end
  end

  # -- P-FOLD: fold defaults + identity leak-guards --------------------------

  describe "P-FOLD: fold defaults and identity leak-guards" do
    test "fold_defaults resolves from Block.default_fold/1 for every known kind plus :opaque" do
      proj = Projection.project(load!("simple-chat"))

      for kind <- Block.known_kinds() ++ [:opaque] do
        assert proj.fold_defaults[kind] == Block.default_fold(kind)
      end
    end

    test "blocks are constructed with their kind's fold default" do
      proj = Projection.project(load!("multi-tool-turn"))
      by_kind = Enum.group_by(proj.blocks, & &1.kind)

      # Machinery kinds (reasoning, tool_call) default FOLDED -- their
      # default form is the compact one-line register (glyph + referent +
      # receipt); speech (message) stays expanded.
      assert Enum.all?(by_kind[:reasoning], &(&1.fold == :folded))
      assert Enum.all?(by_kind[:tool_call], &(&1.fold == :folded))
      assert Enum.all?(by_kind[:message], &(&1.fold == :expanded))
    end

    test "P-FOLD-03: a UI-local fold toggle does not change identity" do
      session = load!("multi-tool-turn")
      proj = Projection.project(session)
      before = Projection.identity(proj)

      toggled_blocks =
        List.update_at(
          proj.blocks,
          0,
          &Block.toggle_fold(&1, fold_after_seal: :allow)
        )

      toggled_proj = %{proj | blocks: toggled_blocks}

      # the toggle really did flip fold state...
      refute hd(toggled_proj.blocks).fold == hd(proj.blocks).fold
      # ...but identity (which drops the mutable `fold` field) is unmoved
      assert Projection.identity(toggled_proj) == before
    end

    test "P-FOLD-04: changing a fold_default changes identity" do
      session = load!("multi-tool-turn")
      default_identity = Projection.identity(Projection.project(session))

      overridden_identity =
        Projection.identity(
          Projection.project(session, fold_defaults: %{reasoning: :expanded})
        )

      refute default_identity == overridden_identity

      {_blocks, fold_defaults} = overridden_identity
      assert fold_defaults.reasoning == :expanded
    end

    test "P-FOLD-05: refold/2 restores fold_defaults and discards any external block mutation" do
      session = load!("multi-tool-turn")
      proj = Projection.project(session)

      mutated_blocks =
        List.update_at(
          proj.blocks,
          0,
          &Block.toggle_fold(&1, fold_after_seal: :allow)
        )

      mutated = %{proj | blocks: mutated_blocks}
      refolded = Projection.refold(mutated)

      assert Projection.identity(refolded) ==
               Projection.identity(Projection.project(session))
    end
  end

  # -- the two identity keys' distinct contracts (T18 vs T13a) ---------------

  describe "transcript_identity/1 vs identity/1" do
    test "transcript_identity ignores a fold_default change; identity does NOT" do
      session = load!("multi-tool-turn")
      default = Projection.project(session)

      overridden =
        Projection.project(session, fold_defaults: %{reasoning: :expanded})

      # the reattach key is blind to a per-surface display preference...
      assert Projection.transcript_identity(default) ==
               Projection.transcript_identity(overridden)

      # ...while the freeze key deliberately catches it
      refute Projection.identity(default) == Projection.identity(overridden)
    end

    test "transcript_identity strips recovery metadata; the projection blocks still carry it" do
      session = load!("adversarial")
      proj = Projection.project(session)

      # the projection blocks DO carry the recovery flags (N-ADV asserts this)
      assert Enum.any?(proj.blocks, &(&1.content[:recovered] == true))

      # but the reattach key strips them, so a recovery re-annotation
      # can never make "same transcript?" answer false
      transcript_contents =
        Projection.transcript_identity(proj) |> Enum.map(& &1.content)

      refute Enum.any?(transcript_contents, &Map.has_key?(&1, :recovered))

      refute Enum.any?(
               transcript_contents,
               &Map.has_key?(&1, :recovered_reasons)
             )
    end

    test "a UI-local fold toggle perturbs neither key (leak-guard #1, both keys)" do
      session = load!("multi-tool-turn")
      proj = Projection.project(session)

      toggled = %{
        proj
        | blocks:
            List.update_at(
              proj.blocks,
              0,
              &Block.toggle_fold(&1, fold_after_seal: :allow)
            )
      }

      assert Projection.transcript_identity(toggled) ==
               Projection.transcript_identity(proj)

      assert Projection.identity(toggled) == Projection.identity(proj)
    end
  end

  # -- N-ADV: adversarial fixture through the recovery policy table ----------

  describe "N-ADV: the recovery policy table, exercised against the adversarial fixture" do
    setup do
      session = load!("adversarial")
      ref = attach_recovered_handler()
      %{session: session, proj: Projection.project(session), ref: ref}
    end

    test "N-ADV-01: never raises; a diagnostic is emitted for every recovered condition",
         %{
           proj: proj,
           ref: ref
         } do
      reasons =
        Enum.map(proj.diagnostics, & &1.reason) |> Enum.uniq() |> Enum.sort()

      assert reasons == [
               :duplicate_id,
               :forward_id_gap,
               :late_delta_after_seal,
               :missing_turn_started,
               :orphan_item_completed,
               :out_of_order_id,
               :unknown_item_type
             ]

      for %{reason: reason, event_id: event_id} <- proj.diagnostics do
        assert_received {^ref, [:raxol, :harness, :projection, :recovered],
                         %{reason: ^reason, event_id: ^event_id}}
      end
    end

    test "N-ADV-02: the out-of-order id is dropped, never applied", %{
      proj: proj
    } do
      all_refs = Enum.flat_map(proj.blocks, & &1.event_refs)
      refute 7 in all_refs

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :out_of_order_id and &1.event_id == 7)
             )
    end

    test "N-ADV-forward-gap: id 8 arriving before its predecessor id 7 (out-of-order, dropped for good) leaves a real interior gap -- diagnosed and hard-marked damaged",
         %{proj: proj} do
      # id 7 arrives (line-order) AFTER id 8 and is dropped as out-of-order
      # (N-ADV-02) -- it never re-enters the accepted stream, so the
      # accepted ids genuinely skip from 6 straight to 8. That is a real
      # forward gap from filter_ids/1's point of view, not a false
      # positive: the durable set really is missing an id.
      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :forward_id_gap and &1.event_id == 8)
             )

      assert proj.damaged == true
    end

    test "N-ADV-03: the duplicate id is idempotent -- applied exactly once", %{
      proj: proj
    } do
      # id 8 (item i3, tool_use) appears in the source stream twice;
      # it must contribute to exactly one block.
      blocks_with_id_8 = Enum.filter(proj.blocks, &(8 in &1.event_refs))
      assert length(blocks_with_id_8) == 1
    end

    test "N-ADV-04: the orphan item_completed renders as exactly one recovered block with correct content",
         %{proj: proj} do
      recovered_orphans =
        Enum.filter(proj.blocks, fn block ->
          block.content[:recovered] == true and
            :orphan_item_completed in block.content[:recovered_reasons]
        end)

      # i-orphan (id 4), the unknown-type i2 (id 6, ALSO orphan), and
      # i3 (id 8, tool_use with no item_started) are all orphans here
      assert length(recovered_orphans) == 3

      orphan_result_block = Enum.find(recovered_orphans, &(4 in &1.event_refs))
      assert orphan_result_block.kind == :tool_call

      assert orphan_result_block.content.result =~
               "orphan result: no preceding item_started"
    end

    test "N-ADV-05: interleaved turns group by turn_id in first-seen order, no cross-turn bleed" do
      events = [
        loop(1, "tA", 100, :turn_started, %{}),
        loop(2, "tA", 110, :item_started, %{
          "item_id" => "a1",
          "item_type" => "message"
        }),
        loop(3, "tB", 120, :turn_started, %{}),
        loop(4, "tB", 130, :item_started, %{
          "item_id" => "b1",
          "item_type" => "message"
        }),
        loop(5, "tA", 140, :item_completed, %{
          "item_id" => "a1",
          "item_type" => "message",
          "content" => "from A"
        }),
        loop(6, "tB", 150, :item_completed, %{
          "item_id" => "b1",
          "item_type" => "message",
          "content" => "from B"
        }),
        loop(7, "tA", 160, :turn_completed, %{}),
        loop(8, "tB", 170, :turn_completed, %{})
      ]

      proj = Projection.project(events)
      contents = Enum.map(proj.blocks, & &1.content.text)

      # tA was first-seen, so its block comes first even though its
      # item_completed (id 5) arrives interleaved with tB's events
      assert contents == ["from A", "from B"]
    end
  end

  # -- N-FWD-GAP: forward id gaps are diagnosed and hard-marked --------------

  describe "N-FWD-GAP: a forward id gap is never silently accepted" do
    test "ids 1, 2, 5 (3 and 4 lost): forward_id_gap diagnosed at id 5, telemetry fires, projection.damaged is true" do
      ref = attach_recovered_handler()

      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        loop(2, "t1", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        }),
        loop(5, "t1", 140, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => "after the gap"
        })
      ]

      proj = Projection.project(events)

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :forward_id_gap and &1.event_id == 5)
             )

      assert_received {^ref, [:raxol, :harness, :projection, :recovered],
                       %{reason: :forward_id_gap, event_id: 5}}

      assert proj.damaged == true

      # soft-render: the gap does not withhold the survivor blocks
      [block] = proj.blocks
      assert block.content.text == "after the gap"
    end

    test "false-positive guard: contiguous ids emit no forward_id_gap diagnostic and damaged stays false" do
      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        loop(2, "t1", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        }),
        loop(3, "t1", 120, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => "no gap here"
        }),
        loop(4, "t1", 130, :turn_completed, %{})
      ]

      proj = Projection.project(events)

      refute Enum.any?(proj.diagnostics, &(&1.reason == :forward_id_gap))
      assert proj.damaged == false
    end

    test "a suffix replay starting mid-stream (a valid reattach offset) is not itself a forward gap" do
      session = load!("multi-tool-turn")
      full_events = raw_events(session)
      # drop the first event -- the suffix's own first id is now > 1,
      # which must NOT be mistaken for a forward gap: filter_ids/1 has
      # no "highest accepted so far" yet for the very first id in a call.
      [_dropped | suffix] = full_events

      proj = Projection.project(suffix)

      refute Enum.any?(proj.diagnostics, &(&1.reason == :forward_id_gap))
      assert proj.damaged == false
    end
  end

  # -- N-DORM: the Dormammu/FI-12-mirrored tip guard --------------------------

  describe "N-DORM: non-conversational records never become a block or the tip" do
    test "N-DORM-01/03: a trailing meta record is never the tip; the tip is the last conversational block" do
      session = load!("adversarial")
      proj = Projection.project(session)

      tip = Projection.tip(proj)
      assert tip.kind == :message
      assert tip.content.text =~ "turn t2 has no turn_started"

      last_envelope = List.last(session.envelopes)
      assert last_envelope.body.family == :meta
    end

    test "N-DORM-02: no family: :meta event ever appears in durable_block_list" do
      for name <- @golden_names ++ ["adversarial"] do
        session = load!(name)
        proj = Projection.project(session)

        meta_ids =
          session
          |> Session.by_family(:meta)
          |> Enum.map(& &1.body.id)
          |> MapSet.new()

        block_ids =
          proj.blocks |> Enum.flat_map(& &1.event_refs) |> MapSet.new()

        assert MapSet.disjoint?(meta_ids, block_ids),
               "#{name}: a meta event id leaked into a block"
      end
    end

    test "N-DORM-04: an untyped/unknown-family record is never a block, never the tip, and is diagnosed" do
      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        loop(2, "t1", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        }),
        loop(3, "t1", 120, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => "real content"
        }),
        loop(4, "t1", 130, :turn_completed, %{}),
        %{
          id: 5,
          turn_id: nil,
          ts: 140,
          family: nil,
          type: nil,
          tier: :durable,
          payload: %{}
        }
      ]

      proj = Projection.project(events)

      assert length(proj.blocks) == 1
      assert Projection.tip(proj).content.text == "real content"

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :untyped_record and &1.event_id == 5)
             )
    end

    test "N-DORM-05: a family: :loop record with a non-atom (string) :type is diagnosed, never silently dropped" do
      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        %{
          id: 2,
          turn_id: "t1",
          ts: 110,
          family: :loop,
          # a string top-level :type, e.g. a malformed/legacy producer --
          # must not silently vanish into BlockBuilder's fold_event/3
          # catch-all clause with no diagnostic
          type: "item_started",
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        loop(3, "t1", 120, :turn_completed, %{})
      ]

      proj = Projection.project(events)

      assert proj.blocks == []

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :untyped_record and &1.event_id == 2)
             )
    end
  end

  # -- N-SEAL: delta after seal ------------------------------------------------

  describe "N-SEAL: item_delta arriving after item_completed" do
    test "N-SEAL-01: the late delta is dropped; sealed content is unaffected; diagnostic emitted" do
      session = load!("adversarial")
      proj = Projection.project(session)

      pathology_offset =
        Session.pathologies(session)
        |> Enum.find(&(&1.class == "late_delta_after_seal"))
        |> Map.fetch!(:offset)

      late_delta =
        Session.range(session, pathology_offset, pathology_offset) |> hd()

      assert late_delta.body.type == :item_delta
      assert late_delta.body.payload["item_id"] == "i1"

      i1_block = Enum.find(proj.blocks, &(3 in &1.event_refs))
      assert i1_block.content.name == "list_dir"
      refute inspect(i1_block.content) =~ "late chunk"

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :late_delta_after_seal and
                   &1.event_id == late_delta.body.id)
             )
    end

    test "N-SEAL-02: sealed content equals item_completed.content for any position of a late delta" do
      for late_position <- [:immediately_after, :several_events_later] do
        events = late_delta_scenario(late_position)
        proj = Projection.project(events)

        block = Enum.find(proj.blocks, &(2 in &1.event_refs))
        assert block.content.text == "final content"
      end
    end

    test "N-SEAL-03: a late delta does not resurrect the tail for its (completed) item" do
      events = late_delta_scenario(:immediately_after)
      proj = Projection.project(events)

      assert proj.tail == %{}
    end
  end

  # -- live tail: per-turn composite keys + bounded delta buffer --------------

  describe "the live tail is keyed per-turn and bounded per item" do
    test "two turns each with an unsealed \"i1\" both survive in proj.tail under distinct composite keys" do
      events = [
        loop(1, "tA", 100, :turn_started, %{}),
        loop(2, "tA", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        }),
        loop(3, "tB", 120, :turn_started, %{}),
        loop(4, "tB", 130, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        })
      ]

      proj = Projection.project(events)

      # without the {turn_id, item_id} composite key, turn B's "i1"
      # would silently clobber turn A's "i1" in Projection's cross-turn
      # Map.merge/2 -- both must survive independently here.
      assert map_size(proj.tail) == 2
      assert Map.has_key?(proj.tail, {"tA", "i1"})
      assert Map.has_key?(proj.tail, {"tB", "i1"})
      assert proj.tail[{"tA", "i1"}].turn_id == "tA"
      assert proj.tail[{"tB", "i1"}].turn_id == "tB"
    end

    test "an unbounded item_delta stream on a never-completed item is capped, not unbounded" do
      header = [
        loop(1, "t1", 100, :turn_started, %{}),
        loop(2, "t1", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "message"
        })
      ]

      delta_count = 500

      deltas =
        for n <- 1..delta_count do
          loop(
            2 + n,
            "t1",
            110 + n,
            :item_delta,
            %{"item_id" => "i1", "chunk" => "chunk-#{n}"},
            tier: :ephemeral
          )
        end

      proj = Projection.project(header ++ deltas)

      tail_entry = Map.fetch!(proj.tail, {"t1", "i1"})
      assert length(tail_entry.chunks) < delta_count

      # sliding window keeps the MOST RECENT chunks (build_tail/2
      # restores arrival order, so the newest chunk is last)
      assert List.last(tail_entry.chunks) == "chunk-#{delta_count}"

      assert Enum.any?(proj.diagnostics, &(&1.reason == :delta_buffer_capped))
    end
  end

  # -- N-FWD: forward-compat opaque render -------------------------------------

  describe "N-FWD: unknown vocabulary renders opaque, never crashes" do
    test "N-FWD-01: an item_completed with an out-of-vocabulary item_type renders an opaque block" do
      session = load!("adversarial")
      proj = Projection.project(session)

      opaque = Enum.find(proj.blocks, &(&1.kind == :opaque))
      # raw_kind preserves the ORIGINAL item_type (not a flattened
      # :opaque) so the opaque render can still show a real label
      assert opaque.raw_kind == "custom_widget"
      assert opaque.content.text =~ "item_type outside today's vocabulary"
      assert opaque.content[:recovered] == true
      # this item is ALSO orphan (no item_started for id "i2") -- both
      # independent anomalies are recorded, not just one
      assert :unknown_item_type in opaque.content.recovered_reasons
      assert :orphan_item_completed in opaque.content.recovered_reasons
    end

    test "N-FWD-03: a future/unbounded block kind never crashes and never evaluates -- always opaque" do
      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        loop(2, "t1", 110, :item_started, %{
          "item_id" => "i1",
          "item_type" => "vision_analysis"
        }),
        loop(3, "t1", 120, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "vision_analysis",
          "content" => "a hypothetical future item kind"
        }),
        loop(4, "t1", 130, :turn_completed, %{})
      ]

      proj = Projection.project(events)
      [block] = proj.blocks
      assert block.kind == :opaque
      assert block.raw_kind == "vision_analysis"
      assert block.content.text == "a hypothetical future item kind"
      # well-formed (has its own item_started) -- unknown-kind only,
      # never flagged orphan
      assert block.content.recovered_reasons == [:unknown_item_type]
    end
  end

  # -- fixtures for hand-authored event streams --------------------------------

  defp loop(id, turn_id, ts, type, payload, opts \\ []) do
    %{
      id: id,
      turn_id: turn_id,
      ts: ts,
      family: :loop,
      type: type,
      tier: Keyword.get(opts, :tier, :durable),
      payload: payload
    }
  end

  defp late_delta_scenario(:immediately_after) do
    [
      loop(1, "t1", 100, :turn_started, %{}),
      loop(2, "t1", 110, :item_started, %{
        "item_id" => "i1",
        "item_type" => "message"
      }),
      loop(3, "t1", 120, :item_completed, %{
        "item_id" => "i1",
        "item_type" => "message",
        "content" => "final content"
      }),
      loop(4, "t1", 130, :item_delta, %{"item_id" => "i1", "chunk" => "late"},
        tier: :ephemeral
      ),
      loop(5, "t1", 140, :turn_completed, %{})
    ]
  end

  defp late_delta_scenario(:several_events_later) do
    [
      loop(1, "t1", 100, :turn_started, %{}),
      loop(2, "t1", 110, :item_started, %{
        "item_id" => "i1",
        "item_type" => "message"
      }),
      loop(3, "t1", 120, :item_completed, %{
        "item_id" => "i1",
        "item_type" => "message",
        "content" => "final content"
      }),
      loop(4, "t1", 130, :item_started, %{
        "item_id" => "i2",
        "item_type" => "reasoning"
      }),
      loop(5, "t1", 140, :item_completed, %{
        "item_id" => "i2",
        "item_type" => "reasoning",
        "content" => "other item"
      }),
      loop(6, "t1", 150, :item_delta, %{"item_id" => "i1", "chunk" => "late"},
        tier: :ephemeral
      ),
      loop(7, "t1", 160, :turn_completed, %{})
    ]
  end
end
