defmodule Raxol.UI.Components.Harness.BlockInteractiveTest do
  @moduledoc """
  The U1-d re-hosting contract: `Block` as a first-class interactive
  Component on the real pipeline (harness TEA migration section 4/6),
  converged on the U1-a/U1-b block-Component seam.

  Three seams under pin:

    1. `render/2` with `context[:id]` STAMPS the root `:column` in place --
       `id`, semantic `attrs` (incl. `component_module: Block` for
       `Raxol.MCP.TreeWalker`), and an `on_click` toggle message -- rather
       than emitting a new node type. WITHOUT `context[:id]` the render is
       the legacy column, untouched (the shelved Surface substrate never
       sees a stamp).
    2. `handle_event/3` (CONTROLLED, section-2 doctrine): Enter / Space /
       the `z` key EMIT the stamped `on_click` message as an outgoing
       command; the block holds no state (the app's `update/2` folds the
       model's `%Block{}`).
    3. `Raxol.MCP.ToolProvider`: an `on_click`-bearing node derives one
       `toggle_fold` action; `handle_tool_call` returns a widget-targeted
       click, which the Bubbler's inline `on_click` path turns into the
       same toggle message a physical click fires (Button's F0-mcp mirror).
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Block

  defp tool_block(opts \\ []) do
    events = [
      %{
        id: "e1",
        type: :item_started,
        payload: %{name: "mix", args: %{task: "test"}}
      }
      | Keyword.get(opts, :extra_events, [])
    ]

    Block.from_events(:tool_call, events, Keyword.take(opts, [:fold, :seal]))
  end

  defp completed_tool_block(opts \\ []) do
    tool_block(
      Keyword.merge(
        [
          seal: :sealed,
          extra_events: [
            %{
              id: "e2",
              type: :item_completed,
              payload: %{
                item_type: :tool_result,
                content: "42 tests, 0 failures",
                exit_code: 0
              }
            }
          ]
        ],
        opts
      )
    )
  end

  describe "render/2 interactive stamp (context[:id])" do
    test "stamps the root column with id, component_module attr, and on_click" do
      block = completed_tool_block()
      legacy = Block.render(block, %{width: 80})

      stamped = Block.render(block, %{width: 80, id: "tool_ok"})

      # Same node shape (a column), now carrying identity + the seam attrs.
      assert stamped.type == :column
      assert stamped.id == "tool_ok"
      assert stamped.attrs.component_module == Block
      assert stamped.attrs.kind == :tool_call
      assert stamped.attrs.fold == :folded
      assert stamped.attrs.seal == :sealed
      assert stamped.on_click == {:harness_block, :toggle_fold, "tool_ok"}
      # The body is unchanged -- only identity/attrs/on_click were added.
      assert stamped.children == legacy.children
    end

    test "without context[:id] the render is the legacy column, unstamped" do
      view = Block.render(completed_tool_block(), %{width: 80})
      assert view.type == :column
      refute Map.get(view, :id)
      refute Map.get(view, :on_click)
    end

    test "tool attrs carry the outcome state the glyph renders: ok" do
      view = Block.render(completed_tool_block(), %{width: 80, id: "t"})
      assert view.attrs.state == :ok
      assert view.attrs.name == "mix"
      assert view.attrs.tainted == false
    end

    test "tool attrs state: failed on a non-zero exit" do
      block =
        tool_block(
          seal: :sealed,
          extra_events: [
            %{
              id: "e2",
              type: :item_completed,
              payload: %{item_type: :tool_result, content: "boom", exit_code: 2}
            }
          ]
        )

      assert Block.render(block, %{width: 80, id: "t"}).attrs.state == :failed
    end

    test "tool attrs state: no_result on a sealed tool with no result/exit" do
      view = Block.render(tool_block(seal: :sealed), %{width: 80, id: "t"})
      assert view.attrs.state == :no_result
    end

    test "tool attrs state: running under the pending footer-preview flag" do
      view = Block.render(tool_block(), %{width: 80, id: "t", pending?: true})
      assert view.attrs.state == :running
    end

    test "tool attrs carry taint provenance" do
      block =
        tool_block(
          seal: :sealed,
          extra_events: [
            %{
              id: "e2",
              type: :item_completed,
              provenance: %{trust: :tainted},
              payload: %{item_type: :tool_result, content: "fetched page"}
            }
          ]
        )

      assert Block.render(block, %{width: 80, id: "t"}).attrs.tainted == true
    end

    test "error blocks stamp too, with their kind in attrs" do
      block =
        Block.from_events(:error, [
          %{id: "e1", type: :error, payload: %{reason: "connection refused"}}
        ])

      view = Block.render(block, %{width: 80, id: "err"})
      assert view.id == "err"
      assert view.attrs.kind == :error
      assert view.attrs.component_module == Block
    end

    test "context[:on_toggle] overrides the on_click toggle message" do
      view =
        Block.render(completed_tool_block(), %{
          width: 80,
          id: "t",
          on_toggle: {:custom, :msg}
        })

      assert view.on_click == {:custom, :msg}
    end
  end

  describe "handle_event/3 (controlled -- emits the toggle command)" do
    defp element(overrides \\ %{}) do
      Map.merge(
        %{
          type: :column,
          id: "tool_ok",
          on_click: {:harness_block, :toggle_fold, "tool_ok"}
        },
        overrides
      )
    end

    test "enter and space emit the stamped toggle message, state unchanged" do
      for key <- [:enter, :space] do
        event = %Event{type: :key, data: %{key: key}}
        el = element()

        assert {^el, [{:harness_block, :toggle_fold, "tool_ok"}]} =
                 Block.handle_event(event, el, %{})
      end
    end

    test "the z fold key emits the toggle message" do
      event = %Event{type: :key, data: %{key: :char, char: "z"}}
      el = element()

      assert {^el, [{:harness_block, :toggle_fold, "tool_ok"}]} =
               Block.handle_event(event, el, %{})
    end

    test "a node without an on_click emits nothing" do
      event = %Event{type: :key, data: %{key: :enter}}
      el = %{type: :column, id: "x"}
      assert {^el, []} = Block.handle_event(event, el, %{})
    end

    test "unrelated events emit nothing (click is left to the Bubbler's inline path)" do
      for event <- [
            %Event{type: :key, data: %{key: :char, char: "q"}},
            %Event{type: :click, data: %{}},
            %Event{type: :mouse, data: %{}}
          ] do
        el = element()
        assert {^el, []} = Block.handle_event(event, el, %{})
      end
    end
  end

  describe "ToolProvider (MCP derivation)" do
    test "mcp_tools/1 derives one toggle_fold tool from an on_click-bearing node" do
      node = %{
        type: :column,
        id: "tool_ok",
        on_click: {:harness_block, :toggle_fold, "tool_ok"},
        attrs: %{component_module: Block, kind: :tool_call, name: "mix"}
      }

      assert [%{name: "toggle_fold", description: description}] =
               Block.mcp_tools(node)

      assert description =~ "mix"
      assert description =~ "tool_call"
    end

    test "mcp_tools/1 derives nothing from a node without on_click" do
      assert Block.mcp_tools(%{type: :column, id: "x", attrs: %{}}) == []
    end

    test "handle_tool_call dispatches a widget-targeted click (Button's shape)" do
      context = %{widget_id: "tool_ok", widget_state: %{}, dispatcher_pid: nil}

      assert {:ok, _text, [%Event{type: :click, data: %{widget_id: "tool_ok"}}]} =
               Block.handle_tool_call("toggle_fold", %{}, context)
    end

    test "unknown actions error honestly" do
      assert {:error, _} = Block.handle_tool_call("explode", %{}, %{})
    end
  end
end
