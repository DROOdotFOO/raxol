defmodule Raxol.UI.Components.Harness.BlockSearchTextTest do
  @moduledoc """
  `Raxol.UI.Components.Harness.Block.search_text/1` -- the per-block
  search corpus the transcript search picker
  (`Raxol.Harness.Surface.open_search_picker/1`) filters over. Every
  doc guarantee `search_text/1` states maps to a named test here: the
  `"<kind> · <summary>"` prefix, the per-kind body extension, that the
  body carries content `summary/1` never shows (full text vs.
  first-line-only), that hostile content is preserved verbatim
  (sanitize lives in `Raxol.Harness.Surface.ViewText`, not here), and
  that any degenerate `content` shape degrades to the prefix alone
  instead of raising.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Block

  defp text_events(content, id \\ 1) do
    [
      %{
        id: id,
        type: :item_completed,
        payload: %{content: content}
      }
    ]
  end

  defp tool_call_events(name, args, result) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{item_type: :tool_use, content: %{name: name, args: args}}
      },
      %{
        id: 2,
        type: :item_completed,
        payload: %{item_type: :tool_result, content: result}
      }
    ]
  end

  defp approval_events(action, options) do
    [
      %{
        id: 1,
        type: :approval_requested,
        payload: %{action: action, options: options}
      }
    ]
  end

  defp diff_events(path, old, new) do
    [
      %{
        id: 1,
        type: :item_completed,
        payload: %{path: path, old: old, new: new}
      }
    ]
  end

  test "message block: search_text carries the kind, the summary line, and a body line summary omits" do
    block =
      Block.from_events(:message, text_events("first line\nsecond line unique"))

    text = Block.search_text(block)

    assert text =~ "message"
    assert text =~ "first line"
    assert text =~ "second line unique"

    refute Block.summary(block) =~ "second line unique",
           "precondition: summary/1 only ever shows line 1"
  end

  test "reasoning block: search_text carries the kind, the summary line, and a body line summary omits" do
    block =
      Block.from_events(
        :reasoning,
        text_events("reasoning line one\nreasoning line two")
      )

    text = Block.search_text(block)

    assert text =~ "reasoning"
    assert text =~ "reasoning line one"
    assert text =~ "reasoning line two"

    refute Block.summary(block) =~ "reasoning line two"
  end

  test "tool_call block: search_text carries the name, the args rendering, and the full result text" do
    block =
      Block.from_events(
        :tool_call,
        tool_call_events("Bash", %{command: "ls -la"}, "file1\nfile2\nfile3")
      )

    text = Block.search_text(block)

    assert text =~ "tool_call"
    assert text =~ "Bash"
    assert text =~ "command: \"ls -la\""
    assert text =~ "file1"
    assert text =~ "file2"
    assert text =~ "file3"
  end

  test "approval block: search_text carries the full multi-line action and option strings" do
    action = "rm -rf /tmp/scratch\nthis will delete data permanently"

    block =
      Block.from_events(
        :approval,
        approval_events(action, ["allow", "deny with reason"])
      )

    text = Block.search_text(block)

    assert text =~ "approval"
    assert text =~ "rm -rf /tmp/scratch"
    assert text =~ "this will delete data permanently"
    assert text =~ "allow"
    assert text =~ "deny with reason"

    refute Block.summary(block) =~ "this will delete data permanently",
           "precondition: summary/1 only ever shows action's line 1"
  end

  test "approval block: non-binary options are skipped, never raise, while binary siblings still surface" do
    block =
      Block.from_events(
        :approval,
        approval_events("rm -rf /", [:allow, "deny with reason", %{weird: true}])
      )

    text = Block.search_text(block)

    assert text =~ "deny with reason"
    refute text =~ "allow", "an atom option must be skipped, not stringified"
    refute text =~ "weird"
  end

  test "diff block: search_text carries the path (via summary), the old text, and the new text" do
    block =
      Block.from_events(
        :diff,
        diff_events(
          "lib/orders/total.ex",
          "def total(x), do: x\n",
          "def total(x), do: x * 2\n"
        )
      )

    text = Block.search_text(block)

    assert text =~ "diff"
    assert text =~ "lib/orders/total.ex"
    assert text =~ "def total(x), do: x"
    assert text =~ "x * 2"
  end

  test "opaque block: search_text carries the raw_kind label and the full text" do
    block =
      Block.from_events(
        :mystery_kind,
        text_events("payload line one\npayload line two")
      )

    text = Block.search_text(block)

    assert block.kind == :opaque
    assert text =~ "opaque"
    assert text =~ "mystery_kind"
    assert text =~ "payload line one"
    assert text =~ "payload line two"
  end

  test "hostile content: search_text preserves escape and control bytes verbatim, and never raises" do
    hostile = "line one\e[31mred\e[0m line two\x01trailer"
    block = Block.from_events(:message, text_events(hostile))

    text = Block.search_text(block)

    assert text =~ "\e[31mred\e[0m"
    assert text =~ <<0x01>>
  end

  test "degenerate content: an empty content map or nil-valued fields degrade to the kind · summary prefix, never raise" do
    empty_block = %Block{
      kind: :message,
      raw_kind: :message,
      event_refs: [],
      fold: :expanded,
      seal: :live,
      outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
      content: %{}
    }

    nil_block = %{empty_block | content: %{text: nil}}

    assert Block.search_text(empty_block) == "message · (empty)"
    assert Block.search_text(nil_block) == "message · (empty)"
  end

  describe "search_text/2 -- bounded work on the input path (PR #628 HIGH)" do
    # Regression guard for the adversarial-review HIGH: the cap must bound
    # the WORK, not just the label output. The observable proxy for
    # "bounded work" is that the RETURNED corpus is <= the cap regardless
    # of how large the untrusted body is -- the earlier revision clamped
    # only downstream, so `search_text/2` (source clamp) is what these
    # pin. `search_text/1` must stay the FULL, unbounded corpus.

    test "message body: /2 clamps the corpus to the cap; /1 stays unbounded" do
      body = String.duplicate("x", 100_000)
      block = Block.from_events(:message, text_events("head\n" <> body))

      assert String.length(Block.search_text(block, 400)) <= 400
      # /1 (== :infinity) still carries the whole body -- semantics intact.
      assert String.length(Block.search_text(block)) > 100_000
      assert Block.search_text(block, :infinity) == Block.search_text(block)
    end

    test "single giant line (no newlines): prefix clamp keeps /2 at the cap" do
      # `summary/1` returns line 1, and here line 1 IS the whole body -- so
      # an unclamped prefix would re-introduce an O(body) concat. The
      # corpus must still land under the cap.
      block =
        Block.from_events(:message, text_events(String.duplicate("z", 50_000)))

      assert String.length(Block.search_text(block, 400)) <= 400
    end

    test "a token before the cap is in the corpus; a token past it is not" do
      # 200 graphemes of filler, MARK_NEAR, filler out past 400, MARK_FAR.
      body =
        "head\n" <>
          String.duplicate("a", 200) <>
          "MARK_NEAR" <>
          String.duplicate("b", 400) <>
          "MARK_FAR"

      block = Block.from_events(:message, text_events(body))
      corpus = Block.search_text(block, 400)

      assert corpus =~ "MARK_NEAR"
      refute corpus =~ "MARK_FAR", "content past the cap must not be searchable"
    end

    test "diff body: BOTH old and new are source-clamped, corpus <= cap" do
      block =
        Block.from_events(
          :diff,
          diff_events(
            "lib/x.ex",
            String.duplicate("o", 100_000),
            String.duplicate("n", 100_000)
          )
        )

      assert String.length(Block.search_text(block, 400)) <= 400
    end

    test "approval body: action and option strings are source-clamped, corpus <= cap" do
      block =
        Block.from_events(
          :approval,
          approval_events(
            String.duplicate("A", 100_000),
            [String.duplicate("o", 100_000), String.duplicate("p", 100_000)]
          )
        )

      assert String.length(Block.search_text(block, 400)) <= 400
    end

    test "tool_call result: source-clamped, corpus <= cap" do
      block =
        Block.from_events(
          :tool_call,
          tool_call_events(
            "Bash",
            %{command: "x"},
            String.duplicate("r", 100_000)
          )
        )

      assert String.length(Block.search_text(block, 400)) <= 400
    end

    test "a body shorter than the cap is returned intact (clamp never over-trims)" do
      block = Block.from_events(:message, text_events("short body token_ok"))

      corpus = Block.search_text(block, 400)
      assert corpus =~ "token_ok"
      assert corpus == Block.search_text(block)
    end
  end
end
