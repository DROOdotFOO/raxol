defmodule Raxol.UI.Components.Harness.BlockBodyTest do
  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.UI.Components.Harness.{Block, BlockBody}

  @markdown_fixture_path "test/fixtures/harness/sessions/markdown-stream.jsonl"

  defp default_context,
    do: %{theme: Raxol.UI.Theming.Theme.default_theme(), width: 80}

  defp flat_texts(%{type: :text, content: content}), do: [content]

  # the Indication container (expanded thoughts) holds its tree in :content
  defp flat_texts(%{type: :indication, content: content})
       when is_binary(content),
       do: [content]

  defp flat_texts(%{type: :indication, content: content}),
    do: flat_texts(content)

  defp flat_texts(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_node), do: []

  defp flat_leaves(%{type: :text, content: content} = node),
    do: [{content, node[:style] || %{}}]

  defp flat_leaves(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_leaves/1)

  defp flat_leaves(_node), do: []

  defp strip_ids(map) when is_map(map) do
    map |> Map.delete(:id) |> Map.new(fn {k, v} -> {k, strip_ids(v)} end)
  end

  defp strip_ids(list) when is_list(list), do: Enum.map(list, &strip_ids/1)
  defp strip_ids(other), do: other

  defp message_block(text, opts) do
    Block.from_events(
      :message,
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :message, content: text}
        }
      ],
      Keyword.merge([fold: :expanded], opts)
    )
  end

  # Same golden-doc loading convention as markdown_body_test.exs: the
  # deltas and the final content come live from the fixture file, never
  # hardcoded.
  defp golden_deltas_and_final do
    {:ok, session} = Fixture.load(@markdown_fixture_path)

    chunks =
      session
      |> Fixture.Session.by_type(:item_delta)
      |> Enum.map(& &1.body.payload["chunk"])

    [completed] = Fixture.Session.by_type(session, :item_completed)
    {chunks, completed.body.payload["content"]}
  end

  defp delta_prefixes(chunks), do: Enum.scan(chunks, "", &(&2 <> &1))

  # -- one realistic events list per kind, reused for both fold states
  # (folded/expanded is a Block construction option, not a different
  # events shape -- these come from a real producer, not a synthetic map) --

  # Two lines on purpose: with the [assistant] tagline dead (speaker
  # separation), a single-line message's expanded body would be
  # indistinguishable from Block's own folded first-line summary -- the
  # second line is what only the expanded mount can show.
  defp events(:message) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{
          item_type: :message,
          content: "Deploy is done.\nAll checks green."
        }
      }
    ]
  end

  defp events(:reasoning) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{
          item_type: :reasoning,
          content: "Considering the rollback plan."
        }
      }
    ]
  end

  defp events(:tool_call) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{
          item_type: :tool_use,
          content: %{name: "Bash", args: %{command: "ls -la"}}
        }
      },
      %{
        id: 2,
        type: :item_completed,
        payload: %{item_type: :tool_result, content: "total 0\ndrwxr-xr-x"},
        provenance: %{trust: :tainted}
      }
    ]
  end

  defp events(:diff) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{
          path: "lib/orders/total.ex",
          old: "def total(x), do: x\n",
          new: "def total(x), do: x * 2\n"
        }
      }
    ]
  end

  defp events(:approval) do
    [
      %{
        id: 1,
        type: :approval_requested,
        payload: %{
          action: "rm -rf build/",
          blast_radius: %{
            writes: [],
            deletes: ["build/"],
            commands: [],
            network: [],
            reversible: false
          },
          options: [
            %{
              key: :allow_once,
              label: "Allow once",
              decision: :allow,
              scope: :once
            },
            %{key: :deny, label: "Deny", decision: :deny, scope: :once}
          ]
        }
      }
    ]
  end

  # The one substring that ONLY appears in the EXPANDED render, never in
  # the folded form -- proves "unfolding renders the full body" isn't
  # tautological.
  #
  # `message` (speaker separation: bare prose) shows its SECOND body line
  # only when expanded. `reasoning` and `tool_call` are the MACHINERY
  # register: folded is a compact count/receipt line (`⁖ thinking · N
  # lines` / `⚙ name(args) · receipt`) that never previews the content,
  # so their expanded-only marker is a line of the BODY itself (the
  # reasoning text / a tool-result line). `:approval` is absent: post-cull
  # its expanded form has no mounted component at all (it falls back to
  # Block.render/2 -- pinned below), so it has no component-only marker.
  @expanded_only_marker %{
    message: "All checks green.",
    reasoning: "Considering",
    tool_call: "drwxr-xr-x",
    diff: "Proposed change"
  }

  # The substring present in BOTH fold states. For message/diff the folded
  # summary previews a first-line/path identifier that the expanded body
  # repeats. For the machinery kinds the shared token is the compact-line
  # identity itself -- `reasoning` folds to `⁖ thinking · N lines` (and
  # the expanded render keeps that same header line above the ∵…∴
  # bracketed body), `tool_call` folds to `⚙ Bash(...) · ...` (name
  # preserved).
  @parity_marker %{
    message: "Deploy is done.",
    reasoning: "thinking",
    tool_call: "Bash",
    diff: "lib/orders/total.ex"
  }

  describe "fold round-trip: folded delegates to Block.render/2 verbatim" do
    for kind <- [:message, :reasoning, :tool_call, :diff, :approval] do
      test "#{kind}: folded BlockBody.render/2 output equals Block.render/2" do
        block =
          Block.from_events(unquote(kind), events(unquote(kind)), fold: :folded)

        assert BlockBody.render(block, default_context()) ==
                 Block.render(block, default_context())
      end
    end
  end

  describe "fold round-trip: expanded mounts the real component, folded does not" do
    for kind <- [:message, :reasoning, :tool_call, :diff] do
      test "#{kind}: expanded shows the component-only content; folded hides it" do
        folded =
          Block.from_events(unquote(kind), events(unquote(kind)), fold: :folded)

        expanded =
          Block.from_events(unquote(kind), events(unquote(kind)),
            fold: :expanded
          )

        folded_texts = flat_texts(BlockBody.render(folded, default_context()))

        expanded_texts =
          flat_texts(BlockBody.render(expanded, default_context()))

        marker = Map.fetch!(@expanded_only_marker, unquote(kind))

        assert Enum.any?(expanded_texts, &(&1 =~ marker)),
               "#{unquote(kind)} expanded render is missing its component-only marker #{inspect(marker)}"

        refute Enum.any?(folded_texts, &(&1 =~ marker)),
               "#{unquote(kind)} folded render leaked the expanded-only marker #{inspect(marker)} " <>
                 "-- folded must stay a one-line summary + outcome row, per T4"
      end

      test "#{kind}: content parity -- the folded summary and the expanded body agree on the shared identifier" do
        folded =
          Block.from_events(unquote(kind), events(unquote(kind)), fold: :folded)

        expanded =
          Block.from_events(unquote(kind), events(unquote(kind)),
            fold: :expanded
          )

        folded_texts = flat_texts(BlockBody.render(folded, default_context()))

        expanded_texts =
          flat_texts(BlockBody.render(expanded, default_context()))

        parity = Map.fetch!(@parity_marker, unquote(kind))

        assert Enum.any?(folded_texts, &(&1 =~ parity)),
               "#{unquote(kind)} folded summary lost the shared identifier #{inspect(parity)}"

        assert Enum.any?(expanded_texts, &(&1 =~ parity)),
               "#{unquote(kind)} expanded body lost the shared identifier #{inspect(parity)}"
      end
    end
  end

  describe "toggle_fold/2 round-trips through BlockBody, pre-seal" do
    test "toggling a live tool_call block's fold flips between the two renders" do
      block = Block.from_events(:tool_call, events(:tool_call), fold: :folded)

      # Folded is the compact one-line receipt (no result body); expanded
      # reveals the body under it -- "drwxr-xr-x" is a body-only line.
      folded_texts = flat_texts(BlockBody.render(block, default_context()))
      refute Enum.any?(folded_texts, &(&1 == "drwxr-xr-x"))

      expanded = Block.toggle_fold(block)
      expanded_texts = flat_texts(BlockBody.render(expanded, default_context()))
      assert Enum.any?(expanded_texts, &(&1 == "drwxr-xr-x"))

      refolded = Block.toggle_fold(expanded)

      assert BlockBody.render(refolded, default_context()) ==
               BlockBody.render(block, default_context())
    end
  end

  describe "expanded mount failure falls back to Block.render/2 safely" do
    test "an opaque (unrecognised) kind never crashes and renders Block's own opaque view" do
      block =
        Block.from_events(:totally_unknown, events(:message), fold: :expanded)

      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "totally_unknown"))
    end

    test "the fallback emits the block_body recovered telemetry event" do
      ref = make_ref()
      handler_id = {__MODULE__, ref}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :block_body, :recovered],
        fn event, _measurements, metadata, _config ->
          send(parent, {ref, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      block =
        Block.from_events(:totally_unknown, events(:message), fold: :expanded)

      BlockBody.render(block, default_context())

      assert_receive {^ref, [:raxol, :harness, :block_body, :recovered],
                      %{kind: :opaque}}
    end

    # Post-cull: an expanded bash/non-diff approval has NO mounted
    # component (the standalone gate components were demo-only). The
    # general clause's mount refuses :approval, and the block recovers to
    # the same Block.render/2 form the short-circuited kinds use -- the
    # referent still reaches the screen, and the fallback is never silent.
    test "an expanded bash approval falls back to Block.render/2 with recovered telemetry" do
      ref = make_ref()
      handler_id = {__MODULE__, ref}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :block_body, :recovered],
        fn event, _measurements, metadata, _config ->
          send(parent, {ref, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      block = Block.from_events(:approval, events(:approval), fold: :expanded)
      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "rm -rf build/")),
             "the approval's action must still reach the screen via the fallback"

      assert_receive {^ref, [:raxol, :harness, :block_body, :recovered],
                      %{kind: :approval}}
    end
  end

  # -- RED-1: a component that RAISES during expanded mount must recover
  # exactly like a mount `{:error, reason}` -- never escape BlockBody.render/2
  # (see the moduledoc's total-safety claim, block_body.ex:20-23).
  describe "expanded mount raise recovers to the same fallback as a mount error" do
    test "a :diff body with non-string old/new raises inside DiffViewer/LineDiff and recovers" do
      # `BodyProvider.mount/3` validates key PRESENCE only (see its
      # moduledoc's `:approval` note) -- a present-but-wrong-shaped value
      # is the producer's bug, and here it reaches all the way down to
      # `LineDiff.diff/2`'s `is_binary` guards. Constructed directly
      # (bypassing `Block.from_events/3`, whose own extraction always
      # stringifies `:old`/`:new`) since no real producer emits this shape
      # today -- this is BodyProvider's contract surface being exercised
      # directly, same as its moduledoc says it's built for.
      block = %Block{
        kind: :diff,
        raw_kind: :diff,
        event_refs: [],
        fold: :expanded,
        seal: :live,
        outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
        content: %{path: "lib/orders/total.ex", old: nil, new: 12_345}
      }

      ref = make_ref()
      handler_id = {__MODULE__, ref}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :block_body, :recovered],
        fn event, _measurements, metadata, _config ->
          send(parent, {ref, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "lib/orders/total.ex")),
             "expected the safe fallback (Block.render/2's own summary), " <>
               "not a crash"

      assert_receive {^ref, [:raxol, :harness, :block_body, :recovered],
                      %{kind: :diff, reason: reason}}

      assert reason =~ "FunctionClauseError",
             "expected the exception module in the recovered reason/metadata"
    end
  end

  # A message block reaching this path may still be LIVE: its accumulated
  # text can end inside an unclosed construct. BlockBody threads
  # `block.seal` into `BodyProvider.mount/3`, so a live body renders the
  # provisional-close streaming treatment and a sealed body the plain full
  # parse -- the transcript never flashes a raw marker mid-stream.
  describe "live markdown message bodies stream safely end-to-end" do
    test "a live expanded message with a trailing unclosed construct never leaks markers" do
      block = message_block("streaming **bold", seal: :live)
      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)

      # Mount-proof (the tagline is dead, so it can't serve as the
      # marker anymore): only the real MessageBlock's streaming path
      # provisionally closes the construct and renders the span BOLD --
      # Block.render/2's plain fallback has no styled leaves at all.
      assert Enum.any?(flat_leaves(rendered), fn {content, style} ->
               content =~ "bold" and style[:bold] == true
             end),
             "the real MessageBlock must mount (not the Block.render fallback)"

      assert Enum.any?(texts, &(&1 =~ "bold"))

      refute Enum.any?(texts, &(&1 =~ "*")),
             "a live message's unclosed bold marker leaked through BlockBody"
    end

    test "the same content sealed renders the final full parse -- the marker stays literal" do
      block = message_block("streaming **bold", seal: :sealed)
      texts = flat_texts(BlockBody.render(block, default_context()))

      assert Enum.any?(texts, &(&1 =~ "**")),
             "sealed content is final -- a genuinely-unclosed marker stays literal"
    end

    test "folding a live markdown block still delegates to Block.render/2 (fold x streaming interaction)" do
      block = message_block("streaming **bold", seal: :live, fold: :folded)

      assert BlockBody.render(block, default_context()) ==
               Block.render(block, default_context())
    end
  end

  describe "expanded render carries the completion row when the block has one" do
    test "a block with content.completion gets the row appended after the mounted component's own view" do
      block = Block.from_events(:message, events(:message), fold: :expanded)

      with_completion = %{
        block
        | content: Map.put(block.content, :completion, %{evidence: :none})
      }

      rendered = BlockBody.render(with_completion, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 == "no evidence provided")),
             "expected the completion row to survive the expanded mount path, got: #{inspect(texts)}"
    end

    test "a block with no completion key renders byte-identical to the unwrapped mount" do
      block = Block.from_events(:message, events(:message), fold: :expanded)

      refute Map.has_key?(block.content, :completion)

      {:ok, unwrapped_view} =
        Raxol.UI.Components.Harness.BodyProvider.mount(
          block.kind,
          block.content,
          context: default_context(),
          outcome: block.outcome,
          seal: block.seal
        )

      # Real mounted components (MessageBlock included) stamp a fresh
      # `:erlang.unique_integer/1`-derived id on every call -- unrelated
      # to this feature, and true of the render path before this change
      # too -- so ids are stripped from both sides before comparing.
      # What this test actually pins is structural: no extra wrapping
      # column, no extra row, when there is no completion key.
      assert strip_ids(BlockBody.render(block, default_context())) ==
               strip_ids(unwrapped_view)
    end

    test "a block with an unrecognized completion shape renders byte-identical to the unwrapped mount (completion_rows/2 returns [])" do
      block = Block.from_events(:message, events(:message), fold: :expanded)

      with_garbage_completion = %{
        block
        | content: Map.put(block.content, :completion, %{evidence: :garbage})
      }

      assert Block.completion_rows(with_garbage_completion) == [],
             "test premise: an unrecognized completion shape must render no rows at all"

      {:ok, unwrapped_view} =
        Raxol.UI.Components.Harness.BodyProvider.mount(
          with_garbage_completion.kind,
          with_garbage_completion.content,
          context: default_context(),
          outcome: with_garbage_completion.outcome,
          seal: with_garbage_completion.seal
        )

      assert strip_ids(
               BlockBody.render(with_garbage_completion, default_context())
             ) ==
               strip_ids(unwrapped_view),
             "an unrecognized completion shape must never trigger the completion-row wrapping column"
    end
  end

  describe "golden fixture: markdown streams through the full BlockBody path" do
    test "every delta-boundary prefix of a live message renders with no marker leak and no raw ANSI" do
      {chunks, _final} = golden_deltas_and_final()

      for prefix <- delta_prefixes(chunks) do
        block = message_block(prefix, seal: :live)
        texts = flat_texts(BlockBody.render(block, default_context()))

        for text <- texts do
          refute text =~ "\e",
                 "raw ESC byte in rendered text at prefix #{inspect(prefix)}"

          refute text =~ "```",
                 "fence marker leaked at prefix #{inspect(prefix)}: #{inspect(text)}"

          refute text =~ "*",
                 "'*' leaked at prefix #{inspect(prefix)}: #{inspect(text)}"

          refute text =~ "_",
                 "'_' leaked at prefix #{inspect(prefix)}: #{inspect(text)}"

          refute text =~ "`",
                 "'`' leaked at prefix #{inspect(prefix)}: #{inspect(text)}"
        end
      end
    end

    test "the sealed final content renders the styled document -- no raw ANSI bytes in the element tree" do
      {_chunks, final} = golden_deltas_and_final()

      block = message_block(final, seal: :sealed)
      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)
      leaves = flat_leaves(rendered)

      assert Enum.any?(texts, &(&1 =~ "Diagnostic Report"))

      assert Enum.any?(leaves, fn {content, style} ->
               content == "run" and style[:bold] == true
             end),
             "the **run** emphasis must render as a bold span"

      code_leaves =
        Enum.filter(leaves, fn {content, _style} -> content =~ "defmodule" end)

      assert code_leaves != [], "fenced code content must render"

      # Fenced code renders through the CodeBlock/SyntaxHighlighter lane:
      # token fg is a Makeup theme hex when highlighting is active, or
      # UNSET when the highlighter degrades — an attr-less cell inherits
      # the terminal's own default fg at the ColorResolver choke point.
      # Pin the lane, never a literal hue.
      assert Enum.all?(code_leaves, fn {_content, style} ->
               is_nil(style[:fg]) or
                 (is_binary(style[:fg]) and String.starts_with?(style[:fg], "#"))
             end),
             "fenced code must render theme tokens or inherit, not a literal hue"

      refute Enum.any?(texts, &(&1 =~ "\e"))
      refute Enum.any?(texts, &(&1 =~ "```"))
    end
  end
end
