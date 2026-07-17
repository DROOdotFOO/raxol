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
    test "the block shows the ± diff of the proposed change, path first" do
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

      assert Enum.any?(lines, &(&1 == "± /lib/x.ex")),
             "the path leads the diff (the referent)"

      assert Enum.member?(lines, "- old line")
      assert Enum.member?(lines, "+ new line")

      assert Enum.member?(lines, "  common"),
             "unchanged lines render as context"

      refute Enum.any?(lines, &(&1 =~ "args:")),
             "a diff approval shows the diff, never a truncated args line"
    end

    test "write_file on a new file is an all-adds diff" do
      lines =
        only_approval_block([
          turn_started(),
          diff_approval_requested("req-n", "/new.ex", "", "line a\nline b")
        ])
        |> render_lines()

      assert Enum.member?(lines, "+ line a")
      assert Enum.member?(lines, "+ line b")
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
