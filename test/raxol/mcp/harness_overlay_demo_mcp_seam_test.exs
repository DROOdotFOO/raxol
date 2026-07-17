defmodule Raxol.MCP.HarnessOverlayDemoMcpSeamTest do
  @moduledoc """
  U3 MCP autotest over `HarnessOverlayDemo`, on the F0-mcp seam (template:
  `harness_block_demo_mcp_seam_test.exs`): an overlay hosted as an
  `AbsoluteLayer` dialog child derives its tools LIVE from the running view
  tree. This is the seam U3 extended -- TreeWalker now descends into an
  `:absolute_layer`'s `flow_child`/`overlays`, so the picker's stamped root
  (`overlay-picker`, `component_module: Picker`) is reached even though it
  lives inside the overlay, not the flow. The derived
  `overlay-picker.dismiss` tool then closes the overlay through the real
  Dispatcher pipeline via the same synthetic Escape a keystroke fires.
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test
  import Raxol.MCP.Test.Assertions

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessOverlayDemo

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

  test "the open picker overlay derives its tools live; MCP dismiss closes it" do
    session =
      start_session(HarnessOverlayDemo,
        width: 100,
        height: 30,
        settle_ms: @settle_ms
      )

    # Closed: no overlay in the tree, so no overlay tools are derived.
    closed = session |> get_tools() |> Enum.map(& &1[:name])
    refute "overlay-picker.select" in closed
    refute "overlay-picker.dismiss" in closed

    # Open the picker. The overlay is an :absolute_layer dialog child --
    # only reachable because TreeWalker descends flow_child/overlays.
    session = send_key(session, "p")
    Process.sleep(@settle_ms)

    names = session |> get_tools() |> Enum.map(& &1[:name])

    assert "overlay-picker.select" in names,
           "expected overlay-picker tools derived from the dialog child, got: #{inspect(names)}"

    assert "overlay-picker.dismiss" in names

    # StructuredScreenshot sanity: the stamped picker root surfaces in the
    # widgets resource with its children.
    session
    |> assert_component("overlay-picker", fn c ->
      c[:type] == :column and is_list(c[:children])
    end)

    # Dismiss through the full MCP pipeline (synthetic Escape -> the demo's
    # key routing -> the picker's cancel -> model close).
    call_tool(session, "overlay-picker.dismiss", %{})
    Process.sleep(@settle_ms)
    assert_model(session, fn m -> m.overlay == nil end)

    stop_session(session)
  end
end
