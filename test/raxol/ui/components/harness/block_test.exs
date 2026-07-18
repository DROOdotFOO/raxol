defmodule Raxol.UI.Components.Harness.BlockTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Components.Harness.Block

  @frozen_fields [:content, :outcome, :event_refs, :kind, :raw_kind]

  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{type: :row, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(%{type: :column, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  # An approval block's render root is stamped :approval_prompt (U1-c
  # re-hosting) but keeps its column children -- walk them the same way.
  defp flat_texts(%{type: :approval_prompt, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_), do: []

  # Structural gap assert: flat_texts can't see the unset-gap footgun
  # (unset gap defaults to 1 in the layout engine), so walk the tree and
  # require every :column/:row container to carry an explicit gap of 0.
  defp assert_zero_gaps(%{type: type} = node) when type in [:column, :row] do
    assert Map.get(node, :gap) == 0,
           "#{type} container missing explicit gap: 0 -> #{inspect(node)}"

    node |> Map.get(:children, []) |> Enum.each(&assert_zero_gaps/1)
  end

  defp assert_zero_gaps(%{children: children}) when is_list(children) do
    Enum.each(children, &assert_zero_gaps/1)
  end

  defp assert_zero_gaps(_node), do: :ok

  defp assert_frozen_fields(before_block, after_block, label) do
    for field <- @frozen_fields do
      assert Map.fetch!(before_block, field) == Map.fetch!(after_block, field),
             "#{label} mutated frozen field #{field}"
    end
  end

  defp attach_recovered_handler do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:raxol, :harness, :block, :recovered],
      fn event, _measurements, metadata, _config ->
        send(parent, {ref, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp message_events(content, id \\ 1) do
    [
      %{
        id: id,
        type: :item_completed,
        payload: %{item_type: :message, content: content}
      }
    ]
  end

  describe "from_events/3 purity" do
    test "identical kind + events + opts always produce an identical block" do
      events = message_events("hello\nworld")

      assert Block.from_events(:message, events) ==
               Block.from_events(:message, events)
    end

    test "block is a pure function of its events (different content, different block)" do
      block_a = Block.from_events(:message, message_events("alpha"))
      block_b = Block.from_events(:message, message_events("beta"))

      refute block_a == block_b
    end

    test "event_refs reflects the source event ids" do
      events = [
        %{id: 1, type: :item_started, payload: %{item_type: :tool_use}},
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "Bash"}}
        }
      ]

      block = Block.from_events(:tool_call, events)
      assert block.event_refs == [1, 2]
    end
  end

  describe "from_events/3 kind normalization" do
    test "known kinds pass through unchanged" do
      for kind <- Block.known_kinds() do
        block = Block.from_events(kind, [])
        assert block.kind == kind
        assert block.raw_kind == kind
      end
    end

    test "an unknown kind normalizes to :opaque, keeping the original as raw_kind" do
      block =
        Block.from_events(:some_future_kind, message_events("payload text"))

      assert block.kind == :opaque
      assert block.raw_kind == :some_future_kind
    end

    test "a string kind (not even an atom) also normalizes to :opaque without raising" do
      block = Block.from_events("weird-string-kind", message_events("x"))
      assert block.kind == :opaque
      assert block.raw_kind == "weird-string-kind"
    end
  end

  describe "fold / unfold — pre-seal" do
    test "fold and unfold round-trip on a live block" do
      expanded_block =
        Block.from_events(:message, message_events("hi"), fold: :expanded)

      folded = Block.fold(expanded_block)
      assert folded.fold == :folded
      assert Block.unfold(folded) == expanded_block

      folded_block =
        Block.from_events(:message, message_events("hi"), fold: :folded)

      unfolded = Block.unfold(folded_block)
      assert unfolded.fold == :expanded
      assert Block.fold(unfolded) == folded_block
    end

    test "toggle_fold flips state pre-seal" do
      block = Block.from_events(:message, message_events("hi"), fold: :expanded)

      toggled_once = Block.toggle_fold(block)
      assert toggled_once.fold == :folded

      toggled_twice = Block.toggle_fold(toggled_once)
      assert toggled_twice == block
    end

    test "live?/1 and sealed?/1 reflect seal state" do
      block = Block.from_events(:message, message_events("hi"))
      assert Block.live?(block)
      refute Block.sealed?(block)

      sealed = Block.seal(block)
      refute Block.live?(sealed)
      assert Block.sealed?(sealed)
    end
  end

  describe "fold / unfold — post-seal, D-PA policy gated" do
    test "default policy (:deny) makes post-seal fold a no-op" do
      block =
        Block.from_events(:message, message_events("hi"), fold: :expanded)
        |> Block.seal()

      assert Block.fold(block) == block
      assert Block.unfold(block) == block
      assert Block.toggle_fold(block) == block
    end

    test "explicit fold_after_seal: :deny behaves the same as default" do
      block =
        Block.from_events(:message, message_events("hi"), fold: :expanded)
        |> Block.seal()

      assert Block.fold(block, fold_after_seal: :deny) == block
    end

    test "fold_after_seal: :allow lets fold state change post-seal" do
      block =
        Block.from_events(:message, message_events("hi"), fold: :expanded)
        |> Block.seal()

      folded = Block.fold(block, fold_after_seal: :allow)
      assert folded.fold == :folded
      assert Block.sealed?(folded)

      unfolded = Block.unfold(folded, fold_after_seal: :allow)
      assert unfolded.fold == :expanded
    end
  end

  describe "render/2 — unknown kind renders opaque, never raises" do
    test "opaque block renders without raising and shows the raw kind label" do
      block =
        Block.from_events(:totally_unknown, message_events("some content here"))

      rendered = Block.render(block)
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "totally_unknown"))
      assert Enum.any?(texts, &(&1 =~ "some content here"))
    end

    test "malformed/garbage events never raise, in construction or render" do
      garbage_events = [
        %{},
        %{
          id: 1,
          type: :item_completed,
          payload: %{content: %{nested: :garbage}}
        },
        :not_even_a_map,
        %{id: 2, payload: nil}
      ]

      block = Block.from_events(:message, garbage_events)
      assert %Block{} = block

      rendered = Block.render(block)
      assert %{type: :column} = rendered
    end

    test "a from_events call whose events aren't a list still can't crash the renderer" do
      # from_events/3 requires a list (typed contract); an unknown kind with
      # well-formed-but-minimal events must still render safely.
      block = Block.from_events(:mystery, [])
      assert Block.render(block).type == :column
    end
  end

  describe "render/2 — expanded vs folded shape" do
    test "expanded message block: header line + content lines" do
      block =
        Block.from_events(:message, message_events("first line\nsecond line"),
          fold: :expanded
        )

      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert length(texts) == 3
      [header, line1, line2] = texts
      assert header =~ "first line"
      assert line1 == "first line"
      assert line2 == "second line"
    end

    test "folded message block: one summary line only (no outcome present)" do
      block =
        Block.from_events(:message, message_events("first\nsecond"),
          fold: :folded
        )

      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert length(texts) == 1
      assert hd(texts) =~ "first"
    end
  end

  describe "speaker role (message blocks: extraction, role/1, folded glyph)" do
    defp role_message_events(role_value) do
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :message,
            content: "why is the build red?",
            role: role_value
          }
        }
      ]
    end

    test "extract_content(:message) populates :role from the payload" do
      block = Block.from_events(:message, role_message_events(:user))
      assert block.content.role == :user
      assert Block.role(block) == :user
    end

    test "a wire-string role normalizes: exactly \"user\" and nothing else" do
      assert Block.from_events(:message, role_message_events("user"))
             |> Block.role() == :user

      # Anything but an explicit user marker resolves :assistant -- the
      # echo is an authorship claim, and mislabeling machine output as
      # the user is the harmful direction (absence-semantics: restrictive
      # default). Hostile/garbled markers included.
      for other <- ["assistant", :assistant, "USER", "\e[2Juser", 42, nil, %{}] do
        assert Block.from_events(:message, role_message_events(other))
               |> Block.role() == :assistant,
               "role #{inspect(other)} must resolve :assistant"
      end
    end

    test "an absent role defaults to :assistant (contract-only-grows)" do
      block = Block.from_events(:message, message_events("hello"))
      assert block.content.role == :assistant
      assert Block.role(block) == :assistant
    end

    test "role/1 is :assistant for every non-message kind -- machinery has no speaker" do
      reasoning =
        Block.from_events(:reasoning, [
          %{
            id: 1,
            type: :item_completed,
            payload: %{item_type: :reasoning, content: "hm", role: :user}
          }
        ])

      assert Block.role(reasoning) == :assistant
    end

    test "folded USER header carries the echo glyph: `▸ ❯ first line…`" do
      block =
        Block.from_events(:message, role_message_events(:user), fold: :folded)

      rendered = Block.render(block, %{width: 80})
      [header] = flat_texts(rendered)

      assert String.starts_with?(header, "▸ ❯ "),
             "folded user header must open `▸ ❯ `, got #{inspect(header)}"

      assert header =~ "why is the build red?"
    end

    test "folded ASSISTANT header keeps `▸ » summary` unchanged" do
      block =
        Block.from_events(:message, message_events("all done"), fold: :folded)

      rendered = Block.render(block, %{width: 80})
      [header] = flat_texts(rendered)

      assert String.starts_with?(header, "▸ » ")
      assert header =~ "all done"
    end
  end

  describe "outcome row" do
    test "absent outcome data renders no outcome row" do
      block = Block.from_events(:message, message_events("no outcome here"))
      rendered = Block.render(block)

      refute Enum.any?(flat_texts(rendered), &(&1 =~ "exit"))
    end

    test "a failed tool_call's exit carries in the ✗ glyph, never an exit/duration/cost receipt" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_result, exit_code: 1}
        }
      ]

      block = Block.from_events(:tool_call, events)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      # Fix 1: the receipt suffix is dropped; a non-zero exit is carried by
      # the leading ✗ glyph, not an `exit N` text tail. Never a duration or
      # cost tail either.
      assert Enum.any?(texts, &(&1 =~ "✗"))
      refute Enum.any?(texts, &(&1 =~ "exit 1"))
      refute Enum.any?(texts, &(&1 =~ "$"))
      refute Enum.any?(texts, &(&1 =~ "ms"))
    end

    test "a successful tool_call's exit-0 outcome is the ⚙ glyph -- no exit/duration/cost receipt" do
      events = [
        %{id: 1, type: :item_started, ts: 1_000_000},
        %{
          id: 2,
          type: :item_completed,
          ts: 1_250_000,
          payload: %{item_type: :tool_result, exit_code: 0, cost: 0.02}
        }
      ]

      block = Block.from_events(:tool_call, events)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      # Fix 1: exit 0 reads as the plain ⚙ glyph; the byte-count, duration,
      # and cost receipt parts are all gone (the strip carries elapsed/cost).
      assert Enum.any?(texts, &(&1 =~ "⚙"))
      refute Enum.any?(texts, &(&1 =~ "exit"))
      refute Enum.any?(texts, &(&1 =~ "250ms"))
      refute Enum.any?(texts, &(&1 =~ "$0.02"))
    end

    test "duration_ms is derived from item_started/item_completed ts deltas (microseconds)" do
      events = [
        %{id: 1, type: :item_started, ts: 0},
        %{
          id: 2,
          type: :item_completed,
          ts: 2_000_000,
          payload: %{item_type: :tool_result}
        }
      ]

      block = Block.from_events(:tool_call, events)
      assert block.outcome.duration_ms == 2_000
    end
  end

  describe "tool_call content extraction" do
    test "gathers name/args from the call and output from the paired result" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_use,
            content: %{name: "Bash", args: %{command: "ls"}}
          }
        },
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_result, content: "file1\nfile2"}
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :expanded)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "Bash"))
      # Fix 1: args are unquoted `key: value`, never `(key: "value")`.
      assert Enum.any?(texts, &(&1 =~ "command: ls"))
      refute Enum.any?(texts, &(&1 =~ "command: \"ls\""))
      assert Enum.any?(texts, &(&1 == "file1"))
      assert Enum.any?(texts, &(&1 == "file2"))
    end
  end

  describe "compact machinery lines (the low-prominence execution register)" do
    defp styled_texts(%{type: :text} = node),
      do: [{Map.get(node, :content), Map.get(node, :style, %{})}]

    defp styled_texts(%{children: children}) when is_list(children),
      do: Enum.flat_map(children, &styled_texts/1)

    defp styled_texts(_node), do: []

    defp tool_events(name, args, result, extra_result \\ %{}) do
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: name, args: args}}
        },
        %{
          id: 2,
          type: :item_completed,
          payload:
            Map.merge(%{item_type: :tool_result, content: result}, extra_result)
        }
      ]
    end

    test "a FOLDED tool renders exactly ONE line: glyph + name + unquoted args, NO receipt, no result body" do
      block =
        Block.from_events(
          :tool_call,
          tool_events("list_dir", %{path: "."}, "a\nb\nc\nd"),
          fold: :folded,
          seal: :sealed
        )

      texts = flat_texts(Block.render(block, %{width: 120}))

      assert [line] = texts
      assert line =~ "⚙ list_dir"
      # Fix 1: unquoted `key: value`, no braces/quotes; NO `· ✓ N lines`
      # receipt suffix.
      assert line =~ "path: ."
      refute line =~ "path: \".\""
      refute line =~ "✓ 4 lines"
      refute line =~ "Tool Result"
      refute Enum.any?(texts, &(&1 == "a"))
    end

    test "the folded tool line is DIM (machinery register), never full-weight" do
      block =
        Block.from_events(:tool_call, tool_events("list_dir", %{}, "x"),
          fold: :folded,
          seal: :sealed
        )

      assert [{_content, style}] =
               styled_texts(Block.render(block, %{width: 120}))

      assert style[:dim] == true
    end

    test "the folded reasoning line is DIM (machinery register) and shows ⁖ + line count" do
      # A sealed reasoning block inherits the low-prominence cognition
      # register (V 2026-07-18): `⁖ thinking` flush left, the honest line
      # count flush right (space-between), dim, folded — never full-weight
      # speech.
      block =
        Block.from_events(
          :reasoning,
          message_events("weigh the options\nthen decide"),
          fold: :folded,
          seal: :sealed
        )

      assert [{content, style}] =
               styled_texts(Block.render(block, %{width: 120}))

      assert content =~ "⁖ thinking"
      assert content =~ "2 lines"
      assert style[:dim] == true
    end

    test "a tool with multi-line output renders the clean ⚙ line, no `N lines` receipt" do
      block =
        Block.from_events(:tool_call, tool_events("t", %{}, "one\ntwo\nthree"),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      # Fix 1: the shape-derived receipt is retired -- a tool with output is
      # a plain ⚙ line; the z-expanded body carries the actual output.
      assert line =~ "⚙ t"
      refute line =~ "3 lines"
      refute line =~ "✓"
    end

    test "single-line output renders no byte-count receipt either" do
      block =
        Block.from_events(:tool_call, tool_events("t", %{}, "hello"),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "⚙ t"
      refute line =~ "5 B"
      refute line =~ "✓"
    end

    test "a failed tool's exit carries in the ✗ glyph, no exit-code / short-error receipt" do
      events = [
        %{
          id: 1,
          type: :item_started,
          ts: 1_000_000,
          payload: %{item_type: :tool_use, content: %{name: "sh", args: %{}}}
        },
        %{
          id: 2,
          type: :item_completed,
          ts: 1_300_000,
          payload: %{item_type: :tool_use, content: %{name: "sh", args: %{}}}
        },
        %{
          id: 3,
          type: :item_completed,
          ts: 1_300_000,
          payload: %{item_type: :tool_result, content: "boom", exit_code: 2}
        }
      ]

      block =
        Block.from_events(:tool_call, events, fold: :folded, seal: :sealed)

      assert [line] = flat_texts(Block.render(block, %{width: 200}))
      # Fix 1: ✗ leads the line (failure state), and the verbose
      # `✗ exit N — <error>` receipt is gone.
      assert line =~ "✗ sh"
      refute line =~ "exit 2"
      refute line =~ "boom"
    end

    test "a FAILED tool keeps ALARM prominence (never dim -- a failure is signal, not machinery noise)" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "sh", args: %{}}}
        },
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_result, content: "err", exit_code: 1}
        }
      ]

      block =
        Block.from_events(:tool_call, events, fold: :folded, seal: :sealed)

      assert [{content, style}] =
               styled_texts(Block.render(block, %{width: 120}))

      assert content =~ "✗ sh"
      refute style[:dim] == true
    end

    test "a resultless tool in the footer live tail (pending?) stays a plain ⚙ line (the margin spinner carries 'running', not a receipt)" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "slow", args: %{}}}
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :folded)
      # Fix 1: the pending footer preview keeps ⚙ (the col-0 margin spinner
      # animates 'running'); no `running…` receipt text on the line.
      assert [line] =
               flat_texts(Block.render(block, %{width: 120, pending?: true}))

      assert line =~ "⚙ slow"
      refute line =~ "running…"
    end

    test "a resultless tool WITHOUT the pending flag (sealed history) renders the honest absence via the ⊘ glyph, never running… or a checkmark" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "gone", args: %{}}}
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :folded)
      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      # Fix 1: the honest absence is carried by the ⊘ glyph, not a
      # `⊘ no result` receipt text.
      assert line =~ "⊘ gone"
      refute line =~ "running…"
      refute line =~ "✓"
    end

    test "tainted tool output appends the FE0E-guarded untrusted marker" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :tool_use, content: %{name: "web", args: %{}}}
        },
        %{
          id: 2,
          type: :item_completed,
          provenance: %{trust: :tainted},
          payload: %{item_type: :tool_result, content: "x"}
        }
      ]

      block =
        Block.from_events(:tool_call, events, fold: :folded, seal: :sealed)

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "⚠︎ untrusted"
    end

    test "z (fold -> expanded) reveals the full result body under the same compact line" do
      block =
        Block.from_events(:tool_call, tool_events("cat", %{}, "line1\nline2"),
          fold: :expanded,
          seal: :sealed
        )

      texts = flat_texts(Block.render(block, %{width: 120}))
      assert Enum.any?(texts, &(&1 =~ "⚙ cat"))
      assert Enum.any?(texts, &(&1 == "line1"))
      assert Enum.any?(texts, &(&1 == "line2"))
    end

    test "reasoning collapses to one dim '⁖ thinking … N lines' line, peekable" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :reasoning, content: "first\nsecond\nthird"}
        }
      ]

      folded =
        Block.from_events(:reasoning, events, fold: :folded, seal: :sealed)

      assert [{line, style}] = styled_texts(Block.render(folded, %{width: 120}))
      assert line =~ "⁖ thinking"
      assert line =~ "3 lines"
      assert style[:dim] == true

      # Expanded: the thought is bracketed by the because/therefore arrows
      # (`∵` opens, `∴` closes) around the real body lines.
      expanded = %{folded | fold: :expanded}
      texts = flat_texts(Block.render(expanded, %{width: 120}))
      assert Enum.any?(texts, &(&1 == "first"))
      assert Enum.any?(texts, &(&1 == "third"))
      assert Enum.any?(texts, &(&1 == "∵"))
      assert Enum.any?(texts, &(&1 == "∴"))
    end

    test "a diff block folds to a compact '± path · +N -M' line" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_result,
            path: "lib/a.ex",
            old: "a\nb\nc",
            new: "a\nX\nc\nd"
          }
        }
      ]

      block = Block.from_events(:diff, events, fold: :folded, seal: :sealed)
      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line == "± lib/a.ex · +2 -1"
    end
  end

  describe ":error alarm block (fix 3: real message, no ◆/(empty), never dim)" do
    defp error_events(payload) do
      [%{id: 1, type: :error, payload: payload}]
    end

    test "an :error kind is first-class, not normalized to :opaque" do
      block = Block.from_events(:error, error_events(%{reason: "boom"}))
      assert block.kind == :error
      assert block.raw_kind == :error
    end

    test "renders the REAL error message (the `reason` payload), never '(empty)'" do
      block =
        Block.from_events(:error, error_events(%{reason: "connection refused"}),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "connection refused"
      refute line =~ "(empty)"
    end

    test "the alarm line leads with ✗, carries NO fold arrow and NO ◆ glyph" do
      block =
        Block.from_events(:error, error_events(%{reason: "kaboom"}),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "✗"
      refute line =~ "◆"
      refute line =~ "▾"
      refute line =~ "▸"
      refute line =~ "[error]"
    end

    test "an error keeps ALARM prominence -- never dim (a fault is signal)" do
      block =
        Block.from_events(:error, error_events(%{reason: "fault"}),
          fold: :folded,
          seal: :sealed
        )

      assert [{content, style}] =
               styled_texts(Block.render(block, %{width: 120}))

      assert content =~ "fault"
      refute style[:dim] == true
    end

    test "a non-binary reason (an atom/tuple) still renders honestly, not '(empty)'" do
      block =
        Block.from_events(:error, error_events(%{reason: {:http_error, 500}}),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "http_error"
      refute line =~ "(empty)"
    end

    test "a fault with NO message renders an honest specific line, never a bare '(empty)'" do
      block =
        Block.from_events(:error, error_events(%{where: "Backend.HTTP"}),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "Backend.HTTP"
      refute line =~ "(empty)"
    end

    test "a fault with neither message nor origin is still honest and specific" do
      block =
        Block.from_events(:error, error_events(%{}),
          fold: :folded,
          seal: :sealed
        )

      assert [line] = flat_texts(Block.render(block, %{width: 120}))
      assert line =~ "✗"
      assert line =~ "error"
      refute line =~ "(empty)"
    end

    test "z (expanded) reveals the full multi-line fault under the same alarm line" do
      block =
        Block.from_events(
          :error,
          error_events(%{reason: "line one\nline two\nline three"}),
          fold: :expanded,
          seal: :sealed
        )

      texts = flat_texts(Block.render(block, %{width: 120}))
      assert Enum.any?(texts, &(&1 =~ "✗ line one"))
      assert Enum.any?(texts, &(&1 == "line three"))
    end
  end

  describe "approval content extraction" do
    test "renders action as the summary and blast radius / options as body lines" do
      events = [
        %{
          id: 1,
          type: :approval_requested,
          payload: %{
            action: "rm -rf /tmp/scratch",
            blast_radius: "deletes 3 files",
            options: [:allow, :deny]
          }
        }
      ]

      block = Block.from_events(:approval, events, fold: :expanded)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "rm -rf /tmp/scratch"))
      assert Enum.any?(texts, &(&1 == "deletes 3 files"))
      assert Enum.any?(texts, &(&1 =~ "allow"))
    end

    test "a producer with no blast_radius extracts nil, not %{} -- absence must stay distinguishable from a declared-empty radius" do
      events = [
        %{
          id: 1,
          type: :approval_requested,
          payload: %{action: "rm -rf /", options: [:allow, :deny]}
        }
      ]

      block = Block.from_events(:approval, events, fold: :expanded)

      assert block.content.blast_radius == nil,
             "an undeclared blast radius must stay nil so " <>
               "BlastRadiusPreview can render its explicit unsafe-warning " <>
               "instead of silently defaulting to a false-safe %{}"
    end
  end

  describe "diff content extraction (T5 seam: path/old/new/language, not :text)" do
    test "gathers path/old/new/language into a structured content map" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            path: "lib/orders/total.ex",
            old: "def total(x), do: x\n",
            new: "def total(x), do: x * 2\n",
            language: "elixir"
          }
        }
      ]

      block = Block.from_events(:diff, events, fold: :expanded)

      assert block.content == %{
               path: "lib/orders/total.ex",
               old: "def total(x), do: x\n",
               new: "def total(x), do: x * 2\n",
               language: "elixir"
             }
    end

    test "the folded summary shows the path, not '(empty)'" do
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{path: "lib/orders/total.ex", old: "a\n", new: "b\n"}
        }
      ]

      block = Block.from_events(:diff, events, fold: :folded)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "lib/orders/total.ex"))
      refute Enum.any?(texts, &(&1 == "(empty)"))
    end

    test "a missing path falls back to a plain, non-crashing summary" do
      events = [
        %{id: 1, type: :item_completed, payload: %{old: "a\n", new: "b\n"}}
      ]

      block = Block.from_events(:diff, events, fold: :folded)
      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "(no path)"))
    end
  end

  describe "unicode content — width via TextMeasure, not String.length" do
    test "CJK header truncation obeys display width (double-width chars), not codepoint count" do
      # Each CJK char is 2 display columns; 10 chars = 20 columns, well over
      # a narrow budget once the "▾ » " prefix (4 cols) is subtracted.
      cjk = String.duplicate("日", 10)
      block = Block.from_events(:message, message_events(cjk), fold: :folded)

      rendered = Block.render(block, %{width: 10})
      [line] = flat_texts(rendered)

      assert Raxol.UI.TextMeasure.display_width(line) <= 10
      assert String.ends_with?(line, "…")
    end

    test "emoji content renders without crashing and preserves the grapheme" do
      block =
        Block.from_events(:message, message_events("status: ✅ done"),
          fold: :expanded
        )

      rendered = Block.render(block, %{width: 80})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "✅"))
    end

    test "unicode content lines never split a double-width grapheme in a way that raises" do
      mixed = String.duplicate("漢字mix", 5)

      block =
        Block.from_events(:reasoning, message_events(mixed), fold: :folded)

      rendered = Block.render(block, %{width: 6})
      assert %{type: :column} = rendered
    end
  end

  describe "block algebra invariants" do
    # I-SEAL-MONO
    test "seal is idempotent and changes ONLY the seal field" do
      block = Block.from_events(:message, message_events("hi"))
      sealed = Block.seal(block)

      assert Block.seal(sealed) == sealed
      assert sealed.seal == :sealed

      assert Map.delete(Map.from_struct(sealed), :seal) ==
               Map.delete(Map.from_struct(block), :seal)
    end

    # I-CONTENT
    test "content, outcome, event_refs, kind, raw_kind are frozen across every transition" do
      events = [
        %{id: 1, type: :item_started, ts: 0},
        %{
          id: 2,
          type: :item_completed,
          ts: 500_000,
          payload: %{
            item_type: :tool_use,
            content: %{name: "Bash", args: %{command: "ls"}},
            exit_code: 0,
            cost: 0.01
          }
        }
      ]

      transitions = [
        {"fold/1", &Block.fold/1},
        {"unfold/1", &Block.unfold/1},
        {"toggle_fold/1", &Block.toggle_fold/1},
        {"seal/1", &Block.seal/1},
        {"fold allow", &Block.fold(&1, fold_after_seal: :allow)},
        {"unfold allow", &Block.unfold(&1, fold_after_seal: :allow)},
        {"toggle allow", &Block.toggle_fold(&1, fold_after_seal: :allow)}
      ]

      live_block = Block.from_events(:tool_call, events)
      sealed_block = Block.seal(live_block)

      for block <- [live_block, sealed_block],
          {label, transition} <- transitions do
        assert_frozen_fields(block, transition.(block), label)
      end
    end

    test "the full default fold table covers every known kind plus :opaque" do
      # Machinery kinds (reasoning, tool_call, diff) default FOLDED --
      # their default form is the compact one-line register.
      expected = %{
        message: :expanded,
        reasoning: :folded,
        tool_call: :folded,
        diff: :folded,
        approval: :expanded,
        opaque: :expanded,
        error: :folded
      }

      kinds = [:opaque | Block.known_kinds()]
      assert Enum.sort(kinds) == expected |> Map.keys() |> Enum.sort()

      for kind <- kinds do
        assert Block.default_fold(kind) == Map.fetch!(expected, kind),
               "default_fold(#{kind}) diverged from the documented table"
      end
    end
  end

  describe "determinism of multi-arg tool_call summary" do
    test "args render in sorted key order regardless of map construction order" do
      args_one = %{command: "ls", cwd: "/tmp", background: false}
      args_two = Map.new(background: false, cwd: "/tmp", command: "ls")

      render_summary = fn args ->
        events = [
          %{
            id: 1,
            type: :item_completed,
            payload: %{
              item_type: :tool_use,
              content: %{name: "Bash", args: args}
            }
          }
        ]

        block = Block.from_events(:tool_call, events, fold: :folded)
        [header] = flat_texts(Block.render(block, %{width: 200}))
        header
      end

      header = render_summary.(args_one)
      # Fix 1: unquoted `key: value`, sorted, no braces/quotes.
      assert header =~ "background: false, command: ls, cwd: /tmp"
      refute header =~ "\""
      assert header == render_summary.(args_two)
    end

    property "random atom-keyed arg maps summarize to the sorted join, construction-order-free" do
      check all(
              pairs <-
                uniq_list_of(
                  {atom(:alphanumeric),
                   one_of([integer(), string(:alphanumeric), boolean()])},
                  uniq_fun: fn {k, _v} -> k end,
                  min_length: 1,
                  max_length: 8
                ),
              max_runs: 50
            ) do
        # Fix 1: binary values render UNQUOTED, other terms inspected;
        # sorted by key, joined with ", ", no surrounding braces.
        fmt = fn
          v when is_binary(v) -> v
          v -> inspect(v)
        end

        expected_args =
          pairs
          |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
          |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{fmt.(v)}" end)

        render_summary = fn args ->
          events = [
            %{
              id: 1,
              type: :item_completed,
              payload: %{
                item_type: :tool_use,
                content: %{name: "T", args: args}
              }
            }
          ]

          block = Block.from_events(:tool_call, events, fold: :folded)
          [header] = flat_texts(Block.render(block, %{width: 10_000}))
          header
        end

        header = render_summary.(Map.new(pairs))

        assert header =~ expected_args
        assert header == render_summary.(pairs |> Enum.shuffle() |> Map.new())
      end
    end
  end

  describe "container gap discipline" do
    test "every rendered container carries an explicit gap of 0 (expanded, full outcome)" do
      events = [
        %{id: 1, type: :item_started, ts: 0},
        %{
          id: 2,
          type: :item_completed,
          ts: 500_000,
          payload: %{
            item_type: :tool_use,
            content: %{name: "Bash", args: %{command: "ls"}},
            exit_code: 0,
            cost: 0.01
          }
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :expanded)
      assert_zero_gaps(Block.render(block, %{width: 80}))
    end

    test "folded and fallback renders also carry gap 0 on every container" do
      folded = Block.from_events(:message, message_events("hi"), fold: :folded)
      assert_zero_gaps(Block.render(folded, %{width: 80}))

      # args map with an unstringable key forces the render rescue path
      broken_events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_use,
            content: %{name: "X", args: %{%{} => 1}}
          }
        }
      ]

      broken = Block.from_events(:tool_call, broken_events)
      assert_zero_gaps(Block.render(broken, %{width: 80}))
    end
  end

  describe "recovery observability" do
    test "a valid :message event set stays :message — never silently :opaque" do
      ref = attach_recovered_handler()

      block = Block.from_events(:message, message_events("perfectly fine"))
      assert block.kind == :message

      refute_received {^ref, _event, _meta}
    end

    @tag capture_log: true
    test "a forced construction raise falls back to :opaque AND emits recovery telemetry" do
      ref = attach_recovered_handler()

      # Improper list: passes the is_list/1 guard, raises inside Enum traversal.
      broken_events = [%{id: 1, type: :item_completed} | :improper_tail]

      block = Block.from_events(:message, broken_events)
      assert block.kind == :opaque
      assert block.raw_kind == :message

      assert_received {^ref, [:raxol, :harness, :block, :recovered], meta}
      assert meta.kind == :message
      assert is_binary(meta.reason)
    end

    @tag capture_log: true
    test "a forced render raise emits recovery telemetry and returns the fallback view" do
      ref = attach_recovered_handler()

      # Unstringable args key: construction succeeds, render's summary raises.
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_use,
            content: %{name: "X", args: %{%{} => 1}}
          }
        }
      ]

      block = Block.from_events(:tool_call, events)
      refute_received {^ref, _event, _meta}

      rendered = Block.render(block, %{width: 80})
      assert %{type: :column} = rendered
      # The moduledoc promise: a render fault is never a dead cell. The
      # fallback shows the block's honest summary plus a visible recovery
      # marker (the real exception + stacktrace go to the log).
      assert Enum.any?(flat_texts(rendered), &(&1 =~ "render error:"))

      assert_received {^ref, [:raxol, :harness, :block, :recovered], meta}
      assert meta.kind == :tool_call
    end
  end

  describe "fold_allowed?/2" do
    test "always true while live" do
      block = Block.from_events(:message, message_events("hi"))
      assert Block.fold_allowed?(block)
      assert Block.fold_allowed?(block, fold_after_seal: :deny)
    end

    test "post-seal it encodes the same policy fold/2 applies" do
      block = Block.from_events(:message, message_events("hi")) |> Block.seal()

      refute Block.fold_allowed?(block)
      refute Block.fold_allowed?(block, fold_after_seal: :deny)
      assert Block.fold_allowed?(block, fold_after_seal: :allow)

      # check-then-apply agreement: allowed? iff fold/2 actually changes state
      refute Block.fold(block).fold == :folded
      assert Block.fold(block, fold_after_seal: :allow).fold == :folded
    end
  end

  describe "default_fold/1" do
    test "reasoning folds by default; message expands by default" do
      assert Block.default_fold(:reasoning) == :folded
      assert Block.default_fold(:message) == :expanded
    end

    test "an unknown kind falls back to opaque's default" do
      assert Block.default_fold(:something_new) == Block.default_fold(:opaque)
    end
  end
end
