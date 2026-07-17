defmodule Raxol.MCP.HarnessFooterDemoMcpSeamTest do
  @moduledoc """
  The MCP derivation seam over the U2 footer demos (harness TEA migration
  §7). These Components are display / input, not click-toggles, so the
  honest derivation is the ABSENCE of any action: the F0-mcp TreeWalker
  walks their stamped tree without error and advertises no spurious
  footer/status/composer tool. (Contrast the U1 blocks, whose on_click
  toggle derives a real `<id>.toggle`.)
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessComposerDemo
  alias Raxol.Playground.Demos.HarnessFooterStackDemo
  alias Raxol.Playground.Demos.HarnessStatusStripDemo

  @settle_ms 250
  @spurious ~r/^(footer|status|composer|notice|lane)/

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

  defp tool_names(module) do
    session =
      start_session(module, width: 80, height: 30, settle_ms: @settle_ms)

    names = session |> get_tools() |> Enum.map(& &1[:name])
    stop_session(session)
    names
  end

  test "the FooterStack demo derives no spurious tool (honest display absence)" do
    names = tool_names(HarnessFooterStackDemo)
    assert "discover_tools" in names
    refute Enum.any?(names, &(&1 =~ @spurious))
  end

  test "the StatusStrip demo derives no spurious tool" do
    names = tool_names(HarnessStatusStripDemo)
    assert "discover_tools" in names
    refute Enum.any?(names, &(&1 =~ @spurious))
  end

  test "the Composer demo derives no spurious tool" do
    names = tool_names(HarnessComposerDemo)
    assert "discover_tools" in names
    refute Enum.any?(names, &(&1 =~ @spurious))
  end
end
