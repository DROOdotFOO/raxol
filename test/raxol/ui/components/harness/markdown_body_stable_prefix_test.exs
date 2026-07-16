defmodule Raxol.UI.Components.Harness.MarkdownBodyStablePrefixTest do
  @moduledoc """
  Stable-prefix (incremental) streaming render of `MarkdownBody`.

  The contract under test: `MarkdownBody.render_streaming_incremental/3`
  takes the FULL accumulated text (append-only across deltas), a
  checkpoint carried from the previous call, and a width, and returns
  `{view, checkpoint}` where `view` is EXACTLY what the existing full
  re-parse (`MarkdownBody.render(text, %{mode: :streaming, width: w})`)
  would return -- element-for-element, at EVERY prefix. The full render
  is the correctness oracle; the checkpoint is purely an optimization
  that re-parses only the live tail after the last safe frozen boundary.

  Safe-boundary rule under test (the per-construct immutability proof,
  documented in `MarkdownBody`'s moduledoc):

  - only just past a committed `\\n` (the last, still-growing line is
    never frozen);
  - both fence state machines balanced -- the renderer's raw-prefix
    ```` ``` ````/`~~~` matching-marker machine AND provisional-close's
    trimmed-prefix machine (a fence, once CLOSED by a matching-marker
    line, can never be reopened by later bytes: the parser is
    forward-only, so its consumed extent is fixed);
  - the inline provisional-close scan stack is EMPTY (an unclosed
    `**`/`*`/`` ` ``/`[` on a committed line receives erasures/closers
    ACROSS later lines, so a boundary with live inline state is not
    stable);
  - the line immediately before the boundary contains no `|` (a
    `|`-containing line can still BECOME a table header when the next
    line arrives, and a still-absorbing table re-computes column widths
    over ALL rows -- later rows rewrite earlier rows' rendered text);
  - the raw frozen segment is valid UTF-8 (whole-buffer Latin-1 recovery
    after a genuinely-invalid byte is not tail-composable).

  Single-line constructs (headings, hr, blockquote, list items,
  paragraphs) are immutable the moment their `\\n` arrives -- this
  grammar has no multi-line nesting besides fences and tables.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.Fixture
  alias Raxol.UI.Components.Harness.MarkdownBody

  @fixture_path "test/fixtures/harness/sessions/markdown-stream.jsonl"
  @width 80

  # The correctness oracle: the existing, trusted full re-parse.
  defp oracle(text, width \\ @width) do
    MarkdownBody.render(text, %{mode: :streaming, width: width})
  end

  # Folds `chunks` through the incremental API, asserting oracle
  # equality at every accumulated prefix. Returns {final_text, final_cp,
  # per_step} where per_step is a list of {acc, view, cp} in order.
  defp assert_stream_equivalence(chunks, width \\ @width) do
    {steps, {final_acc, final_cp}} =
      Enum.map_reduce(chunks, {"", MarkdownBody.new_checkpoint()}, fn chunk,
                                                                      {acc, cp} ->
        acc = acc <> chunk

        {view, cp} = MarkdownBody.render_streaming_incremental(acc, width, cp)

        assert view == oracle(acc, width),
               "incremental view diverged from the full re-parse oracle\n" <>
                 "prefix: #{inspect(acc)}\n" <>
                 "incremental: #{inspect(view)}\n" <>
                 "oracle: #{inspect(oracle(acc, width))}"

        {{acc, view, cp}, {acc, cp}}
      end)

    {final_acc, final_cp, steps}
  end

  defp golden_deltas_and_final do
    {:ok, session} = Fixture.load(@fixture_path)

    chunks =
      session
      |> Fixture.Session.by_type(:item_delta)
      |> Enum.map(& &1.body.payload["chunk"])

    [completed] = Fixture.Session.by_type(session, :item_completed)
    final = completed.body.payload["content"]

    {chunks, final}
  end

  # --- SP-EQ: the equivalence spec (the load-bearing oracle property) ---

  describe "SP-EQ — incremental render equals full re-parse at every prefix" do
    # Fragments deliberately include unclosed inline constructs, stray
    # pipes, fence markers, and multibyte text -- the exact hazards the
    # checkpoint rule must refuse to freeze across.
    defp inline_fragment_gen do
      member_of([
        "plain words here",
        "**bold**",
        "*ital*",
        "`code`",
        "[t](http://x)",
        "**unclosed",
        "*dangling",
        "`open",
        "[half",
        "a | b | c",
        "text with | pipe",
        "日本語 😀 café",
        "__under__",
        "_u_",
        "***",
        "~~~"
      ])
    end

    defp line_gen do
      inline_fragment_gen()
      |> list_of(min_length: 1, max_length: 3)
      |> map(&Enum.join(&1, " "))
    end

    defp block_gen do
      one_of([
        map(line_gen(), &(&1 <> "\n")),
        constant("\n"),
        map(line_gen(), &("# " <> &1 <> "\n")),
        map(line_gen(), &("- " <> &1 <> "\n")),
        map(line_gen(), &("> " <> &1 <> "\n")),
        constant("---\n"),
        map(line_gen(), &("```elixir\n" <> &1 <> "\n```\n")),
        # unclosed fence (never yields a safe boundary after it opens)
        map(line_gen(), &("```\n" <> &1)),
        constant("| h1 | h2 |\n|---|---|\n| a | b |\n"),
        # header + partial separator: the premature-frame streaming shape
        constant("| h1 | h2 |\n|---|\n")
      ])
    end

    defp doc_gen do
      block_gen()
      |> list_of(min_length: 1, max_length: 6)
      |> map(&Enum.join(&1, ""))
    end

    # Splits `doc` into chunks by a list of byte sizes -- byte-granular,
    # so cuts land mid-grapheme, mid-marker, and mid-CRLF by design.
    defp split_by_sizes(doc, sizes) do
      {chunks, rest} =
        Enum.reduce_while(sizes, {[], doc}, fn size, {chunks, rest} ->
          case rest do
            "" ->
              {:halt, {chunks, ""}}

            _ ->
              take = min(size, byte_size(rest))
              chunk = binary_part(rest, 0, take)
              rest = binary_part(rest, take, byte_size(rest) - take)
              {:cont, {[chunk | chunks], rest}}
          end
        end)

      chunks = if rest == "", do: chunks, else: [rest | chunks]
      Enum.reverse(chunks)
    end

    property "arbitrary markdown streamed in arbitrary byte chunkings matches the oracle at every prefix" do
      check all(
              doc <- doc_gen(),
              sizes <- list_of(integer(1..9), max_length: 80),
              max_runs: 50
            ) do
        chunks = split_by_sizes(doc, sizes)
        assert_stream_equivalence(chunks)
      end
    end

    property "garbage binary chunks match the oracle at every prefix and never raise" do
      check all(
              chunks <- list_of(binary(max_length: 40), max_length: 6),
              max_runs: 100
            ) do
        assert_stream_equivalence(chunks)
      end
    end

    test "the golden fixture's 17 real delta chunks match the oracle at every boundary" do
      {chunks, _final} = golden_deltas_and_final()
      assert length(chunks) == 17
      assert_stream_equivalence(chunks)
    end

    test "character-granular streaming of the golden doc matches the oracle at every prefix" do
      {_chunks, final} = golden_deltas_and_final()
      chunks = final |> String.graphemes()
      assert_stream_equivalence(chunks)
    end
  end

  # --- SP-IMM: the frozen prefix is genuinely immutable ---

  describe "SP-IMM — frozen elements never change once frozen" do
    test "each returned view begins with exactly the checkpoint's frozen elements" do
      {chunks, _final} = golden_deltas_and_final()

      {_acc, _cp, steps} = assert_stream_equivalence(chunks)

      for {{_acc, view, cp}, next} <-
            Enum.zip(steps, tl(steps) ++ [nil]) do
        frozen = cp.frozen_elements

        # the checkpoint returned WITH a view is always a prefix of it...
        assert Enum.take(view.children, length(frozen)) == frozen,
               "checkpoint's frozen elements are not a prefix of its own view"

        # ...and of every LATER view (no flash/rewrite of frozen output).
        case next do
          nil ->
            :ok

          {_next_acc, next_view, _next_cp} ->
            assert Enum.take(next_view.children, length(frozen)) == frozen,
                   "a later delta rewrote already-frozen elements"
        end
      end
    end
  end

  # --- SP-HAZ: directed hazard cases (each names a clause of the boundary rule) ---

  describe "SP-HAZ — table lookahead: a committed '|' line must not freeze before its next line arrives" do
    test "a line that later becomes a table header is never frozen prematurely" do
      # After chunk 1, "| a | b |" is a committed plain-prose line; chunk
      # 2 retroactively makes it a TABLE HEADER. Freezing it after chunk
      # 1 would pin the prose parse. The no-pipe boundary clause forbids
      # that; equivalence holds at both steps.
      chunks = ["| a | b |\n", "|---|\n", "| 1 | 2 |\n", "\n", "after\n"]
      assert_stream_equivalence(chunks)
    end

    test "a later table row widening a column never rewrites frozen output" do
      # Column widths are computed over ALL rows -- the wide row in chunk
      # 3 re-renders the header/earlier rows. No part of the table may
      # freeze until the terminating pipe-free line has arrived.
      chunks = [
        "| a | b |\n|---|---|\n",
        "| x | y |\n",
        "| much-wider-cell-content | z |\n",
        "\n",
        "done\n"
      ]

      {_acc, cp, _steps} = assert_stream_equivalence(chunks)
      # after the pipe-free blank + "done" line the table is closed and
      # freezable -- the checkpoint must have advanced past it.
      assert cp.frozen_byte_offset > 0
    end
  end

  describe "SP-HAZ — open fence: no boundary inside an unterminated fence" do
    test "the checkpoint holds at the fence opener until the matching closer arrives" do
      opener = "```\n"
      chunks = [opener, "code | with pipe\n", "**not bold**\n", "```\n", "\n"]

      {_acc, _cp, steps} = assert_stream_equivalence(chunks)

      offsets =
        Enum.map(steps, fn {_acc, _view, cp} -> cp.frozen_byte_offset end)

      # while the fence is open (steps 1..3) nothing freezes...
      assert Enum.take(offsets, 3) == [0, 0, 0],
             "checkpoint advanced inside an open fence: #{inspect(offsets)}"

      # ...and once the matching closer has arrived, the closed fence
      # block becomes freezable.
      assert List.last(offsets) > 0,
             "checkpoint never advanced after the fence closed: #{inspect(offsets)}"
    end

    test "a mismatched ~~~ line inside a ``` fence does not create a boundary" do
      chunks = ["```\n", "~~~\n", "still code\n", "```\n", "\nafter\n"]

      {_acc, _cp, steps} = assert_stream_equivalence(chunks)

      offsets =
        Enum.map(steps, fn {_acc, _view, cp} -> cp.frozen_byte_offset end)

      assert Enum.take(offsets, 3) == [0, 0, 0]
    end
  end

  describe "SP-HAZ — live inline state: an unclosed emphasis spanning lines blocks the boundary" do
    test "a committed line with an unclosed ** does not freeze until the construct resolves" do
      chunks = ["start **bold\n", "still bold** done\n", "\n", "next\n"]

      {_acc, _cp, steps} = assert_stream_equivalence(chunks)

      offsets =
        Enum.map(steps, fn {_acc, _view, cp} -> cp.frozen_byte_offset end)

      # after chunk 1 the line is committed but the inline scan stack
      # still holds the open bold frame -- no boundary.
      assert hd(offsets) == 0,
             "froze a boundary with live inline state: #{inspect(offsets)}"

      # once the bold closes (chunk 2's line), the stack empties and the
      # boundary is allowed.
      assert Enum.at(offsets, 1) > 0
    end
  end

  describe "SP-HAZ — UTF-8 and CRLF chunk splits" do
    test "byte-by-byte streaming across multibyte graphemes matches the oracle at every byte" do
      doc = "café 日本語 😀 done\n\n**bold** more\n"

      chunks =
        for i <- 0..(byte_size(doc) - 1), do: binary_part(doc, i, 1)

      assert_stream_equivalence(chunks)
    end

    test "a chunk split between CR and LF matches the oracle at every step" do
      chunks = ["alpha\r", "\nbeta\r\n\r", "\ngamma **b** end\r", "\n"]
      assert_stream_equivalence(chunks)
    end

    test "a genuinely-invalid byte in a committed line degrades to the oracle without freezing past it" do
      # 0xFF can never begin a UTF-8 codepoint: whole-buffer recovery
      # Latin-1-converts everything after it, which is not
      # tail-composable -- so no boundary at or beyond the invalid byte.
      chunks = ["good line\n\n", <<"bad ", 0xFF, " line\n">>, "tail **b**\n"]
      assert_stream_equivalence(chunks)
    end
  end

  # --- SP-API: checkpoint lifecycle contract ---

  describe "SP-API — checkpoint lifecycle" do
    test "new_checkpoint/0 starts at offset zero with no frozen elements" do
      cp = MarkdownBody.new_checkpoint()
      assert cp.frozen_byte_offset == 0
      assert cp.frozen_elements == []
    end

    test "nil is accepted as a fresh checkpoint" do
      {view, cp} =
        MarkdownBody.render_streaming_incremental("hi **there**\n", @width, nil)

      assert view == oracle("hi **there**\n")
      assert cp.frozen_byte_offset >= 0
    end

    test "a stale checkpoint from DIFFERENT text (non-extension) resets instead of corrupting output" do
      {_view, cp} =
        MarkdownBody.render_streaming_incremental(
          "first doc line\n\nsecond paragraph\n\n",
          @width,
          MarkdownBody.new_checkpoint()
        )

      assert cp.frozen_byte_offset > 0

      # attacker/misuse case: same checkpoint, unrelated text. The guard
      # must detect the non-extension and fall back to a full parse.
      other = "completely different content **x**\n"

      {view, new_cp} =
        MarkdownBody.render_streaming_incremental(other, @width, cp)

      assert view == oracle(other)
      assert new_cp.frozen_byte_offset <= byte_size(other)
    end

    test "a width change invalidates the checkpoint (frozen elements are width-dependent)" do
      text =
        "a paragraph that is long enough to wrap differently at forty columns **bold**\n\nnext\n"

      {_view, cp} =
        MarkdownBody.render_streaming_incremental(text, 80, nil)

      {view_40, _cp} =
        MarkdownBody.render_streaming_incremental(text, 40, cp)

      assert view_40 == oracle(text, 40)
    end

    test "non-binary input matches the oracle and never raises" do
      {view, _cp} =
        MarkdownBody.render_streaming_incremental(%{not: "text"}, @width, nil)

      assert view == oracle(%{not: "text"})
    end
  end

  # --- SP-CAP: the 256KB ceiling applies to the TOTAL accumulated text ---

  describe "SP-CAP — the byte cap applies to the total, and resets the checkpoint" do
    @cap_bytes 256 * 1024

    test "above the cap the view is the oracle-identical plain-text fallback and the checkpoint resets" do
      small = "intro paragraph\n\n"
      huge = String.duplicate("word ", 60_000)
      total = small <> huge
      assert byte_size(total) > @cap_bytes

      {_view, cp} =
        MarkdownBody.render_streaming_incremental(small, @width, nil)

      {view, cp_after} =
        MarkdownBody.render_streaming_incremental(total, @width, cp)

      assert view == oracle(total)
      # fallback shape: exactly one plain text node (matches the
      # existing above-cap contract in markdown_body_test.exs).
      assert %{type: :column, children: [%{type: :text}]} = view
      assert cp_after.frozen_byte_offset == 0
      assert cp_after.frozen_elements == []
    end

    test "below the cap the parse path runs (fallback does NOT fire)" do
      text = "**bold** and *italic*\n"

      {view, _cp} =
        MarkdownBody.render_streaming_incremental(text, @width, nil)

      assert view == oracle(text)
      refute match?(%{children: [%{type: :text, content: ^text}]}, view)
    end
  end

  # --- SP-PERF: the O(N^2) -> O(N) pin ---

  # Order-of-magnitude convention (same as N-MDFUZZ-05 in
  # markdown_body_test.exs): generous absolute bounds that a
  # wrong-complexity implementation blows past by 10x+, never tight
  # wall-clock asserts -- CI runners are slow.

  describe "SP-PERF — incremental parse work is bounded by the live tail, not the total" do
    defp perf_doc do
      Enum.map_join(1..1_000, "", fn i ->
        "paragraph #{i} with **bold** text and `code` spans.\n\n"
      end)
    end

    defp line_deltas(doc) do
      lines = String.split(doc, "\n")
      {body, [last]} = Enum.split(lines, -1)
      deltas = Enum.map(body, &(&1 <> "\n"))
      if last == "", do: deltas, else: deltas ++ [last]
    end

    test "streaming 2000 lines keeps the checkpoint within a hop of the end (the frozen prefix tracks the stream)" do
      doc = perf_doc()
      deltas = line_deltas(doc)
      assert length(deltas) == 2_000

      {_acc, cp} =
        Enum.reduce(deltas, {"", MarkdownBody.new_checkpoint()}, fn delta,
                                                                    {acc, cp} ->
          acc = acc <> delta

          {_view, cp} =
            MarkdownBody.render_streaming_incremental(acc, @width, cp)

          {acc, cp}
        end)

      # every blank line is a safe boundary here, so the frozen offset
      # must sit within one paragraph (< 100 bytes) of the total --
      # THIS is the structural fact that makes total work O(N): the
      # re-parsed tail stays O(1) paragraphs regardless of history.
      assert cp.frozen_byte_offset >= byte_size(doc) - 100,
             "checkpoint failed to track the stream: frozen " <>
               "#{cp.frozen_byte_offset} of #{byte_size(doc)} bytes"

      # and the final incremental view still equals the oracle.
      {view, _cp} =
        MarkdownBody.render_streaming_incremental(
          doc,
          @width,
          cp
        )

      assert view == oracle(doc)
    end

    test "cumulative incremental work over 2000 line-deltas stays well under the never-hang bound" do
      # Pre-fix, every delta re-parses the FULL accumulated text: 2000
      # deltas x O(N) parse = O(N^2) total, which blows this bound by an
      # order of magnitude. Incremental work per delta is O(live tail)
      # (one paragraph), so the total stays comfortably inside it.
      doc = perf_doc()
      deltas = line_deltas(doc)

      {elapsed_us, _} =
        :timer.tc(fn ->
          Enum.reduce(deltas, {"", MarkdownBody.new_checkpoint()}, fn delta,
                                                                      {acc, cp} ->
            acc = acc <> delta

            {_view, cp} =
              MarkdownBody.render_streaming_incremental(acc, @width, cp)

            {acc, cp}
          end)
        end)

      assert elapsed_us < 2_000_000,
             "2000 incremental deltas took #{elapsed_us}us (bound 2000000)"
    end

    # Timing comparisons belong out of the default suite (:slow is
    # excluded by the repo's default run). This is the before/after
    # order-of-magnitude receipt, not a CI gate.
    @tag :slow
    test "incremental streaming beats per-delta full re-parse by an order of magnitude" do
      doc = perf_doc()
      deltas = line_deltas(doc)

      prefixes =
        deltas
        |> Enum.scan("", &(&2 <> &1))
        # every 10th prefix keeps the full-reparse arm tractable while
        # preserving the O(N^2)-vs-O(N) shape.
        |> Enum.take_every(10)

      {full_us, _} =
        :timer.tc(fn ->
          Enum.each(prefixes, &oracle/1)
        end)

      {incr_us, _} =
        :timer.tc(fn ->
          Enum.reduce(prefixes, MarkdownBody.new_checkpoint(), fn prefix, cp ->
            {_view, cp} =
              MarkdownBody.render_streaming_incremental(prefix, @width, cp)

            cp
          end)
        end)

      # generous 2x margin on an expected >=10x gap -- comparative, so
      # runner speed cancels out.
      assert incr_us * 2 < full_us,
             "incremental (#{incr_us}us) not clearly faster than " <>
               "full re-parse (#{full_us}us)"
    end
  end
end
