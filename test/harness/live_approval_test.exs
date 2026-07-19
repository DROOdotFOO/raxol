defmodule Raxol.Harness.LiveApprovalTest do
  @moduledoc """
  Track D -- live approvals. ACP's `session/request_permission` becomes a
  LIVE approval block in the harness, answered from the keyboard, and the
  answer seals the block with a receipt.

  This suite is the harness-UI half's red-first net (the split unit:
  block / projection / surface / keymap). It proves the producer path the
  frontier's pending-input gate was reserved for is now REAL:

    * the projection folds `approval_requested` into a LIVE approval block,
      and folds a correlated `approval_decided` answer into the SAME block,
      sealing it with the decision receipt (deny is as first-class as
      allow; a turn that ends unanswered renders "canceled before answer");
    * a live approval holds the seal frontier (G3): nothing seals at or
      past it until it is answered;
    * `status.needs_input` reads the REFERENT (a live approval block on
      screen), not the retired last-event-type proxy;
    * the answer keys (`y`/`n`/digits) resolve to an answer ONLY against a
      live question and only when the composer is not focused -- they never
      steal a letter from typed text;
    * the surface resolves an answer HINT into a concrete `option_id` and
      routes it through `command_sink`, refusing honestly when it cannot.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Projection
  alias Raxol.Harness.Surface
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.Harness.Keymap
  alias Raxol.Core.Events.Event

  # -- event builders (fixture wire shape: string-atom top-level fields,
  # payloads read by both Block's path extraction and the projection) --

  defp turn_started(id \\ 1),
    do: %{
      id: id,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{prompt: "go"}
    }

  defp message(id, item_id, text) do
    [
      %{
        id: id,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{item_id: item_id, item_type: "message"}
      },
      %{
        id: id + 1,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{item_id: item_id, item_type: "message", content: text}
      }
    ]
  end

  @options [
    %{option_id: "allow-once", name: "Allow once", kind: :allow_once},
    %{option_id: "allow-always", name: "Allow always", kind: :allow_always},
    %{option_id: "reject", name: "Reject", kind: :reject_once}
  ]

  defp approval_requested(id \\ 10, request_id \\ "req-1") do
    %{
      id: id,
      family: :loop,
      type: :approval_requested,
      tier: :durable,
      payload: %{
        request_id: request_id,
        action: "Run a shell command",
        tool_name: "bash",
        args: "rm -rf /tmp/scratch",
        options: @options,
        blast_radius: %{}
      }
    }
  end

  defp approval_decided(id, request_id, decision, option_id, opts \\ []) do
    %{
      id: id,
      family: :loop,
      type: :approval_decided,
      tier: :durable,
      payload: %{
        request_id: request_id,
        decision: decision,
        option_id: option_id,
        scope: Keyword.get(opts, :scope, :once),
        decided_by: Keyword.get(opts, :decided_by, "operator"),
        decided_at: Keyword.get(opts, :decided_at, 1_234)
      }
    }
  end

  defp only_approval_block(events) do
    blocks = Projection.project(events).blocks
    assert [%Block{kind: :approval} = block] = blocks
    block
  end

  # An edit/write approval whose payload carries the PROPOSED DIFF (the
  # before/after image the executor computed at approval time).
  defp diff_approval_requested(request_id, path, old, new) do
    %{
      id: 10,
      family: :loop,
      type: :approval_requested,
      tier: :durable,
      payload: %{
        request_id: request_id,
        tool_name: "edit_file",
        action: "edit_file",
        args: %{"path" => path},
        diff: true,
        path: path,
        old: old,
        new: new,
        language: "elixir",
        options: [
          %{option_id: "allow", name: "Allow", kind: :allow_once},
          %{option_id: "deny", name: "Deny", kind: :reject_once}
        ]
      }
    }
  end

  # -- 1. the projection producer: live vs sealed vs canceled ---------------

  describe "the projection folds approval_requested into a LIVE approval block" do
    test "an unanswered request is a single LIVE approval block carrying the referent" do
      block = only_approval_block([turn_started(), approval_requested()])

      assert Block.live?(block)
      assert block.content.request_id == "req-1"
      assert block.content.tool_name == "bash"
      assert block.content.args == "rm -rf /tmp/scratch"
      assert block.content.options == @options
      # No decision on a live question -- every receipt field stays nil.
      assert block.content.decision == nil
      assert block.content.decided_by == nil
    end

    test "a request with no decision and no turn end stays live across a following block" do
      # The proxy-divergence shape: an event ARRIVES after the unanswered
      # approval. The approval is still live and still the referent.
      events =
        [turn_started(), approval_requested()] ++ message(20, "i9", "later")

      blocks = Projection.project(events).blocks
      approval = Enum.find(blocks, &(&1.kind == :approval))
      assert Block.live?(approval)
    end
  end

  describe "a correlated approval_decided folds into the SAME block and seals it" do
    test "allow: one sealed block, decision + who + option recorded" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :allow, "allow-once")
      ]

      block = only_approval_block(events)

      assert Block.sealed?(block)
      assert block.content.decision == :allow
      assert block.content.option_id == "allow-once"
      assert block.content.decided_by == "operator"
    end

    test "deny is as first-class as allow" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :deny, "reject")
      ]

      block = only_approval_block(events)
      assert Block.sealed?(block)
      assert block.content.decision == :deny
    end

    test "the gate's :approved/:denied vocabulary folds to allow/deny too" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :approved, "allow-once")
      ]

      block = only_approval_block(events)
      assert Block.sealed?(block)
      # The render reconciles :approved -> allow; the raw payload is kept.
      lines = render_lines(block)
      assert Enum.any?(lines, &String.contains?(&1, "allowed"))
    end
  end

  describe "cancel-while-asking resolves honestly (never a wedged live block)" do
    test "a turn that completes with the question unanswered seals as canceled" do
      events = [
        turn_started(),
        approval_requested(),
        %{
          id: 11,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{final: true}
        }
      ]

      block = only_approval_block(events)
      assert Block.sealed?(block)
      assert block.content.decision == nil

      assert render_lines(block) |> Enum.any?(&(&1 =~ "canceled before answer"))
    end

    test "an explicit :cancel decision also seals as canceled" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :cancel, nil)
      ]

      block = only_approval_block(events)
      assert Block.sealed?(block)
      assert render_lines(block) |> Enum.any?(&(&1 =~ "canceled before answer"))
    end
  end

  describe "an orphan decision (no matching request) is a diagnostic, never a block" do
    test "a decision with no request in the turn produces no block and a recovered diagnostic" do
      events = [
        turn_started(),
        approval_decided(11, "no-such-req", :allow, "allow-once")
      ]

      projection = Projection.project(events)
      assert projection.blocks == []

      assert Enum.any?(
               projection.diagnostics,
               &(&1.reason == :orphan_approval_decision)
             )
    end
  end

  # -- 2. Block render: referent, live prompt, sealed receipt ---------------

  defp render_lines(block) do
    %{children: children} = Block.render(block, %{width: 80})

    children
    |> Enum.flat_map(&collect_text/1)
  end

  defp collect_text(%{type: :text, content: content}), do: [content]

  defp collect_text(%{children: children}),
    do: Enum.flat_map(children, &collect_text/1)

  defp collect_text(_node), do: []

  # The Pierre diff engine emits one FLAT `:row` per physical diff line
  # (gutter bar span + line-number span + syntax-split content spans +
  # trailing wash pad). These helpers read that structure the way
  # `diff_viewer_test.exs` reads `render/2`'s own rows -- by the `▌` gutter
  # bar and the per-span bg wash -- so the approval's diff is asserted as
  # the SAME engine's output, not a hand-rolled ± format.
  defp diff_rows(block) do
    %{children: children} = Block.render(block, %{width: 80})
    Enum.filter(children, &match?(%{type: :row}, &1))
  end

  defp row_text(%{children: spans}),
    do: Enum.map_join(spans, "", &Map.get(&1, :content, ""))

  defp changed_row?(%{children: spans}),
    do: Enum.any?(spans, &(Map.get(&1, :content) == "▌"))

  defp row_bg?(%{children: spans}),
    do: Enum.any?(spans, &is_binary(Map.get(Map.get(&1, :style, %{}), :bg)))

  describe "the live approval renders the referent and the answer keys" do
    test "the body shows the actual tool + args and numbered options with y/n aliases" do
      block = only_approval_block([turn_started(), approval_requested()])
      lines = render_lines(block)

      assert Enum.any?(lines, &(&1 =~ "tool: bash"))
      assert Enum.any?(lines, &(&1 =~ "args: rm -rf /tmp/scratch"))
      assert Enum.any?(lines, &(&1 =~ "[1] Allow once"))
      assert Enum.any?(lines, &(&1 =~ "[3] Reject"))
      assert Enum.any?(lines, &(&1 =~ "answer: y Allow once"))
    end
  end

  describe "the sealed approval renders the decision receipt" do
    test "allow receipt names the actor and scope" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :allow, "allow-once", scope: :once)
      ]

      lines = only_approval_block(events) |> render_lines()
      assert Enum.any?(lines, &(&1 =~ "✓ allowed" and &1 =~ "operator"))
    end

    test "deny receipt is first-class" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :deny, "reject")
      ]

      lines = only_approval_block(events) |> render_lines()
      assert Enum.any?(lines, &(&1 =~ "✗ denied"))
    end
  end

  # -- 3. Surface: G3 frontier hold + proxy retirement ----------------------

  defp real_model(events) do
    {:ok, device} = StringIO.open("")

    Surface.new(events,
      device: device,
      width: 80,
      rows: 24,
      footer_rows: 6,
      mode: :inline_log,
      capabilities: nil
    )
  end

  defp advance_all(model) do
    Enum.reduce(1..(length(model.events) * 2 + 10), model, fn _i, m ->
      {m, _} = Surface.advance(m)
      m
    end)
  end

  describe "G3: a live approval holds the seal frontier" do
    test "nothing seals at or past the live approval block" do
      # message (sealable) then the live approval -- the approval and
      # everything after it must be stranded behind the frontier.
      events =
        [turn_started()] ++
          message(2, "i1", "before") ++ [approval_requested(20, "req-1")]

      model = events |> real_model() |> advance_all()

      blocks = model.projection.blocks
      approval_index = Enum.find_index(blocks, &(&1.kind == :approval))
      assert approval_index != nil
      assert Block.live?(Enum.at(blocks, approval_index))

      scan = Surface.frontier_scan(model)

      assert scan.tail_start == approval_index,
             "the frontier must land exactly at the live approval block"

      # The approval block is never painted into print-once history.
      assert model.painted_count <= approval_index,
             "a live approval must never seal past the frontier (G3)"
    end

    test "answering the approval releases the frontier and seals the block" do
      base =
        [turn_started()] ++
          message(2, "i1", "before") ++ [approval_requested(20, "req-1")]

      live = base |> real_model() |> advance_all()
      assert Block.live?(Surface.live_approval_block(live))

      # Fold the answer in as a new stream event -- the seal is
      # event-observed, exactly as the live lane will drive it.
      answered =
        live
        |> Surface.append_events([
          approval_decided(30, "req-1", :allow, "allow-once")
        ])
        |> advance_all()

      approval =
        Enum.find(answered.projection.blocks, &(&1.kind == :approval))

      assert Block.sealed?(approval)
      assert Surface.live_approval_block(answered) == nil
    end
  end

  describe "the needs_input status reads the referent, not the retired proxy" do
    test "needs_input stays true while a live approval sits behind a later event" do
      # The exact divergence the old `last_loop == :approval_requested`
      # proxy got wrong: a message arrives AFTER the unanswered approval,
      # so the last event is no longer the request -- yet the question is
      # still live and still holding the frontier.
      events =
        [turn_started(), approval_requested(10, "req-1")] ++
          message(20, "i9", "later")

      model = events |> real_model() |> advance_all()

      assert model.status.needs_input == true,
             "needs_input must track the live approval block, not the last event"
    end

    test "needs_input clears once the approval is answered" do
      events = [
        turn_started(),
        approval_requested(10, "req-1"),
        approval_decided(11, "req-1", :allow, "allow-once")
      ]

      model = events |> real_model() |> advance_all()
      assert model.status.needs_input == false
    end
  end

  # -- 4. Surface: answering through command_sink ---------------------------

  defp sink_model(events) do
    test_pid = self()
    {:ok, device} = StringIO.open("")

    model =
      Surface.new(events,
        device: device,
        width: 80,
        rows: 24,
        footer_rows: 6,
        mode: :inline_log,
        capabilities: nil,
        command_sink: fn cmd -> send(test_pid, {:sink, cmd}) end
      )

    advance_all(model)
  end

  defp answer(model, char) do
    Surface.handle_input(model, Event.key(char))
  end

  describe "answering routes a concrete option_id through command_sink" do
    test "y resolves to the first allow option and sends the referent triple" do
      model =
        [turn_started(), approval_requested(10, "req-1")]
        |> sink_model()
        |> Surface.focus_transcript()

      _ = answer(model, "y")

      assert_receive {:sink,
                      %{
                        type: :approval_answer,
                        payload: %{
                          request_id: "req-1",
                          option_id: "allow-once",
                          decision: :allow
                        }
                      }}
    end

    test "n resolves to the first reject option (deny)" do
      model =
        [turn_started(), approval_requested(10, "req-1")]
        |> sink_model()
        |> Surface.focus_transcript()

      _ = answer(model, "n")

      assert_receive {:sink,
                      %{
                        type: :approval_answer,
                        payload: %{option_id: "reject", decision: :deny}
                      }}
    end

    test "a digit selects the Nth option by position" do
      model =
        [turn_started(), approval_requested(10, "req-1")]
        |> sink_model()
        |> Surface.focus_transcript()

      _ = answer(model, "2")

      assert_receive {:sink,
                      %{
                        type: :approval_answer,
                        payload: %{option_id: "allow-always"}
                      }}
    end

    test "an answer with no live approval never reaches the sink" do
      model =
        ([turn_started()] ++ message(2, "i1", "hi"))
        |> sink_model()
        |> Surface.focus_transcript()

      _ = answer(model, "y")
      refute_receive {:sink, _}, 50
    end
  end

  # -- 4b. the empty-draft reachability fix (the field focus trap) ----------

  describe "the answer keys are reachable with the composer focused when the draft is empty" do
    test "y answers a live approval even with the composer focused, as long as the draft is empty" do
      # No focus_transcript: after a submit the composer keeps focus, which
      # is exactly the state V hit -- pressing y typed \"y\" into the draft
      # instead of answering. An EMPTY draft now routes y to the answer.
      model = sink_model([turn_started(), approval_requested(10, "req-1")])

      _ = answer(model, "y")

      assert_receive {:sink,
                      %{
                        type: :approval_answer,
                        payload: %{option_id: "allow-once"}
                      }}
    end

    test "once there is a draft, y is typed into it -- never a phantom answer" do
      model = sink_model([turn_started(), approval_requested(10, "req-1")])

      # "h"/"e" are not answer keys -> they build the draft; by the time "y"
      # arrives the draft is non-empty, so y is text too.
      typed = model |> answer("h") |> answer("e") |> answer("y")

      assert Composer.value(typed.composer) == "hey"
      refute_receive {:sink, _}, 50
    end
  end

  # -- 4c. the answer affordance hint (gap 1a) ------------------------------

  describe "the live approval block shows how to answer it" do
    test "the affordance hint names the real allow/deny options and the digit range" do
      lines =
        only_approval_block([turn_started(), approval_requested()])
        |> render_lines()

      hint = Enum.find(lines, &(&1 =~ "answer:"))
      assert hint, "a live approval must render an answer-affordance line"
      assert hint =~ "y Allow once"
      assert hint =~ "n Reject"
      assert hint =~ "1-3 to choose"
    end

    test "a sealed approval renders NO affordance hint -- the question is answered" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :allow, "allow-once")
      ]

      lines = only_approval_block(events) |> render_lines()
      refute Enum.any?(lines, &(&1 =~ "answer:"))
    end
  end

  # -- 2b. the approval render root is a re-hosted Component node (U1-c) ----
  #
  # The TEA migration re-hosts the approval block: `Block.render/2`'s
  # `:approval` root carries `type: :approval_prompt` + `id` + `attrs`
  # (the TreeWalker requirements), so the real pipeline can derive the
  # answer tools from the LIVE block and route events at it. The node
  # keeps its column shape (`gap`/`children` unchanged, laid out via the
  # engine's type-alias rewrite), so every children-reading consumer --
  # ViewText flattening, the Pierre `:row` filter above -- sees the exact
  # tree it always saw.

  describe "the approval render root is stamped for the component tree" do
    test "a live approval's root carries type/id/attrs from the referent" do
      block = only_approval_block([turn_started(), approval_requested()])
      root = Block.render(block, %{width: 80})

      assert root.type == :approval_prompt
      assert root.id == "approval-req-1"
      assert root.attrs.seal == :live
      assert root.attrs.answer_mode == :direct
      assert root.attrs.request_id == "req-1"
      assert root.attrs.options == @options
      # the column shape survives: direct children, explicit gap
      assert is_list(root.children)
      assert root.gap == 0
    end

    test "a sealed approval keeps the id and reports seal: :sealed" do
      events = [
        turn_started(),
        approval_requested(),
        approval_decided(11, "req-1", :allow, "allow-once")
      ]

      root = only_approval_block(events) |> Block.render(%{width: 80})

      assert root.type == :approval_prompt
      assert root.id == "approval-req-1"
      assert root.attrs.seal == :sealed
    end

    test "a non-approval block's root stays a plain column" do
      events = [turn_started()] ++ message(20, "i1", "hello")
      blocks = Projection.project(events).blocks
      block = Enum.find(blocks, &(&1.kind == :message))

      root = Block.render(block, %{width: 80})
      assert root.type == :column
      refute Map.has_key?(root, :attrs)
    end
  end

  # -- 2c. needs-input prominence: the live question resists demotion -------
  #
  # A LIVE approval auto-engages the needs-input starvation floor
  # (`block.ex` `needs_input?/2`), so a demotion sweep cannot fade the
  # pending question as far as it fades answered history. Falsifier: under
  # the SAME sub-1.0 prominence, the live referent's colour must differ
  # from the sealed one's (the floor holds it brighter).

  describe "a live approval holds the needs-input prominence floor" do
    defp tool_line_fg(block) do
      block
      |> Block.render(%{width: 60, prominence: 0.3})
      |> collect_fg()
      |> Enum.find_value(fn {content, fg} ->
        if String.contains?(content, "tool: bash"), do: fg
      end)
    end

    defp collect_fg(%{type: :text, content: content, style: style}),
      do: [{content, Map.get(style, :fg)}]

    defp collect_fg(%{children: children}) when is_list(children),
      do: Enum.flat_map(children, &collect_fg/1)

    defp collect_fg(_node), do: []

    test "the live referent stays brighter than the sealed one under demotion" do
      live = only_approval_block([turn_started(), approval_requested()])

      sealed =
        only_approval_block([
          turn_started(),
          approval_requested(),
          approval_decided(11, "req-1", :allow, "allow-once")
        ])

      live_fg = tool_line_fg(live)
      sealed_fg = tool_line_fg(sealed)

      assert is_binary(live_fg)
      assert is_binary(sealed_fg)

      refute live_fg == sealed_fg,
             "the needs-input floor must keep the live question brighter than sealed history"
    end
  end

  # -- 4d. arg ordering: the path (referent) leads (gap 3) ------------------

  describe "the tool_call header leads with the path argument" do
    test "an edit_file header shows path before new_string, though new_string sorts earlier" do
      block =
        Block.from_events(
          :tool_call,
          [
            %{
              id: 1,
              type: :item_completed,
              payload: %{
                item_type: :tool_use,
                name: "edit_file",
                args: %{
                  "path" => "/lib/foo.ex",
                  "old_string" => "a",
                  "new_string" => "bbbbbbbb"
                }
              }
            }
          ],
          seal: :sealed
        )

      summary = Block.summary(block)
      {path_at, _} = :binary.match(summary, "path")
      {new_at, _} = :binary.match(summary, "new_string")

      assert path_at < new_at,
             "the path (the referent) must lead the arg header, not new_string"
    end
  end

  # -- 4e. the proposed diff (gap 2.2): the operator sees what y will do ----

  describe "an edit/write approval renders the PROPOSED DIFF, not truncated args" do
    test "the block renders the proposed change through the Pierre engine, identity at the bottom" do
      block =
        only_approval_block([
          turn_started(),
          diff_approval_requested(
            "req-e",
            "/lib/x.ex",
            "old line\ncommon",
            "new line\ncommon"
          )
        ])

      lines = render_lines(block)

      assert Enum.any?(lines, &(&1 == "± edit /lib/x.ex")),
             "the `± <verb> <path>` identity line names what y will do"

      # NOT the compact one-line register, NOT the raw args -- byte-sweep:
      # no truncated `new_string:`/`args:` arg reaches a diff-approval render.
      refute Enum.any?(lines, &(&1 =~ "args:")),
             "a diff approval shows the diff, never a truncated args line"

      refute Enum.any?(lines, &(&1 =~ "new_string")),
             "a diff approval never leaks the raw new_string arg"

      # The Pierre engine's own signatures (mirroring diff_viewer_test.exs):
      # a `▌` gutter bar on each changed row, the syntax-split content, and
      # the diff bg wash under it.
      rows = diff_rows(block)
      changed = Enum.filter(rows, &changed_row?/1)

      assert Enum.any?(changed, &(row_text(&1) =~ "old line")),
             "the removed line renders through the engine, gutter bar and all"

      assert Enum.any?(changed, &(row_text(&1) =~ "new line")),
             "the added line renders through the engine"

      assert Enum.all?(changed, &row_bg?/1),
             "every changed row carries the diff bg wash (Pierre styling)"

      assert Enum.any?(rows, &(row_text(&1) =~ "common")),
             "unchanged lines render as context rows"
    end

    test "bottom-identity reading order: diff rows first, then `± edit <path>`, and no ⚑ header at all" do
      # V's bottom-identity ruling: the diff IS the identity, so a
      # diff-carrying approval renders NO generic `⚑ <tool>` header row,
      # and the `± <verb> <path>` line reads at the BOTTOM -- rows, then
      # identity, then (in the hosting footer, not this block) the answer.
      block =
        only_approval_block([
          turn_started(),
          diff_approval_requested(
            "req-e",
            "/lib/x.ex",
            "old line\ncommon",
            "new line\ncommon"
          )
        ])

      # One flattened string per physical child (a Pierre `:row`'s spans
      # join into its full line text), so index order IS reading order.
      %{children: children} = Block.render(block, %{width: 80})

      rows =
        Enum.map(children, fn child ->
          child |> collect_text() |> Enum.join()
        end)

      refute Enum.any?(rows, &(&1 =~ "⚑")),
             "a diff-carrying approval renders no ⚑ header -- the diff IS the identity"

      diff_idx = Enum.find_index(rows, &(&1 =~ "old line"))
      identity_idx = Enum.find_index(rows, &(&1 =~ "± edit /lib/x.ex"))

      assert diff_idx, "the diff rows must render in the block body"
      assert identity_idx, "the ± edit identity line must render"

      assert diff_idx < identity_idx,
             "the diff rows read BEFORE the ± edit identity line (bottom-identity)"
    end

    test "intra-line word emphasis: the changed word gets a distinct bg tier" do
      # "old line" -> "new line": only the FIRST word changed. The Pierre
      # engine paints the changed word on the brighter emphasis bg tier and
      # the unchanged tail on the calmer (chroma-reduced) row wash -- two
      # DIFFERENT backgrounds within one changed line.
      block =
        only_approval_block([
          turn_started(),
          diff_approval_requested("req-w", "/lib/x.ex", "old line", "new line")
        ])

      del_row =
        block
        |> diff_rows()
        |> Enum.find(fn row -> changed_row?(row) and row_text(row) =~ "old" end)

      assert del_row, "the removed line renders as a changed row"

      bgs =
        del_row.children
        |> Enum.map(&Map.get(Map.get(&1, :style, %{}), :bg))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      assert length(bgs) >= 2,
             "the changed word and the unchanged tail sit on distinct bg tiers"
    end

    test "write_file on a new file is an all-adds diff" do
      rows =
        only_approval_block([
          turn_started(),
          diff_approval_requested("req-n", "/new.ex", "", "line a\nline b")
        ])
        |> diff_rows()

      added = Enum.filter(rows, &changed_row?/1)

      assert Enum.any?(added, &(row_text(&1) =~ "line a"))
      assert Enum.any?(added, &(row_text(&1) =~ "line b"))
    end

    test "shown == done: the approved diff image equals the sealed diff block's image" do
      # The approval carries {path, old, new}; the executed tool_result
      # carries the SAME image (the executor computes it once, staleness-
      # guarded). Both project; the approval's diff content must equal the
      # sealed :diff block's -- what was shown is what was done.
      path = "/lib/x.ex"
      old = "old line\ncommon"
      new = "new line\ncommon"

      approval =
        only_approval_block([
          turn_started(),
          diff_approval_requested("req-e", path, old, new)
        ])

      # The sealed diff block, as the executor's tool_result would project it.
      sealed_events = [
        turn_started(),
        %{
          id: 20,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            item_id: "i20",
            item_type: :tool_result,
            name: "edit_file",
            diff: true,
            path: path,
            old: old,
            new: new,
            language: "elixir"
          }
        }
      ]

      sealed =
        Enum.find(Projection.project(sealed_events).blocks, &(&1.kind == :diff))

      assert sealed, "the executed edit projects as a sealed :diff block"

      assert {approval.content.path, approval.content.old, approval.content.new} ==
               {sealed.content.path, sealed.content.old, sealed.content.new},
             "the diff shown at approval must equal the diff that executed"
    end
  end

  # -- 5. Keymap: answer keys never steal from the composer -----------------

  defp resolve(char, context),
    do: char |> Event.key() |> InputEvent.normalize() |> Keymap.resolve(context)

  describe "the answer-key guard: fires on an empty draft, never steals a typed letter" do
    test "y answers when a question is live and the draft is empty" do
      assert resolve("y", %{approval_pending?: true, composer_empty?: true}) ==
               %{type: :approval_answer, payload: %{answer: :allow}}
    end

    test "y stays plain text the moment there is a draft to protect" do
      assert resolve("y", %{approval_pending?: true, composer_empty?: false}) ==
               :passthrough
    end

    test "y does nothing when no question is live" do
      assert resolve("y", %{approval_pending?: false, composer_empty?: true}) ==
               :passthrough
    end

    test "n answers deny (winning over the plan-panel bind) with a live question and empty draft" do
      assert resolve("n", %{approval_pending?: true, composer_empty?: true}) ==
               %{type: :approval_answer, payload: %{answer: :deny}}
    end

    test "n falls through to the plan panel when no question is live" do
      assert resolve("n", %{approval_pending?: false, composing?: false}) ==
               %{type: :open_panel, payload: %{panel: :plan}}
    end

    test "a digit answers by position only with a live question and empty draft" do
      assert resolve("1", %{approval_pending?: true, composer_empty?: true}) ==
               %{type: :approval_answer, payload: %{answer: {:option, 0}}}

      assert resolve("1", %{approval_pending?: true, composer_empty?: false}) ==
               :passthrough
    end
  end
end
