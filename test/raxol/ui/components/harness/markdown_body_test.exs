defmodule Raxol.UI.Components.Harness.MarkdownBodyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.Fixture
  alias Raxol.UI.Components.Harness.{Block, MarkdownBody}
  alias Raxol.UI.Components.MarkdownRenderer

  @fixture_path "test/fixtures/harness/sessions/markdown-stream.jsonl"

  # --- shared tree helpers (same conventions as markdown_renderer_test.exs
  # and block_test.exs: a local recursive flattener over the
  # `%{type: :column | :row | :text, ...}` element tree) ---

  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{type: :row, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(%{type: :column, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_), do: []

  defp full_text(rendered), do: rendered |> flat_texts() |> Enum.join("\n")

  defp assert_zero_gaps(%{type: type} = node) when type in [:column, :row] do
    assert Map.get(node, :gap) == 0,
           "#{type} container missing explicit gap: 0 -> #{inspect(node)}"

    node |> Map.get(:children, []) |> Enum.each(&assert_zero_gaps/1)
  end

  defp assert_zero_gaps(%{children: children}) when is_list(children) do
    Enum.each(children, &assert_zero_gaps/1)
  end

  defp assert_zero_gaps(_node), do: :ok

  # A rendered view must never leak a Markdown marker character as
  # literal text: every one of these is either consumed into a styled
  # span (bold/italic/code) or a fence delimiter line that never appears
  # in the output at all. Mirrors the existing suite's own convention
  # (`refute full_text(result) =~ "*"` etc. in markdown_renderer_test.exs).
  defp assert_no_raw_marker_leak(text) do
    refute text =~ "```",
           "fence marker leaked into rendered text: #{inspect(text)}"

    refute text =~ "*", "'*' leaked into rendered text: #{inspect(text)}"
    refute text =~ "_", "'_' leaked into rendered text: #{inspect(text)}"
    refute text =~ "`", "'`' leaked into rendered text: #{inspect(text)}"
  end

  # --- the golden fixture: 17 real delta chunks + the item_completed
  # content, loaded live from the fixture file (never hardcoded) so this
  # suite stays in sync with the recorded session. ---

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

  defp delta_prefixes(chunks), do: Enum.scan(chunks, "", &(&2 <> &1))

  # --- render/2 basic dispatch ---

  describe "render/2 dispatch" do
    test "defaults to :sealed mode when context is omitted" do
      rendered = MarkdownBody.render("**bold**")
      assert full_text(rendered) =~ "bold"
      refute full_text(rendered) =~ "*"
    end

    test ":sealed mode does a plain full parse (no provisional close applied)" do
      rendered = MarkdownBody.render("**unclosed", %{mode: :sealed, width: 80})
      # sealed trusts the content is final -- an actually-unclosed marker
      # in already-final content passes through exactly as MarkdownRenderer
      # would render it directly (existing "lone unmatched marker" behavior).
      direct = MarkdownRenderer.render_with_builtin("**unclosed", 80)

      assert flat_texts(%{type: :column, children: direct, gap: 0}) ==
               flat_texts(rendered)
    end

    test ":streaming mode applies provisional close before rendering" do
      rendered =
        MarkdownBody.render("some **bold", %{mode: :streaming, width: 80})

      text = full_text(rendered)

      assert text =~ "bold"
      refute text =~ "*"
    end
  end

  # --- P-MD-03: sealed render == full parse, provisional close discarded ---

  describe "P-MD-03 — sealed render equals full parse" do
    test "render_sealed on the golden doc's final content matches MarkdownRenderer directly" do
      {_chunks, final} = golden_deltas_and_final()

      sealed = MarkdownBody.render_sealed(final, 80)
      direct = MarkdownRenderer.render_with_builtin(final, 80)

      assert flat_texts(sealed) ==
               flat_texts(%{type: :column, children: direct, gap: 0})
    end

    test "an incomplete construct in the LAST delta-prefix never survives into the sealed render" do
      {chunks, final} = golden_deltas_and_final()
      last_prefix = chunks |> delta_prefixes() |> List.last()

      # the last prefix is exactly the full accumulated text; sealed
      # render of the true final content must equal full parse, never a
      # leftover provisional-close artifact from the streaming path.
      assert last_prefix == final

      assert full_text(MarkdownBody.render_sealed(final, 80)) ==
               full_text(MarkdownBody.render_sealed(last_prefix, 80))
    end
  end

  # --- P-MD-01 / P-MD-02: no raw-marker leak + never raises, at EVERY prefix ---

  describe "P-MD-01/02 — no raw-marker leak, never raises, at every prefix of the golden doc" do
    test "all 17 delta-boundary prefixes render without leaking a marker" do
      {chunks, _final} = golden_deltas_and_final()
      prefixes = delta_prefixes(chunks)
      assert length(prefixes) == 17

      for prefix <- prefixes do
        rendered = MarkdownBody.render(prefix, %{mode: :streaming, width: 80})
        assert %{type: :column} = rendered
        assert_no_raw_marker_leak(full_text(rendered))
      end
    end

    test "every character-granular prefix (not just chunk boundaries) renders without leaking a marker" do
      {_chunks, final} = golden_deltas_and_final()
      length = String.length(final)

      for n <- 0..length do
        prefix = String.slice(final, 0, n)
        rendered = MarkdownBody.render(prefix, %{mode: :streaming, width: 80})
        assert %{type: :column} = rendered
        assert_no_raw_marker_leak(full_text(rendered))
      end
    end

    property "arbitrary byte-prefixes of the golden doc never raise and never leak a fence marker" do
      {_chunks, final} = golden_deltas_and_final()
      byte_len = byte_size(final)

      check all(cut <- integer(0..byte_len), max_runs: 200) do
        # `binary_part` may cut mid multi-byte grapheme -- exercising
        # exactly the "incl. mid-grapheme" axis N-MDFUZZ-02 calls for.
        prefix = binary_part(final, 0, cut)

        rendered = MarkdownBody.render(prefix, %{mode: :streaming, width: 80})
        assert %{type: :column} = rendered
        # a split multi-byte grapheme can legitimately alter which glyphs
        # show up, but the fence delimiter itself is pure ASCII and must
        # never survive as literal text regardless of the cut point.
        refute full_text(rendered) =~ "```"
      end
    end
  end

  # --- P-MD-05: monotone-ish append (no from-scratch flashing of earlier lines) ---

  describe "P-MD-05 — provisional-close is monotone-ish across the delta stream" do
    test "each fully-arrived line's rendered text is never removed by a later delta" do
      {chunks, _final} = golden_deltas_and_final()
      prefixes = delta_prefixes(chunks)

      prefixes
      |> Enum.zip(tl(prefixes))
      |> Enum.each(fn {before, after_} ->
        # only meaningful right at a natural line boundary -- `before`
        # ending mid-line means its OWN last (in-progress) line was never
        # "fully arrived" and is expected to change.
        if String.ends_with?(before, "\n") do
          before_text =
            full_text(
              MarkdownBody.render(before, %{mode: :streaming, width: 80})
            )

          after_text =
            full_text(
              MarkdownBody.render(after_, %{mode: :streaming, width: 80})
            )

          assert String.starts_with?(after_text, before_text),
                 "later render dropped/rewrote earlier committed content\nbefore: #{inspect(before_text)}\nafter: #{inspect(after_text)}"
        end
      end)
    end
  end

  # --- P-MD-04 / table degradation: never a zero-width column collapse ---

  describe "P-MD-04 — tables degrade to a scrollable/clipped block, never zero-width columns" do
    defp table_lines(rendered) do
      rendered |> flat_texts() |> Enum.filter(&(&1 =~ "|"))
    end

    defp table_cells(line) do
      line
      |> String.trim()
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)
    end

    test "the golden doc's real table renders with no empty cell at a normal width" do
      {_chunks, final} = golden_deltas_and_final()
      rendered = MarkdownBody.render_sealed(final, 80)

      [header, separator | rows] = table_lines(rendered)
      assert table_cells(header) == ["check", "status", "ms"]
      refute Enum.any?(table_cells(separator), &(&1 == ""))
      assert length(rows) == 3

      for row <- rows, cell <- table_cells(row) do
        refute cell == "",
               "a table cell collapsed to zero width: #{inspect(row)}"
      end
    end

    test "an unclosed (still-streaming) table never collapses a column to zero width" do
      partial =
        "| check | status | ms |\n|---|---|---|\n| compile | ok | 812 "

      for width <- [1, 2, 3, 5, 8, 10, 40, 80] do
        rendered =
          MarkdownBody.render(partial, %{mode: :streaming, width: width})

        for line <- table_lines(rendered), cell <- table_cells(line) do
          refute cell == "",
                 "width #{width}: a table cell collapsed to zero width -> #{inspect(line)}"
        end
      end
    end

    test "extremely narrow width still never collapses a wide table's columns" do
      wide =
        "| alpha column | beta column | gamma column | delta column |\n" <>
          "|---|---|---|---|\n" <>
          "| one | two | three | four |\n"

      rendered = MarkdownBody.render_sealed(wide, 10)

      for line <- table_lines(rendered), cell <- table_cells(line) do
        refute cell == "",
               "column collapsed to zero width at narrow forced width"
      end
    end
  end

  # --- provisional_close/1: the closer for each construct named in the roadmap ---

  describe "provisional_close/1 — construct-by-construct" do
    test "does nothing to already-well-formed text" do
      assert MarkdownBody.provisional_close("plain text, no markers") ==
               "plain text, no markers"
    end

    test "closes an unclosed fenced code block" do
      closed = MarkdownBody.provisional_close("```elixir\ndef foo do\n  :ok")
      assert String.ends_with?(closed, "\n```")

      rendered = closed |> then(&MarkdownRenderer.render_with_builtin(&1, 80))

      full =
        flat_texts(%{type: :column, children: rendered, gap: 0})
        |> Enum.join("\n")

      refute full =~ "```"
      assert full =~ "def foo do"
    end

    test "closes unclosed bold (**)" do
      closed = MarkdownBody.provisional_close("some **bold text")
      assert closed == "some **bold text**"
    end

    test "closes unclosed bold (__)" do
      closed = MarkdownBody.provisional_close("some __bold text")
      assert closed == "some __bold text__"
    end

    test "closes unclosed italic (*)" do
      closed = MarkdownBody.provisional_close("some *italic text")
      assert closed == "some *italic text*"
    end

    test "closes unclosed italic (_)" do
      closed = MarkdownBody.provisional_close("some _italic text")
      assert closed == "some _italic text_"
    end

    test "closes an unclosed inline code span" do
      closed = MarkdownBody.provisional_close("run `mix test")
      assert closed == "run `mix test`"
    end

    test "closes nested constructs in LIFO order" do
      # bold opened, then italic opened, then italic closed inline via **;
      # only bold remains open by the end.
      closed = MarkdownBody.provisional_close("**bold and *italic* still bold")
      assert closed == "**bold and *italic* still bold**"
    end

    test "an opener with NOTHING typed after it yet is stripped, never closed into an empty span" do
      # Naively appending "**" here would produce "Summary of the ****" --
      # a degenerate empty bold span the underlying regex parser can't
      # match (it requires >= 1 non-marker char between delimiters), so
      # the raw asterisks would leak right back out. Stripping the
      # dangling opener is the correct provisional behavior instead.
      closed = MarkdownBody.provisional_close("Summary of the **")
      assert closed == "Summary of the "
      refute closed =~ "*"
    end

    test "a nested opener with nothing after it strips just the inner marker, keeping the outer's real content" do
      closed = MarkdownBody.provisional_close("**bold *")
      assert closed == "**bold **"

      rendered = closed |> then(&MarkdownRenderer.render_with_builtin(&1, 80))

      full =
        flat_texts(%{type: :column, children: rendered, gap: 0})
        |> Enum.join("\n")

      refute full =~ "*"
      assert full =~ "bold"
    end

    test "a lone dangling opener with nothing else in the buffer strips to empty" do
      assert MarkdownBody.provisional_close("**") == ""
    end

    test "an unclosed link's bracket is closed" do
      closed = MarkdownBody.provisional_close("see [the docs")
      assert closed == "see [the docs]"
    end

    test "an unclosed link URL is closed" do
      closed =
        MarkdownBody.provisional_close("see [the docs](http://example.com/path")

      assert closed == "see [the docs](http://example.com/path)"
    end

    test "content inside an open fence is never touched by inline-marker closing" do
      # a single '*' is common, legitimate Python/Elixir syntax and must
      # not trigger italic-closing INSIDE the still-open code block.
      closed =
        MarkdownBody.provisional_close("```python\ndef foo(*args):\n    pass")

      assert closed == "```python\ndef foo(*args):\n    pass\n```"
    end

    test "is a no-op for empty text" do
      assert MarkdownBody.provisional_close("") == ""
    end

    test "never mutates its input -- returns a new string, source untouched" do
      source = "some **bold"
      _closed = MarkdownBody.provisional_close(source)
      assert source == "some **bold"
    end
  end

  # --- N-MDFUZZ: never raise, bounded, safe on adversarial/garbage input ---

  describe "N-MDFUZZ-01 — arbitrary bytes never raise" do
    property "garbage binaries always render some safe view" do
      check all(garbage <- binary(max_length: 300), max_runs: 200) do
        rendered = MarkdownBody.render(garbage, %{mode: :streaming, width: 80})
        assert %{type: :column, children: children} = rendered
        assert is_list(children)
      end
    end
  end

  describe "N-MDFUZZ-02 — byte-prefix fuzz of a small corpus, never raise, no leak" do
    @corpus [
      "# Title\n\n**bold** and _em_ and `code` and [link](http://x.io)\n\n" <>
        "```elixir\ndef f, do: :ok\n```\n",
      "| a | b |\n|---|---|\n| 1 | 2 |\n",
      "- one\n- two\n  - nested *item*\n",
      # unicode-heavy: CJK + emoji + combining marks, exercises
      # mid-grapheme cuts (N-MDFUZZ-02's explicit axis).
      "日本語のテキスト **強調** と 🇯🇵👨‍👩‍👧‍👦 絵文字 and café"
    ]

    property "every byte prefix of every corpus doc renders without raising" do
      check all(
              doc <- member_of(@corpus),
              cut <- integer(0..300),
              max_runs: 300
            ) do
        prefix = binary_part(doc, 0, min(cut, byte_size(doc)))

        rendered = MarkdownBody.render(prefix, %{mode: :streaming, width: 80})
        assert %{type: :column} = rendered
        refute full_text(rendered) =~ "```"
      end
    end
  end

  describe "N-MDFUZZ-03 — pathological nesting stays bounded, no stack blow-up" do
    test "many unclosed fences/bold/nesting complete quickly" do
      pathological =
        String.duplicate("```\n", 50) <>
          String.duplicate("**", 200) <> String.duplicate("* item\n", 200)

      {elapsed_us, rendered} =
        :timer.tc(fn ->
          MarkdownBody.render(pathological, %{mode: :streaming, width: 80})
        end)

      assert %{type: :column} = rendered
      # generous bound -- the point is "doesn't hang", not a perf budget
      assert elapsed_us < 2_000_000
    end

    test "deeply nested emphasis never raises" do
      deep =
        String.duplicate("*", 500) <> "center" <> String.duplicate("_", 500)

      rendered = MarkdownBody.render(deep, %{mode: :streaming, width: 80})
      assert %{type: :column} = rendered
    end
  end

  # --- N-MDFUZZ-05: large-input performance (the O(n^2)/O(n^3) regression
  # lock). Provisional close is single-pass O(n): one scan builds the
  # open-construct stack, one tail-walk resolves it -- no re-scan loop, no
  # per-char full-stack sweep. These would time out under the old
  # rescan-per-strip + mark_content-per-char design. ---

  describe "N-MDFUZZ-05 — large opener runs stay bounded (single-pass O(n))" do
    @perf_bound_us 2_000_000

    test "20k unclosed brackets render well under the never-hang bound" do
      doc = String.duplicate("[", 20_000)

      {elapsed_us, rendered} =
        :timer.tc(fn ->
          MarkdownBody.render(doc, %{mode: :streaming, width: 80})
        end)

      assert %{type: :column} = rendered

      assert elapsed_us < @perf_bound_us,
             "20k-bracket render took #{elapsed_us}us (bound #{@perf_bound_us})"

      # all openers are content-free -> stripped away, no marker leak
      refute rendered |> flat_texts() |> Enum.join("\n") =~ "["
    end

    test "50k unclosed brackets still bounded" do
      doc = String.duplicate("[", 50_000)

      {elapsed_us, rendered} =
        :timer.tc(fn ->
          MarkdownBody.render(doc, %{mode: :streaming, width: 80})
        end)

      assert %{type: :column} = rendered

      assert elapsed_us < @perf_bound_us,
             "50k-bracket render took #{elapsed_us}us (bound #{@perf_bound_us})"
    end

    test "mixed 10k brackets + 5k bold openers stays bounded" do
      # The 5k "**" pair up (open/close), so they count as content after
      # the 10k "[" -- those brackets get closed as literal "[...]" rather
      # than stripped. Degenerate pure-marker runs like this render
      # literally (empty "[]"/"**" spans have no styled form); the
      # invariant under test here is the O(n) TIME bound, not the (moot)
      # leak shape of an all-marker input.
      doc = String.duplicate("[", 10_000) <> String.duplicate("**", 5_000)

      {elapsed_us, rendered} =
        :timer.tc(fn ->
          MarkdownBody.render(doc, %{mode: :streaming, width: 80})
        end)

      assert %{type: :column} = rendered

      assert elapsed_us < @perf_bound_us,
             "mixed-opener render took #{elapsed_us}us (bound #{@perf_bound_us})"
    end

    test "cumulative streaming: provisional_close on every prefix 1..n of a large opener run stays bounded" do
      # This is the real-world risk: an operator watches a message stream
      # in, and the projection re-renders at EVERY delta. The sum of
      # per-prefix work is the Theta(n^3) case pre-fix (each of n prefixes
      # cost Theta(n^2)); single-pass makes each prefix O(k), so the sum is
      # Theta(n^2) -- comfortably bounded here.
      n = 2_000
      openers = String.duplicate("[", n)
      prefixes = for k <- 1..n, do: binary_part(openers, 0, k)

      {elapsed_us, _results} =
        :timer.tc(fn ->
          Enum.each(prefixes, &MarkdownBody.provisional_close/1)
        end)

      assert elapsed_us < @perf_bound_us,
             "cumulative #{n}-prefix stream took #{elapsed_us}us (bound #{@perf_bound_us})"
    end

    test "the >256KB degradation ceiling returns the text unchanged (no scan)" do
      # Above the cap, provisional_close is skipped entirely -- a pure
      # safety belt (the single-pass O(n) scan is the actual fix). Verify
      # the degradation path is a fast identity return.
      huge = String.duplicate("[", 300 * 1024)

      {elapsed_us, result} =
        :timer.tc(fn -> MarkdownBody.provisional_close(huge) end)

      assert result == huge
      assert elapsed_us < @perf_bound_us
    end
  end

  describe "N-MDFUZZ-04 — adversarial width (ZWJ, RTL, control chars), width via TextMeasure" do
    test "a table with wide/zero-width unicode content never crashes and stays framed" do
      adversarial =
        "| emoji | plain |\n|---|---|\n| 👨‍👩‍👧‍👦 | ​zero​ |\n"

      rendered = MarkdownBody.render_sealed(adversarial, 40)
      assert %{type: :column} = rendered
      assert full_text(rendered) =~ "plain"
    end

    test "control characters and RTL override marks never crash the renderer" do
      adversarial =
        "some \u{202E}text\u{202C} with \u{0000} control \u{200D} chars"

      rendered =
        MarkdownBody.render(adversarial, %{mode: :streaming, width: 20})

      assert %{type: :column} = rendered
    end
  end

  # --- Wire-in: Block's :message/:reasoning content via context[:markdown] ---

  describe "wire-in — Block.render/2 opt-in markdown option (T26 step 5)" do
    defp message_events(content) do
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :message, content: content}
        }
      ]
    end

    test "default (no :markdown key) renders exactly as before -- zero behavior change" do
      block =
        Block.from_events(:message, message_events("**bold** text"),
          fold: :expanded
        )

      plain = Block.render(block, %{width: 80})
      assert full_text(plain) =~ "**bold** text"
    end

    test "markdown: false explicitly behaves the same as omitted" do
      block =
        Block.from_events(:message, message_events("**bold** text"),
          fold: :expanded
        )

      rendered = Block.render(block, %{width: 80, markdown: false})
      assert full_text(rendered) =~ "**bold** text"
    end

    # The block HEADER always shows a raw first-line summary by design
    # (`Block.summary/1` -- unrelated to T26, unaffected by the markdown
    # option), so marker-leak assertions below check the CONTENT lines
    # (everything after the header), not the whole tree.
    defp content_only(rendered),
      do: rendered |> flat_texts() |> tl() |> Enum.join("\n")

    test "markdown: true on a SEALED message block does a full parse (no literal markers)" do
      block =
        Block.from_events(:message, message_events("some **bold** text"),
          fold: :expanded
        )
        |> Block.seal()

      rendered = Block.render(block, %{width: 80, markdown: true})

      assert content_only(rendered) =~ "bold"
      refute content_only(rendered) =~ "**"
    end

    test "markdown: true on a LIVE message block streams with provisional close" do
      block =
        Block.from_events(:message, message_events("some **bold"),
          fold: :expanded
        )

      assert Block.live?(block)
      rendered = Block.render(block, %{width: 80, markdown: true})

      assert content_only(rendered) =~ "bold"
      refute content_only(rendered) =~ "**"
    end

    test "markdown: true also applies to :reasoning blocks" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :reasoning, content: "thinking about **X**"}
        }
      ]

      block =
        Block.from_events(:reasoning, events, fold: :expanded) |> Block.seal()

      rendered = Block.render(block, %{width: 80, markdown: true})

      assert content_only(rendered) =~ "thinking about"
      assert content_only(rendered) =~ "X"
      refute content_only(rendered) =~ "**"
    end

    test "markdown: true does NOT affect other block kinds" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "Bash", args: %{}}}
        },
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_result, content: "**not markdown**"}
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :expanded)
      rendered = Block.render(block, %{width: 80, markdown: true})

      # tool_call bodies are never routed through MarkdownBody -- the
      # literal content (including any '**') passes through unchanged.
      assert full_text(rendered) =~ "**not markdown**"
    end

    test "folded blocks are unaffected by the markdown option (header-only render)" do
      block =
        Block.from_events(:message, message_events("**bold** text"),
          fold: :folded
        )

      rendered = Block.render(block, %{width: 80, markdown: true})
      assert length(flat_texts(rendered)) == 1
    end

    test "container gap discipline holds through the embedded MarkdownBody tree" do
      block =
        Block.from_events(
          :message,
          message_events(
            "# Title\n\n**bold** and a table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
          ),
          fold: :expanded
        )
        |> Block.seal()

      rendered = Block.render(block, %{width: 80, markdown: true})
      assert_zero_gaps(rendered)
    end

    test "never raises even with markdown: true and malformed content" do
      block = Block.from_events(:message, message_events(nil), fold: :expanded)
      rendered = Block.render(block, %{width: 80, markdown: true})
      assert %{type: :column} = rendered
    end
  end

  # --- prominence fade reaches the Markdown body (the bright-body-under-
  # faded-header gap): when a block is faded via context[:prominence], its
  # Markdown body must fade in lockstep -- every body text node carries
  # the same resolved :fg as the header, and a neutral (absent / 1.0)
  # prominence leaves the body byte-identical to a no-fade markdown
  # render. This case only exists once the T8 prominence wiring and the
  # T26 markdown routing live in the same tree. ---

  describe "markdown body fades with prominence" do
    # every :fg value carried by a text node anywhere in the tree
    defp text_node_fgs(%{type: :text, style: style}), do: [Map.get(style, :fg)]

    defp text_node_fgs(%{children: children}),
      do: Enum.flat_map(children, &text_node_fgs/1)

    defp text_node_fgs(_), do: []

    test "a faded block's markdown body text carries the SAME :fg as the header" do
      block =
        Block.from_events(
          :message,
          message_events("some **bold** and _em_ text across the body"),
          fold: :expanded
        )
        |> Block.seal()

      rendered =
        Block.render(block, %{width: 80, markdown: true, prominence: 0.6})

      fgs = text_node_fgs(rendered)

      # the fade actually fired (a resolved colour, not neutral)...
      assert [header_fg | _] = fgs
      assert is_binary(header_fg)

      # ...and EVERY text node (header + faded markdown body + outcome)
      # carries that one resolved colour -- no bright body under a faded
      # header.
      assert Enum.all?(fgs, &(&1 == header_fg)),
             "markdown body text did not fade to the header colour: #{inspect(fgs)}"
    end

    test "prominence 1.0 leaves the markdown body byte-identical to a no-fade render" do
      source = "some **bold** and _em_ text"

      block =
        Block.from_events(:message, message_events(source), fold: :expanded)
        |> Block.seal()

      faded_1_0 =
        Block.render(block, %{width: 80, markdown: true, prominence: 1.0})

      neutral =
        Block.render(block, %{width: 80, markdown: true})

      # 1.0 is the neutral case: no :fg is added anywhere...
      assert Enum.all?(text_node_fgs(faded_1_0), &is_nil/1)
      # ...and it is identical to omitting :prominence entirely.
      assert faded_1_0 == neutral

      # the body content lines (everything past the header) match a direct
      # MarkdownBody render of the same source -- routing untouched by the
      # neutral prominence.
      direct = MarkdownBody.render(source, %{width: 80, mode: :sealed})
      assert content_only(neutral) == full_text(direct)
    end

    test "prominence fades a plain (non-markdown) body to the header colour too" do
      # the same fade must hold on the plain path, so enabling markdown is
      # not what makes fade work -- it is the shared resolved colour.
      block =
        Block.from_events(
          :message,
          message_events("line one\nline two\nline three"),
          fold: :expanded
        )
        |> Block.seal()

      rendered = Block.render(block, %{width: 80, prominence: 0.6})
      fgs = text_node_fgs(rendered)

      assert [header_fg | _] = fgs
      assert is_binary(header_fg)
      assert Enum.all?(fgs, &(&1 == header_fg))
    end
  end

  # --- review round (Drew) ---------------------------------------------

  # HIGH: nested-emphasis marker leak at the streaming tail. The
  # renderer's builtin path uses a FLAT (non-recursive) regex grammar --
  # it can represent at most one active emphasis/code/link run at a
  # time. `provisional_close/1` used to close a genuinely nested,
  # never-closed chain by emitting one closer per still-open frame
  # (LIFO) -- a multi-character sequence like "***"/"___"/"`*" the flat
  # grammar can't parse back out, so it leaked raw markers. The fix:
  # only the OUTERMOST still-open construct gets a real closer; any
  # inner construct that never closed has its own opening token erased
  # instead (the real text after it is preserved, just no longer styled
  # separately).
  describe "review round (Drew), HIGH — nested-emphasis marker leak at the streaming tail" do
    test "review example 1: italic containing an unfinished bold attempt never leaks '**'" do
      rendered =
        MarkdownBody.render("note: *very **important", %{
          mode: :streaming,
          width: 80
        })

      text = full_text(rendered)
      refute text =~ "*"
      assert text =~ "very"
      assert text =~ "important"
    end

    test "review example 2: italic_under containing an unfinished bold_under attempt never leaks '__'" do
      rendered =
        MarkdownBody.render("text _a __b", %{mode: :streaming, width: 80})

      text = full_text(rendered)
      refute text =~ "_"
      assert text =~ "a"
      assert text =~ "b"
    end

    test "review example 3: italic containing an unfinished code attempt never leaks a backtick" do
      rendered = MarkdownBody.render("a *b `c", %{mode: :streaming, width: 80})

      text = full_text(rendered)
      refute text =~ "`"
      assert text =~ "b"
      assert text =~ "c"
    end

    test "provisional_close itself: only the outer construct survives, the inner opener is erased" do
      assert MarkdownBody.provisional_close("note: *very **important") ==
               "note: *very important*"

      assert MarkdownBody.provisional_close("text _a __b") == "text _a b_"
      assert MarkdownBody.provisional_close("a *b `c") == "a *b c*"
    end

    # Generalizes the three examples above: an arbitrarily deep chain of
    # GENUINELY nested (each level a different construct than its
    # immediate parent), never-closed emphasis constructs, whose text
    # leaves are letters/spaces only. Scoped to the four pure-emphasis
    # kinds (bold/italic, star/underscore) -- `:code` and link-bracket
    # nesting are deliberately excluded here: a code span's interior is
    # verbatim by design (CommonMark), so another kind's marker chars
    # legitimately surviving AS LITERAL CODE CONTENT when code is the
    # surviving outer construct is correct behavior, not a leak; and a
    # closed link-text bracket with no following `(url)` doesn't match
    # the renderer's link alternative at all (it requires the URL
    # suffix to recognize a link as a link) -- a separate, pre-existing
    # renderer gap, not this fix's target.
    #
    # Each generated doc draws from only ONE star-family kind (bold_star
    # XOR italic_star) and ONE underscore-family kind (bold_under XOR
    # italic_under). The two kinds in a family share a delimiter
    # character, so a byte-level cut landing mid a two-character opener
    # (e.g. `**`) leaves a single leftover marker that the scanner reads
    # as the OTHER, single-character member of that family -- if that
    # sibling kind were ALSO genuinely open elsewhere on the stack, the
    # leftover character would coincidentally (and correctly, per
    # CommonMark) close it rather than exercise a still-open,
    # never-closed frame. That's a real but SEPARATE, pre-existing
    # rendering limitation (the flat grammar doesn't recursively
    # re-parse a fully-resolved inner pair's content once it's embedded
    # in an outer span -- see `markdown_renderer_test.exs`'s existing
    # acceptance of "nested constructs in LIFO order"), not the
    # never-closes-at-all leak this test targets; restricting each run
    # to one kind per family keeps the fuzz focused on that.
    @emphasis_openers %{
      bold_star: "**",
      bold_under: "__",
      italic_star: "*",
      italic_under: "_"
    }

    defp emphasis_leaf_gen do
      [?a..?z, [?\s]]
      |> Enum.concat()
      |> StreamData.member_of()
      |> StreamData.list_of(min_length: 1, max_length: 6)
      |> StreamData.map(&List.to_string/1)
    end

    defp emphasis_kind_pool_gen do
      StreamData.tuple(
        {StreamData.member_of([:bold_star, :italic_star]),
         StreamData.member_of([:bold_under, :italic_under])}
      )
      |> StreamData.map(&Tuple.to_list/1)
    end

    defp level_pair_gen(pool) do
      StreamData.tuple({StreamData.member_of(pool), emphasis_leaf_gen()})
    end

    defp nested_never_closed_doc_gen do
      StreamData.bind(emphasis_kind_pool_gen(), fn pool ->
        StreamData.bind(emphasis_leaf_gen(), fn leading ->
          StreamData.bind(
            StreamData.list_of(level_pair_gen(pool),
              min_length: 1,
              max_length: 4
            ),
            fn levels ->
              deduped = Enum.dedup_by(levels, fn {kind, _leaf} -> kind end)

              doc =
                leading <>
                  Enum.map_join(deduped, fn {kind, leaf} ->
                    Map.fetch!(@emphasis_openers, kind) <> leaf
                  end)

              StreamData.constant(doc)
            end
          )
        end)
      end)
    end

    property "every prefix of an arbitrarily nested, never-closed emphasis chain renders with no marker leak" do
      check all(doc <- nested_never_closed_doc_gen(), max_runs: 200) do
        len = String.length(doc)

        for n <- 0..len do
          prefix = String.slice(doc, 0, n)
          # Exercise the builtin path directly (not `render/2`'s mode
          # dispatch) so this stays load-bearing even if dispatch logic
          # changes later -- EarmarkParser is a dev-only, compile-time
          # dependency here (never present in :test or production), so
          # the builtin regex parser is what actually ships; asserting
          # against it directly removes any ambiguity about which
          # parser produced the result.
          closed = MarkdownBody.provisional_close(prefix)
          elements = MarkdownRenderer.render_with_builtin(closed, 80)

          text =
            flat_texts(%{type: :column, children: elements, gap: 0})
            |> Enum.join("\n")

          refute text =~ ~r/[*_]/,
                 "leaked a marker for prefix #{inspect(prefix)} -> closed #{inspect(closed)} -> #{inspect(text)}"
        end
      end
    end
  end

  # MEDIUM: a delta can arrive mid multi-byte grapheme (an accented
  # letter, CJK, or emoji split across a chunk boundary). Reinterpreting
  # the WHOLE buffer as Latin-1 in that case mojibakes the already-valid,
  # already-committed leading text too. The fix keeps the longest valid
  # UTF-8 prefix untouched and only drops (or, if genuinely malformed,
  # lossily re-encodes) the trailing incomplete bytes.
  describe "review round (Drew), MEDIUM — mid-grapheme UTF-8 cut never mojibakes committed text" do
    test "a cut mid 2-byte accented character drops the incomplete tail instead of corrupting it" do
      # "café" = c,a,f + é (0xC3 0xA9). Cut after 0xC3 alone.
      cut = binary_part("café", 0, byte_size("café") - 1)
      rendered = MarkdownBody.render(cut, %{mode: :streaming, width: 80})
      text = full_text(rendered)

      assert text == "caf"
      refute text =~ "Ã"
    end

    test "a cut mid 3-byte CJK character drops the incomplete tail instead of corrupting it" do
      # "日" is E6 97 A5; cut after the first two bytes.
      full_char = "日"
      cut = binary_part(full_char, 0, byte_size(full_char) - 1)

      rendered =
        MarkdownBody.render("intro " <> cut, %{mode: :streaming, width: 80})

      text = full_text(rendered)

      assert text == "intro "
    end

    test "a cut mid 4-byte emoji drops the incomplete tail instead of corrupting it" do
      # "😀" is F0 9F 98 80; cut after the first three bytes.
      emoji = "😀"
      cut = binary_part(emoji, 0, byte_size(emoji) - 1)

      rendered =
        MarkdownBody.render("hi " <> cut, %{mode: :streaming, width: 80})

      text = full_text(rendered)

      assert text == "hi "
    end

    test "every byte-prefix of a multibyte-heavy fixture renders the already-valid leading text byte-identical, never mojibaked" do
      fixture = "café 日本語 😀 done"
      byte_len = byte_size(fixture)

      results =
        for cut <- 0..byte_len do
          prefix = binary_part(fixture, 0, cut)
          full_text(MarkdownBody.render(prefix, %{mode: :streaming, width: 80}))
        end

      # monotone: each successive (by one more byte) render's text either
      # equals the previous or extends it -- never mojibaked into
      # something shorter/different for the already-valid leading part.
      results
      |> Enum.zip(tl(results))
      |> Enum.each(fn {before, after_} ->
        assert String.starts_with?(after_, before) or
                 String.starts_with?(before, after_),
               "byte-prefix render was not consistent: #{inspect(before)} -> #{inspect(after_)}"
      end)

      # the classic UTF-8-as-Latin-1 mojibake signature never appears.
      refute Enum.any?(results, &(&1 =~ "Ã"))
    end

    test "a ZWJ family emoji split mid-sequence never crashes and never mojibakes plain ASCII around it" do
      family = "👨‍👩‍👧‍👦"
      doc = "before " <> family <> " after"
      byte_len = byte_size(doc)

      for cut <- 0..byte_len do
        prefix = binary_part(doc, 0, cut)
        rendered = MarkdownBody.render(prefix, %{mode: :streaming, width: 80})
        assert %{type: :column} = rendered
        text = full_text(rendered)
        refute text =~ "Ã"
      end
    end
  end

  # MEDIUM: the 256KB provisional-close cap guarded the cheap scan, but
  # the downstream full parse (re-run on every streaming delta) was
  # uncapped. The fix applies the same ceiling to the render path: above
  # it, render skips the parse and emits the raw buffer as plain text.
  #
  # These assert the ALGORITHMIC cap behavior with hard booleans (above
  # the cap -> un-parsed plain-text fallback; below it -> the parser
  # runs), never a wall-clock bound -- a timing assertion in the default
  # suite passes locally but flakes on a slow/contended CI runner. The
  # wall-clock perf check lives in the `:slow`-tagged test below, excluded
  # from the default CI run.
  describe "review round (Drew), MEDIUM — render path is byte-capped like provisional_close" do
    @cap_bytes 256 * 1024

    test "streaming render of a buffer ABOVE the cap takes the un-parsed plain-text fallback" do
      huge = String.duplicate("**bold** ", 40_000)
      assert byte_size(huge) > @cap_bytes

      rendered = MarkdownBody.render(huge, %{mode: :streaming, width: 80})

      # fallback = exactly one plain text node, byte-identical to the
      # buffer (a hard structural match -- the parse path would instead
      # have produced multiple/styled elements).
      assert %{type: :column, children: [%{type: :text, content: ^huge}]} =
               rendered

      # and because the parser never ran, the raw markers survive
      # verbatim -- the parse path would have consumed every "**" into a
      # styled bold span (see the below-cap test).
      assert full_text(rendered) =~ "**"
    end

    test "sealed render of a buffer ABOVE the cap also takes the fallback" do
      huge = String.duplicate("| a | b |\n", 40_000)
      assert byte_size(huge) > @cap_bytes

      rendered = MarkdownBody.render_sealed(huge, 80)

      assert %{type: :column, children: [%{type: :text, content: ^huge}]} =
               rendered
    end

    test "render of a buffer BELOW the cap is fully parsed (fallback does NOT fire)" do
      small = "**bold** and *italic*"
      assert byte_size(small) < @cap_bytes

      rendered = MarkdownBody.render(small, %{mode: :streaming, width: 80})

      # NOT the single-raw-text fallback node the above-cap path emits...
      refute match?(%{children: [%{type: :text, content: ^small}]}, rendered)

      # ...and the parser consumed every marker into a styled span, so no
      # raw marker survives in the rendered text.
      refute full_text(rendered) =~ "*"
      assert full_text(rendered) =~ "bold"
      assert full_text(rendered) =~ "italic"
    end

    # Timing belongs in bench, never the default suite -- `:slow` is
    # excluded by the repo's default `mix test` run. This is a documented
    # perf guard (the render cap keeps per-delta re-parse work bounded
    # even as an operator watches a large message stream in), not a CI
    # gate.
    @tag :slow
    test "N incremental streaming prefixes of a large document stay within budget" do
      doc = String.duplicate("some **bold** text and *italic* text.\n", 8_000)

      prefixes =
        for k <- 1..20, do: binary_part(doc, 0, div(byte_size(doc) * k, 20))

      {elapsed_us, _results} =
        :timer.tc(fn ->
          Enum.each(
            prefixes,
            &MarkdownBody.render(&1, %{mode: :streaming, width: 80})
          )
        end)

      assert elapsed_us < 2_000_000,
             "20 incremental large-doc renders took #{elapsed_us}us"
    end
  end

  # SECURITY: untrusted (e.g. LLM-generated) markdown must never carry a
  # raw control byte -- especially ESC -- out of this module, since an
  # embedded ANSI/OSC sequence would reach the terminal renderer as if it
  # were real (cursor move, screen clear, a fake title write), violating
  # the "never embed raw ANSI in text()" rule.
  describe "review round (Drew), SECURITY — control-char/ANSI sanitization" do
    test "ESC-based ANSI sequences (SGR color, screen clear) are stripped" do
      adversarial = "hi \e[31mRED\e[0m bye"

      rendered =
        MarkdownBody.render(adversarial, %{mode: :streaming, width: 80})

      text = full_text(rendered)

      refute text =~ "\e"
      assert text =~ "hi"
      assert text =~ "RED"
      assert text =~ "bye"
    end

    test "an OSC title-set sequence (ESC ] 0 ; ... BEL) is stripped" do
      adversarial = "hi \e]0;pwn\a bye"

      rendered =
        MarkdownBody.render(adversarial, %{mode: :streaming, width: 80})

      text = full_text(rendered)

      refute text =~ "\e"
      refute text =~ "\a"
      assert text =~ "hi"
      assert text =~ "bye"
    end

    test "assorted C0 controls and DEL are stripped, \\n and \\t are kept" do
      adversarial = "a\x00b\x01c\x02\nd\te\x7ff"
      rendered = MarkdownBody.render(adversarial, %{mode: :sealed, width: 80})
      text = full_text(rendered)

      assert Enum.all?(String.to_charlist(text), fn cp ->
               cp >= 0x20 or cp in [?\n, ?\t]
             end)

      refute text =~ "\x7f"
    end

    test "C1 controls (0x80-0x9F) are stripped" do
      adversarial = "a" <> <<0xC2, 0x9B>> <> "b"

      rendered =
        MarkdownBody.render(adversarial, %{mode: :streaming, width: 80})

      text = full_text(rendered)

      refute Enum.any?(String.to_charlist(text), &(&1 in 0x80..0x9F))
    end

    test "sanitization also applies to :sealed mode, not just :streaming" do
      adversarial = "hi \e[2J bye"
      rendered = MarkdownBody.render(adversarial, %{mode: :sealed, width: 80})
      refute full_text(rendered) =~ "\e"
    end
  end

  # LOW: table-row absorption used to swallow ANY later `|`-containing
  # line, ragged-row-ing ordinary prose that happened to contain a pipe
  # character. The fix stops absorption once a line's cell count no
  # longer matches the header's.
  describe "review round (Drew), LOW — table row absorption stops at a non-table-shaped line" do
    test "a table followed by an unrelated prose line containing a stray '|' does not absorb it as a row" do
      doc =
        "| check | status |\n" <>
          "|---|---|\n" <>
          "| compile | ok |\n" <>
          "the ratio a|b applies here\n"

      rendered = MarkdownBody.render_sealed(doc, 80)
      lines = flat_texts(rendered)

      assert Enum.any?(lines, &(&1 =~ "ratio a|b applies"))
      refute Enum.any?(lines, &(&1 == "| ratio a|b applies here |"))
    end

    test "a blank line still ends table-row absorption (existing GFM contiguity, unaffected)" do
      doc =
        "| check | status |\n" <>
          "|---|---|\n" <>
          "| compile | ok |\n" <>
          "\n" <>
          "some trailing prose\n"

      rendered = MarkdownBody.render_sealed(doc, 80)
      lines = flat_texts(rendered)

      assert Enum.any?(lines, &(&1 =~ "trailing prose"))
    end
  end

  # LOW: `fence_marker?` used to toggle on EITHER ``` or ~~~, so a
  # mismatched pair (opened with one, "closed" with the other) was
  # treated as a complete fence. The fix tracks the opening marker's
  # identity and only closes on a matching marker, in both
  # `provisional_close` and the renderer.
  describe "review round (Drew), LOW — mixed fence markers never cross-close" do
    test "an unclosed ~~~ fence is closed with a matching ~~~ (not ```)" do
      closed = MarkdownBody.provisional_close("~~~elixir\ndef foo do\n  :ok")
      assert String.ends_with?(closed, "\n~~~")
      refute closed =~ "```"
    end

    test "a ``` fence is NOT closed by an interior ~~~ line -- it stays open through it" do
      closed =
        MarkdownBody.provisional_close("```elixir\ndef foo do\n~~~\n  :ok")

      assert String.ends_with?(closed, "\n```")
      # the interior ~~~ line is preserved as fence content, not consumed
      # as a (mismatched) closer.
      assert closed =~ "~~~\n  :ok\n```"
    end

    test "the renderer treats a mismatched ```...~~~ pair as one still-open code block" do
      text = "```elixir\ndef foo do\n~~~\n  :ok\nend\n```\n"
      elements = MarkdownRenderer.render_with_builtin(text, 80)

      full =
        flat_texts(%{type: :column, children: elements, gap: 0})
        |> Enum.join("\n")

      assert full =~ "def foo do"
      assert full =~ "~~~"
      assert full =~ ":ok"
    end

    test "the renderer supports ~~~ fences on their own, same as ```" do
      text = "~~~\ndef foo do\n  :ok\nend\n~~~\n"
      elements = MarkdownRenderer.render_with_builtin(text, 80)

      full =
        flat_texts(%{type: :column, children: elements, gap: 0})
        |> Enum.join("\n")

      refute full =~ "~~~"
      assert full =~ "def foo do"
    end
  end
end
