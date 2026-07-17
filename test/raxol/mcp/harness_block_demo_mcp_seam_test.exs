defmodule Raxol.MCP.HarnessBlockDemoMcpSeamTest do
  @moduledoc """
  U1-a MCP autotests over the harness block demos, on the F0-mcp seam
  (template: `button_demo_mcp_seam_test.exs`): the demos derive their
  tools LIVE from the running app's view tree -- the blocks' stamped
  `id`/`attrs.component_module`/`on_click` feed TreeWalker, the derived
  `<id>.toggle` semantic action dispatches a widget-targeted click
  through the Dispatcher/Bubbler, and the same model mutation is
  reachable through a plain keystroke. StructuredScreenshot sanity rides
  the widgets resource (`assert_component`).
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test
  import Raxol.MCP.Test.Assertions

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessMessageBlockDemo
  alias Raxol.Playground.Demos.HarnessReasoningBlockDemo

  # Covers dispatcher cast + engine re-render + the ToolSynchronizer's
  # 50ms debounce on slow CI machines (same budget as the button seam test).
  @settle_ms 250

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  test "reasoning demo derives its toggle live; the MCP toggle drives model, tree, and frame" do
    session =
      start_session(HarnessReasoningBlockDemo,
        width: 100,
        height: 30,
        settle_ms: @settle_ms
      )

    names = session |> get_tools() |> Enum.map(& &1[:name])

    assert "reasoning.toggle" in names,
           "expected a live-derived toggle, got: #{inspect(names)}"

    assert "discover_tools" in names

    # StructuredScreenshot sanity: the stamped root surfaces in the
    # widgets resource with its children.
    session
    |> assert_component("reasoning", fn c ->
      c[:type] == :column and is_list(c[:children]) and c[:children] != []
    end)

    # Toggle through the full MCP pipeline -- no shortcuts.
    session
    |> toggle("reasoning")
    |> assert_model(fn m -> m.expanded == true end)

    assert screenshot(session) =~ "▾ 4 lines"

    session
    |> toggle("reasoning")
    |> assert_model(fn m -> m.expanded == false end)

    assert screenshot(session) =~ "▸ 4 lines — Phase 1"

    stop_session(session)
  end

  test "message demo derives one toggle per turn; MCP fold and unfold round-trip" do
    session =
      start_session(HarnessMessageBlockDemo,
        width: 100,
        height: 40,
        settle_ms: @settle_ms
      )

    names = session |> get_tools() |> Enum.map(& &1[:name])

    for id <- ["msg-1", "msg-2", "msg-3", "msg-4"] do
      assert "#{id}.toggle" in names,
             "expected #{id}.toggle among live-derived tools, got: #{inspect(names)}"
    end

    session
    |> assert_component("msg-1", fn c -> c[:type] == :column end)

    # Fold msg-2 via the derived tool: model, widgets resource, and frame agree.
    session
    |> toggle("msg-2")
    |> assert_model(fn m ->
      Enum.find(m.turns, &(&1.id == "msg-2")).folded == true
    end)

    folded_frame = screenshot(session)
    assert folded_frame =~ "▸ Two suites are red:"
    refute folded_frame =~ "renderer_test.exs"

    # The folded header keeps the block's identity -- toggling again unfolds.
    session
    |> toggle("msg-2")
    |> assert_model(fn m ->
      Enum.find(m.turns, &(&1.id == "msg-2")).folded == false
    end)

    assert screenshot(session) =~ "renderer_test.exs"

    stop_session(session)
  end

  test "keystroke and MCP toggle share one vocabulary: z folds the focused turn" do
    session =
      start_session(HarnessMessageBlockDemo,
        width: 100,
        height: 40,
        settle_ms: @settle_ms
      )

    session
    |> send_key("z")
    |> assert_model(fn m ->
      Enum.find(m.turns, &(&1.id == "msg-1")).folded == true
    end)

    assert screenshot(session) =~ "▸ Run the tests"

    # And the derived tool unfolds what the key folded -- same message,
    # same model mutation point.
    session
    |> toggle("msg-1")
    |> assert_model(fn m ->
      Enum.find(m.turns, &(&1.id == "msg-1")).folded == false
    end)

    stop_session(session)
  end
end
