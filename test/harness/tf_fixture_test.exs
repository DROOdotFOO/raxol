defmodule Raxol.Harness.TFFixtureTest do
  @moduledoc """
  Acceptance tests for roadmap unit TF (fixture toolchain):

    * all golden sessions (the design's five shapes plus the FI-5
      taint-propagation substrate) load through `Fixture.decode/1`
    * the adversarial fixture's seven corruption classes are present,
      decodable, and indexed as data via `Session.pathologies/1`
      (they're semantically pathological, not decode-malformed — see
      `test/fixtures/harness/sessions/adversarial.notes.md`)
    * `Fixture.decode/1`'s typed-error taxonomy, exercised against
      inline malformed lines (loud reject, never partial)
    * `Upcast.to_current/2` fills absent newer fields with defaults —
      fail-safe trust: absent provenance on tool_result payloads loads
      as `:tainted` (FI-5); upcast is idempotent; decode is lossless
      against the disk bytes
    * checked-in `<name>.blocks.json` snapshots match a fresh projection
      (the drift tripwire, running in the normal suite)
    * `mix raxol.harness.fixtures.bless` round-trips with the identity
      projector, and `--check` mode detects drift without writing
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.{Bless, DecodeError, Envelope, Header, Session, Upcast}
  alias Raxol.Harness.Fixture.Projectors.Identity

  # Standalone test-only projector (defined at file scope, not inside a
  # test body, so it compiles exactly once as
  # `Raxol.Harness.TFFixtureTest.CountingProjector`) proving the bless
  # task's `--projector` seam is genuinely swappable, not hardcoded to
  # `Projectors.Identity`.
  defmodule CountingProjector do
    @behaviour Raxol.Harness.Fixture.Projector
    @impl true
    def project(session), do: %{"envelope_count" => length(session.envelopes)}
  end

  @sessions_dir "test/fixtures/harness/sessions"
  @golden_names ~w(simple-chat multi-tool-turn long-folds unicode-heavy markdown-stream taint-propagation evidence-done)
  @all_names @golden_names ++ ["adversarial"]

  # -- golden sessions load ------------------------------------------------

  describe "golden sessions load through decode/1" do
    for name <- @golden_names do
      test "#{name} loads as a well-formed, kind: golden session" do
        path = Path.join(@sessions_dir, unquote(name) <> ".jsonl")
        assert {:ok, %Session{} = session} = Fixture.load(path)

        assert %Header{kind: :golden, schema: "harness-fixture/1"} =
                 session.header

        assert session.header.envelope_v == 1
        assert Session.golden?(session)
        refute Session.adversarial?(session)
        assert session.envelopes != []

        # every envelope offset is its 1-based line number, and offsets
        # are strictly increasing (line 1 is the header).
        offsets = Enum.map(session.envelopes, & &1.offset)
        assert offsets == Enum.sort(offsets)
        assert hd(offsets) == 2
      end
    end

    test "simple-chat has the expected shape: 4 durable, 2 ephemeral" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "simple-chat.jsonl"))

      assert length(Session.durable(session)) == 4
      assert length(Session.ephemeral(session)) == 2
      assert length(Session.by_type(session, :item_delta)) == 2
      assert length(Session.by_family(session, :loop)) == 6
      assert Session.by_family(session, :meta) == []

      [turn_completed] = Session.by_type(session, :turn_completed)
      assert turn_completed.body.payload["final"] == true
    end

    test "long-folds has 36 envelopes across 6 turns and supports offset replay" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "long-folds.jsonl"))

      assert length(session.envelopes) == 36

      turn_ids = session.envelopes |> Enum.map(& &1.body.turn_id) |> Enum.uniq()
      assert length(turn_ids) == 6

      # replay-from-offset: the tail from the last envelope's offset is
      # exactly that one envelope.
      last = List.last(session.envelopes)
      assert Session.from_offset(session, last.offset) == [last]

      # range window (inclusive both ends, physical-line axis): lines
      # 2..7 are exactly the first turn's 6 envelopes
      window = Session.range(session, 2, 7)
      assert length(window) == 6
      assert Enum.map(window, & &1.offset) == Enum.to_list(2..7)
      assert Enum.all?(window, &(&1.body.turn_id == "t1"))

      # by_id (journal-offset axis): unique per id in a well-formed stream
      assert [%Envelope{body: %{id: 1, type: :turn_started}}] =
               Session.by_id(session, 1)
    end

    test "unicode-heavy content survives the JSON round trip byte-for-byte" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "unicode-heavy.jsonl"))

      [completed] = Session.by_type(session, :item_completed) |> Enum.take(1)
      content = completed.body.payload["content"]

      assert content =~ "你好世界"
      assert content =~ "مرحبا"
      assert content =~ "שלום"
      assert content =~ "\u{1F389}"
    end

    test "markdown-stream deltas concatenate to a doc containing a fence and a table" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "markdown-stream.jsonl"))

      deltas = Session.ephemeral(session)
      assert length(deltas) > 5

      streamed = deltas |> Enum.map(& &1.body.payload["chunk"]) |> Enum.join("")
      assert streamed =~ "```elixir"
      assert streamed =~ "| check | status | ms |"

      [completed] = Session.by_type(session, :item_completed)
      assert completed.body.payload["content"] == streamed
    end

    test "taint-propagation: tainted tool_result and the message quoting it are BOTH stamped tainted" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "taint-propagation.jsonl"))

      completed =
        session
        |> Session.by_type(:item_completed)
        |> Enum.map(& &1.body)

      tool_result =
        Enum.find(completed, &(&1.payload["item_type"] == "tool_result"))

      assert tool_result.provenance == %{
               source: "tool:web_fetch",
               trust: :tainted
             }

      message = Enum.find(completed, &(&1.payload["item_type"] == "message"))
      assert message.provenance == %{source: "primary", trust: :tainted}

      # the taint is not decorative: the message literally quotes the
      # tainted tool output — the TaintBadge substrate
      assert message.payload["content"] =~ tool_result.payload["content"]

      # the ephemeral delta of the quoting message is stamped too
      [delta] = Session.by_type(session, :item_delta)
      assert delta.body.provenance.trust == :tainted

      # and the taint stamps are explicit on disk, not upcast fills:
      # decode (pre-upcast) already carries them
      raw_lines = read_envelope_lines("taint-propagation")

      explicit =
        for line <- raw_lines,
            {:ok, %Envelope{body: body}} = Fixture.decode(line),
            body.provenance != nil,
            do: body.provenance.trust

      assert :tainted in explicit
    end
  end

  # -- adversarial fixture --------------------------------------------------

  describe "adversarial fixture" do
    test "loads cleanly (every line is a structurally valid envelope)" do
      path = Path.join(@sessions_dir, "adversarial.jsonl")
      assert {:ok, %Session{} = session} = Fixture.load(path)
      assert Session.adversarial?(session)
      refute Session.golden?(session)
    end

    test "each documented corruption class from adversarial.notes.md is present" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "adversarial.jsonl"))

      bodies = Enum.map(session.envelopes, & &1.body)
      ids = Enum.map(bodies, & &1.id)

      # duplicate event: id=8 appears twice
      assert Enum.count(ids, &(&1 == 8)) == 2

      # out-of-order id: a lower id (7) appears after a higher one (8)
      assert Enum.find_index(ids, &(&1 == 8)) < Enum.find_index(ids, &(&1 == 7))

      # orphan item_completed: item_id "i-orphan" has no item_started sibling
      assert Enum.any?(bodies, fn b -> b.payload["item_id"] == "i-orphan" end)

      refute Enum.any?(bodies, fn b ->
               b.type == :item_started and b.payload["item_id"] == "i-orphan"
             end)

      # late item_delta after seal: an item_delta for "i1" after i1's item_completed
      i1_completed_id =
        Enum.find_value(bodies, fn b ->
          if b.type == :item_completed and b.payload["item_id"] == "i1",
            do: b.id
        end)

      late_delta =
        Enum.find(
          bodies,
          &(&1.type == :item_delta and &1.payload["item_id"] == "i1")
        )

      assert late_delta.id > i1_completed_id

      # unknown item_type: decodes fine, value preserved verbatim
      unknown = Enum.find(bodies, &(&1.payload["item_type"] == "custom_widget"))
      assert unknown.type == :item_completed

      # missing turn_started: turn t2 has items but never opened
      t2_bodies = Enum.filter(bodies, &(&1.turn_id == "t2"))
      assert t2_bodies != []
      refute Enum.any?(t2_bodies, &(&1.type == :turn_started))

      # trailing meta record: the FINAL envelope is family :meta —
      # N-DORM-03's seek target (a rebuild landing here must not fold
      # it into a block or select it as tip)
      last = List.last(session.envelopes)
      assert last.body.family == :meta
      assert last.body.type == :gate_decision
      assert last.body.provenance == %{source: "probe_c1_gate", trust: :trusted}
    end

    test "pathologies are exposed as data and each offset seeks to its corruption" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "adversarial.jsonl"))

      pathologies = Session.pathologies(session)
      by_class = Map.new(pathologies, &{&1.class, &1.offset})

      assert map_size(by_class) == 7

      # seek each named corruption through the data, not hardcoded lines
      [orphan] = Session.range(session, by_class["orphan_item_completed"], by_class["orphan_item_completed"])
      assert orphan.body.payload["item_id"] == "i-orphan"

      [late_delta] = Session.range(session, by_class["late_delta_after_seal"], by_class["late_delta_after_seal"])
      assert late_delta.body.type == :item_delta
      assert late_delta.body.payload["item_id"] == "i1"

      [unknown] = Session.range(session, by_class["unknown_item_type"], by_class["unknown_item_type"])
      assert unknown.body.payload["item_type"] == "custom_widget"

      [out_of_order] = Session.range(session, by_class["out_of_order_id"], by_class["out_of_order_id"])
      assert out_of_order.body.id == 7

      [missing_ts] = Session.range(session, by_class["missing_turn_started"], by_class["missing_turn_started"])
      assert missing_ts.body.turn_id == "t2"

      [trailing] = Session.range(session, by_class["trailing_meta"], by_class["trailing_meta"])
      assert trailing.body.family == :meta

      # goldens carry no pathologies
      assert {:ok, golden} =
               Fixture.load(Path.join(@sessions_dir, "simple-chat.jsonl"))

      assert Session.pathologies(golden) == []
    end

    test "the two axes diverge detectably: by_id surfaces the duplicate, offsets stay unique" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "adversarial.jsonl"))

      dup_offset =
        Session.pathologies(session)
        |> Enum.find(&(&1.class == "duplicate_id"))
        |> Map.fetch!(:offset)

      # seek/identity axis: id 8 appears twice — by_id surfaces both
      assert [first, second] = Session.by_id(session, 8)
      assert first.body == second.body

      # diagnostic axis: their physical offsets differ, one being the
      # pathology-indexed line — this divergence IS the corruption signal
      assert first.offset != second.offset
      assert second.offset == dup_offset

      # a well-formed golden has the axes in lockstep: every id unique
      assert {:ok, golden} =
               Fixture.load(Path.join(@sessions_dir, "simple-chat.jsonl"))

      for envelope <- golden.envelopes do
        assert [_only] = Session.by_id(golden, envelope.body.id)
      end
    end
  end

  # -- snapshot drift tripwire ------------------------------------------------

  describe "checked-in .blocks.json snapshots match a fresh projection" do
    for name <- @golden_names do
      test "#{name}.blocks.json is current (drift tripwire)" do
        fixture_path = Path.join(@sessions_dir, unquote(name) <> ".jsonl")
        blocks_path = Path.join(@sessions_dir, unquote(name) <> ".blocks.json")

        assert {:ok, session} = Fixture.load(fixture_path)
        fresh = Identity.project(session)

        checked_in = Jason.decode!(File.read!(blocks_path))
        assert checked_in["schema"] == "harness-fixture-blocks/1"

        assert checked_in["projector"] ==
                 "Raxol.Harness.Fixture.Projectors.Identity"

        # Compare through a JSON round trip so the fresh projection's
        # atoms meet the snapshot's strings on equal terms. If this
        # fails, the projection changed without re-blessing (or a
        # snapshot was hand-edited): run
        # `mix raxol.harness.fixtures.bless` and review the diff.
        assert Jason.decode!(Jason.encode!(fresh)) == checked_in["blocks"]
      end
    end
  end

  # -- decode/1 error taxonomy ----------------------------------------------

  describe "decode/1 typed error taxonomy (loud reject, never partial)" do
    test "invalid JSON" do
      assert {:error, %DecodeError{reason: :invalid_json}} =
               Fixture.decode("not json{{{")
    end

    test "not a JSON object" do
      assert {:error, %DecodeError{reason: :not_an_object}} =
               Fixture.decode("[1,2,3]")
    end

    test "missing record discriminator" do
      assert {:error, %DecodeError{reason: :missing_record_type}} =
               Fixture.decode(~s({"foo":1}))
    end

    test "unknown record discriminator" do
      assert {:error,
              %DecodeError{reason: :unknown_record_type, details: "bogus"}} =
               Fixture.decode(~s({"record":"bogus"}))
    end

    test "header missing a required field" do
      assert {:error, %DecodeError{reason: :missing_field, details: "backend"}} =
               Fixture.decode(
                 ~s({"record":"header","schema":"harness-fixture/1","envelope_v":1,) <>
                   ~s("harness_version":"0.1.0","model":"m","config_hash":"c","kind":"golden"})
               )
    end

    test "header with wrong field type" do
      assert {:error,
              %DecodeError{
                reason: :invalid_field_type,
                details: {"envelope_v", "one"}
              }} =
               Fixture.decode(
                 ~s({"record":"header","schema":"harness-fixture/1","envelope_v":"one",) <>
                   ~s("harness_version":"0.1.0","backend":"b","model":"m","config_hash":"c","kind":"golden"})
               )
    end

    test "header with unsupported schema" do
      assert {:error,
              %DecodeError{reason: :unsupported_schema, details: "nope/9"}} =
               Fixture.decode(
                 ~s({"record":"header","schema":"nope/9","envelope_v":1,"harness_version":"0.1.0",) <>
                   ~s("backend":"b","model":"m","config_hash":"c","kind":"golden"})
               )
    end

    test "header with invalid kind enum value" do
      assert {:error,
              %DecodeError{
                reason: :invalid_field_value,
                details: {"kind", "bogus"}
              }} =
               Fixture.decode(
                 ~s({"record":"header","schema":"harness-fixture/1","envelope_v":1,) <>
                   ~s("harness_version":"0.1.0","backend":"b","model":"m","config_hash":"c","kind":"bogus"})
               )
    end

    test "envelope with unsupported (future) envelope_v" do
      assert {:error,
              %DecodeError{reason: :unsupported_envelope_version, details: 99}} =
               Fixture.decode(
                 ~s({"record":"envelope","v":99,"session_id":"s","kind":"event",) <>
                   ~s("body":{"id":1,"ts":1,"family":"loop","type":"turn_started",) <>
                   ~s("tier":"durable","payload":{}}})
               )
    end

    test "envelope body with unknown top-level Event.type is a loud, strict error" do
      assert {:error,
              %DecodeError{
                reason: :unknown_event_type,
                details: {:loop, "not_a_real_type"}
              }} =
               Fixture.decode(
                 ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
                   ~s("body":{"id":1,"ts":1,"family":"loop","type":"not_a_real_type",) <>
                   ~s("tier":"durable","payload":{}}})
               )
    end

    test "envelope body with invalid tier enum value" do
      assert {:error,
              %DecodeError{
                reason: :invalid_field_value,
                details: {"tier", "sometimes"}
              }} =
               Fixture.decode(
                 ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
                   ~s("body":{"id":1,"ts":1,"family":"loop","type":"idle",) <>
                   ~s("tier":"sometimes","payload":{}}})
               )
    end

    test "envelope body missing a required field" do
      assert {:error, %DecodeError{reason: :missing_field, details: "payload"}} =
               Fixture.decode(
                 ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
                   ~s("body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable"}})
               )
    end
  end

  describe "load/1 whole-file structural errors" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "tf-fixture-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "envelope before header", %{dir: dir} do
      path = Path.join(dir, "bad.jsonl")

      File.write!(path, """
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable","payload":{}}}
      """)

      assert {:error, %DecodeError{reason: :envelope_before_header, offset: 1}} =
               Fixture.load(path)
    end

    test "duplicate header", %{dir: dir} do
      path = Path.join(dir, "bad.jsonl")
      header = header_line()

      File.write!(path, header <> "\n" <> header <> "\n")

      assert {:error, %DecodeError{reason: :duplicate_header, offset: 2}} =
               Fixture.load(path)
    end

    test "missing header entirely (file of only envelopes never reaches one)",
         %{dir: dir} do
      path = Path.join(dir, "bad.jsonl")
      # a single malformed-as-envelope-before-header line surfaces that
      # error first; an EMPTY file (zero lines) is the true "no header
      # ever seen" case.
      File.write!(path, "")

      assert {:error, %DecodeError{reason: :missing_header}} =
               Fixture.load(path)
    end

    test "a malformed line deep in the file reports its real line offset", %{
      dir: dir
    } do
      path = Path.join(dir, "bad.jsonl")

      File.write!(path, """
      #{header_line()}
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable","payload":{}}}
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":2,"ts":2,"family":"loop","type":"not_real","tier":"durable","payload":{}}}
      """)

      assert {:error, %DecodeError{reason: :unknown_event_type, offset: 3}} =
               Fixture.load(path)
    end

    test "unreadable file surfaces a file_error, not a crash", %{dir: dir} do
      path = Path.join(dir, "does-not-exist.jsonl")
      assert {:error, %DecodeError{reason: :file_error}} = Fixture.load(path)
    end

    test "an interior blank line is a loud :blank_line error at its physical line",
         %{dir: dir} do
      path = Path.join(dir, "blank.jsonl")

      envelope =
        ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
          ~s("body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable","payload":{}}})

      # blank line at physical line 2, between header and envelope —
      # silently skipping it would desync offset from line number.
      File.write!(path, header_line() <> "\n\n" <> envelope <> "\n")

      assert {:error, %DecodeError{reason: :blank_line, offset: 2}} =
               Fixture.load(path)
    end

    test "trailing final newline(s) stay tolerated, offsets unaffected", %{
      dir: dir
    } do
      path = Path.join(dir, "trailing.jsonl")

      envelope =
        ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
          ~s("body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable","payload":{}}})

      File.write!(path, header_line() <> "\n" <> envelope <> "\n\n\n")

      assert {:ok, %Session{envelopes: [%Envelope{offset: 2}]}} =
               Fixture.load(path)
    end
  end

  # -- upcast ---------------------------------------------------------------

  describe "Upcast.to_current/2" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "tf-fixture-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "fills scope and provenance when absent on disk (non-tool payload -> trusted)",
         %{dir: dir} do
      path = Path.join(dir, "old.jsonl")

      File.write!(path, """
      #{header_line()}
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":1,"ts":1,"family":"loop","type":"idle","tier":"durable","payload":{}}}
      """)

      assert {:ok, %Session{envelopes: [%Envelope{body: body}]}} =
               Fixture.load(path)

      assert body.scope == :session
      assert body.provenance == %{source: "primary", trust: :trusted}
    end

    test "absent provenance on a tool_result payload loads as :tainted (fail-safe, FI-5)",
         %{dir: dir} do
      path = Path.join(dir, "tool.jsonl")

      File.write!(path, """
      #{header_line()}
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":1,"ts":1,"family":"loop","type":"item_completed","tier":"durable","payload":{"item_id":"i1","item_type":"tool_result","content":"tool output of unknown origin"}}}
      """)

      assert {:ok, %Session{envelopes: [%Envelope{body: body}]}} =
               Fixture.load(path)

      # unknown-origin tool data must never launder to trusted through
      # a missing provenance field
      assert body.provenance == %{source: "primary", trust: :tainted}
    end

    test "the multi-tool-turn golden's tool_results load tainted end-to-end" do
      assert {:ok, session} =
               Fixture.load(Path.join(@sessions_dir, "multi-tool-turn.jsonl"))

      tool_results =
        session.envelopes
        |> Enum.map(& &1.body)
        |> Enum.filter(&(&1.payload["item_type"] == "tool_result"))

      assert tool_results != []
      assert Enum.all?(tool_results, &(&1.provenance.trust == :tainted))
    end

    test "leaves explicit scope/provenance untouched", %{dir: dir} do
      path = Path.join(dir, "explicit.jsonl")

      File.write!(path, """
      #{header_line()}
      {"record":"envelope","v":1,"session_id":"s","kind":"event","body":{"id":1,"ts":1,"family":"meta","type":"promote","tier":"durable","scope":"global","provenance":{"source":"probe_meta_adr","trust":"tainted"},"payload":{}}}
      """)

      assert {:ok, %Session{envelopes: [%Envelope{body: body}]}} =
               Fixture.load(path)

      assert body.scope == :global
      assert body.provenance == %{source: "probe_meta_adr", trust: :tainted}
    end

    test "upcast is idempotent across every fixture envelope (I5 invariant)" do
      for name <- @all_names, line <- read_envelope_lines(name) do
        assert {:ok, %Envelope{} = envelope} = Fixture.decode(line)

        once = Upcast.to_current(1, envelope)
        assert Upcast.to_current(1, once) == once
      end
    end

    test "upcast is idempotent on a provenance-absent synthetic (both trust branches)" do
      for item_type <- ["tool_result", "message"] do
        line =
          ~s({"record":"envelope","v":1,"session_id":"s","kind":"event",) <>
            ~s("body":{"id":1,"ts":1,"family":"loop","type":"item_completed",) <>
            ~s("tier":"durable","payload":{"item_id":"i1","item_type":"#{item_type}","content":"x"}}})

        assert {:ok, %Envelope{body: %{provenance: nil}} = envelope} =
                 Fixture.decode(line)

        once = Upcast.to_current(1, envelope)
        assert once.body.provenance != nil
        assert Upcast.to_current(1, once) == once
      end
    end

    test "decode is lossless and load never rewrites the file (disk-byte freeze)" do
      for name <- @golden_names do
        path = Path.join(@sessions_dir, name <> ".jsonl")

        bytes_before = File.read!(path)
        assert {:ok, _session} = Fixture.load(path)
        assert File.read!(path) == bytes_before

        # every envelope, re-serialized WITHOUT upcast fills, is
        # value-faithful to its disk line: explicit provenance/scope
        # survive, absent ones stay absent — locking "upcast fills
        # absents only, never mutates the source"
        for line <- read_envelope_lines(name) do
          assert {:ok, %Envelope{} = envelope} = Fixture.decode(line)
          assert to_wire(envelope) == Jason.decode!(line)
        end
      end
    end
  end

  # -- bless task -------------------------------------------------------------

  describe "mix raxol.harness.fixtures.bless" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "tf-bless-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      for name <- @all_names do
        File.cp!(
          Path.join(@sessions_dir, name <> ".jsonl"),
          Path.join(dir, name <> ".jsonl")
        )
      end

      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "blesses every golden fixture, skips the adversarial one", %{dir: dir} do
      assert {:ok, results} = Bless.run(dir: dir)
      by_name = Map.new(results, &{&1.name, &1})

      for name <- @golden_names do
        result = Map.fetch!(by_name, name)
        # Path.rootname (product side) normalizes separators to "/" while
        # Path.join keeps the tmp-dir's native separators; expand both so the
        # comparison is separator-agnostic on Windows.
        assert Path.expand(result.blocks_path) ==
                 Path.expand(Path.join(dir, name <> ".blocks.json"))
        assert File.exists?(result.blocks_path)
        assert result.count > 0
      end

      adversarial = Map.fetch!(by_name, "adversarial")
      assert adversarial.blocks_path == nil
      assert adversarial.count == 0
    end

    test "round-trips: blessing twice produces byte-identical snapshots", %{
      dir: dir
    } do
      assert {:ok, _} = Bless.run(dir: dir)
      first_bytes = File.read!(Path.join(dir, "simple-chat.blocks.json"))

      assert {:ok, _} = Bless.run(dir: dir)
      second_bytes = File.read!(Path.join(dir, "simple-chat.blocks.json"))

      assert first_bytes == second_bytes

      decoded = Jason.decode!(first_bytes)
      assert decoded["schema"] == "harness-fixture-blocks/1"
      assert decoded["projector"] == "Raxol.Harness.Fixture.Projectors.Identity"
      assert length(decoded["blocks"]) == 6
    end

    test "an explicit --projector-equivalent module is honored", %{dir: dir} do
      assert {:ok, results} =
               Bless.run(
                 dir: dir,
                 projector: CountingProjector,
                 names: ["simple-chat"]
               )

      [%{blocks_path: blocks_path}] = results

      decoded = Jason.decode!(File.read!(blocks_path))
      assert decoded["blocks"] == %{"envelope_count" => 6}

      assert decoded["projector"] ==
               "Raxol.Harness.TFFixtureTest.CountingProjector"
    end

    test "the actual mix task runs end-to-end via --dir", %{dir: dir} do
      Mix.Task.rerun("raxol.harness.fixtures.bless", ["--dir", dir])
      assert File.exists?(Path.join(dir, "multi-tool-turn.blocks.json"))
    end

    test "check mode: fresh snapshots pass, writes nothing", %{dir: dir} do
      assert {:ok, _} = Bless.run(dir: dir)

      snapshot_path = Path.join(dir, "simple-chat.blocks.json")
      before_bytes = File.read!(snapshot_path)

      assert {:ok, results} = Bless.run(dir: dir, check: true)

      for %{name: name, status: status} <- results do
        if name == "adversarial" do
          assert status == :skipped
        else
          assert status == :current
        end
      end

      # check mode never writes
      assert File.read!(snapshot_path) == before_bytes
    end

    test "check mode: a stale snapshot is drift", %{dir: dir} do
      assert {:ok, _} = Bless.run(dir: dir)

      snapshot_path = Path.join(dir, "simple-chat.blocks.json")
      File.write!(snapshot_path, "{\"stale\": true}\n")

      assert {:error, {:drift, ["simple-chat"]}} = Bless.run(dir: dir, check: true)

      # and drift never overwrites — the mutation is still on disk
      assert File.read!(snapshot_path) == "{\"stale\": true}\n"
    end

    test "check mode: a missing snapshot is drift", %{dir: dir} do
      assert {:ok, _} = Bless.run(dir: dir)
      File.rm!(Path.join(dir, "long-folds.blocks.json"))

      assert {:error, {:drift, ["long-folds"]}} = Bless.run(dir: dir, check: true)
    end

    test "the mix task --check exits non-zero on drift, passes when current", %{
      dir: dir
    } do
      Mix.Task.rerun("raxol.harness.fixtures.bless", ["--dir", dir])

      # current -> no raise
      Mix.Task.rerun("raxol.harness.fixtures.bless", ["--check", "--dir", dir])

      File.write!(Path.join(dir, "simple-chat.blocks.json"), "{\"stale\": true}\n")

      assert_raise Mix.Error, ~r/snapshot drift: simple-chat/, fn ->
        Mix.Task.rerun("raxol.harness.fixtures.bless", ["--check", "--dir", dir])
      end
    end
  end

  defp header_line do
    ~s({"record":"header","schema":"harness-fixture/1","envelope_v":1,"harness_version":"0.1.0",) <>
      ~s("backend":"b","model":"m","config_hash":"c","kind":"golden"})
  end

  # Raw envelope lines (header dropped) of a checked-in fixture.
  defp read_envelope_lines(name) do
    Path.join(@sessions_dir, name <> ".jsonl")
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.drop(1)
  end

  # Re-serialize a decoded (pre-upcast) envelope back to its wire shape.
  # Optional fields absent on disk stay absent here — comparing against
  # `Jason.decode!(line)` proves decode invents nothing and loses
  # nothing (JSON objects are unordered, so value equality is the
  # byte-faithfulness criterion for a single JSON line).
  defp to_wire(%Envelope{} = envelope) do
    body = envelope.body

    body_map =
      %{
        "id" => body.id,
        "ts" => body.ts,
        "family" => to_string(body.family),
        "type" => to_string(body.type),
        "tier" => to_string(body.tier),
        "payload" => body.payload
      }
      |> put_present("turn_id", body.turn_id)
      |> put_present("scope", body.scope && to_string(body.scope))
      |> put_present("provenance", provenance_to_wire(body.provenance))

    %{
      "record" => "envelope",
      "v" => envelope.v,
      "session_id" => envelope.session_id,
      "kind" => to_string(envelope.kind),
      "body" => body_map
    }
  end

  defp provenance_to_wire(nil), do: nil

  defp provenance_to_wire(%{source: source, trust: trust}) do
    %{"source" => source, "trust" => to_string(trust)}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
