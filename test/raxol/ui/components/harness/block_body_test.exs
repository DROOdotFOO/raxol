defmodule Raxol.UI.Components.Harness.BlockBodyTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.{Block, BlockBody}

  defp default_context,
    do: %{theme: Raxol.UI.Theming.Theme.default_theme(), width: 80}

  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_node), do: []

  # -- one realistic events list per kind, reused for both fold states
  # (folded/expanded is a Block construction option, not a different
  # events shape -- methodology R9: real producer, not a synthetic map) --

  defp events(:message) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{item_type: :message, content: "Deploy is done."}
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

  # The one substring that ONLY appears in the real merged component's
  # expanded render, never in Block's own folded header+outcome summary
  # -- proves "unfolding renders the full body" isn't tautological.
  #
  # `message`/`reasoning` content here is a single short line, so Block's
  # OWN folded summary (`first_line/1`, always computed regardless of
  # fold) already shows that whole line verbatim -- the genuinely
  # expanded-ONLY thing is what the rich component adds on top: the role
  # prefix (`MessageBlock`) and the "N line(s)" affordance
  # (`ReasoningBlock`), neither of which Block's plain summary ever emits.
  @expanded_only_marker %{
    message: "[assistant]",
    reasoning: "1 line",
    tool_call: "⚠ untrusted",
    diff: "Proposed change",
    approval: "IRREVERSIBLE"
  }

  # The substring present in BOTH fold states -- "content parity where
  # expected" (T4's folded summary already surfaces a name/path/action/
  # first-line preview; the expanded component surfaces the same
  # identifier again).
  @parity_marker %{
    message: "Deploy is done.",
    reasoning: "rollback plan",
    tool_call: "Bash",
    diff: "lib/orders/total.ex",
    approval: "rm -rf build/"
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
    for kind <- [:message, :reasoning, :tool_call, :diff, :approval] do
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

      folded_texts = flat_texts(BlockBody.render(block, default_context()))
      refute Enum.any?(folded_texts, &(&1 == "⚠ untrusted"))

      expanded = Block.toggle_fold(block)
      expanded_texts = flat_texts(BlockBody.render(expanded, default_context()))
      assert Enum.any?(expanded_texts, &(&1 == "⚠ untrusted"))

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
  end

  # -- RED-1: a component that RAISES during expanded mount must recover
  # exactly like a mount `{:error, reason}` -- never escape BlockBody.render/2
  # (see the moduledoc's total-safety claim, block_body.ex:20-23). Two
  # independently reachable vectors, per the T5 Opus review:
  describe "expanded mount raise recovers to the same fallback as a mount error" do
    test "a real :approval producer with no blast_radius renders the real component (Y1 default)" do
      # Real producer shape: `approval_requested` with no `blast_radius` key
      # at all -- Block.extract_approval_content now defaults the missing
      # field to `%{}` (Y1), so BlastRadiusPreview mounts and renders its
      # own "no tracked effects" message instead of ever reaching a raise.
      events = [
        %{
          id: 1,
          type: :approval_requested,
          payload: %{action: "rm -rf /"}
        }
      ]

      block = Block.from_events(:approval, events, fold: :expanded)
      rendered = BlockBody.render(block, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "rm -rf /")),
             "expected the real ApprovalPrompt to mount and show the action"

      assert Enum.any?(texts, &(&1 =~ "No tracked effects.")),
             "expected the Y1 blast_radius default (%{}) to render " <>
               "BlastRadiusPreview's own empty-state message, not a raise"
    end

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
end
