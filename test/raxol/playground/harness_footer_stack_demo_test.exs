defmodule Raxol.Playground.HarnessFooterStackDemoTest do
  @moduledoc """
  The honest-notice / fit-priority law (harness TEA migration §5 law 3)
  observed end-to-end through the demo buffer: drop order, protected
  channels never shed, and budget-1 notice-wins. The exact per-step drop
  order is pinned as a pure falsifier in
  `Raxol.UI.Components.Harness.FooterStackTest`; this asserts the same law
  is what actually reaches the screen.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessFooterStackDemo

  @settle_ms 150

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

  defp start_demo do
    id = :"footer_demo_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(HarnessFooterStackDemo, id: id, width: 60, height: 24)

    Process.sleep(@settle_ms)
    id
  end

  defp screenshot(id) do
    {:ok, t} = Headless.screenshot(id)
    t
  end

  defp shrink(id, n) do
    Enum.each(1..n//1, fn _ -> Headless.send_key(id, "[") end)
    Process.sleep(@settle_ms)
  end

  describe "refusal fixture: drop order + notice-wins" do
    test "at the full budget every content row is on screen" do
      id = start_demo()
      s = screenshot(id)

      for text <- [
            "status: thinking 3s",
            "divider: 5 unread",
            "preview: line A",
            "preview: line B",
            "> composer prompt",
            "  composer cont",
            "notice: no block focused"
          ] do
        assert s =~ text
      end
    end

    test "the preview yields from its tail after the composer_sep blank" do
      id = start_demo()
      # 8 -> 6: composer_sep (blank) then the preview's tail row.
      shrink(id, 2)
      s = screenshot(id)

      refute s =~ "preview: line B"
      # ...while everything below the preview in the drop order survives.
      assert s =~ "preview: line A"
      assert s =~ "> composer prompt"
      assert s =~ "notice: no block focused"
    end

    test "the composer yields from its tail before the status" do
      id = start_demo()
      # 8 -> 3: composer_sep, both preview rows, divider, one composer row.
      shrink(id, 5)
      s = screenshot(id)

      refute s =~ "  composer cont"
      assert s =~ "> composer prompt"
      assert s =~ "status: thinking 3s"
      assert s =~ "notice: no block focused"
    end

    test "budget-1: the notice is the one row that wins" do
      id = start_demo()
      shrink(id, 7)
      s = screenshot(id)

      assert s =~ "notice: no block focused"
      refute s =~ "status: thinking"
      refute s =~ "> composer prompt"
    end
  end

  describe "live fixture: protected channels are never shed" do
    test "lane / submitting / notice ride a budget that drops every discretionary group" do
      id = start_demo()
      Headless.send_key(id, "m")
      Process.sleep(@settle_ms)
      # live total 12 -> 3 (exactly the three protected rows).
      shrink(id, 9)
      s = screenshot(id)

      assert s =~ "lane: reconnecting to session"
      assert s =~ "submitting: sending hello"
      assert s =~ "notice: session degraded"

      refute s =~ "status: running mix"
      refute s =~ "> composer prompt"
      refute s =~ "overlay: pick"
    end
  end
end
