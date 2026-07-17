defmodule Raxol.Playground.Demos.HarnessOverlayDemoTest do
  @moduledoc """
  U3 autotest contract for `HarnessOverlayDemo` (harness TEA migration §7):
  the overlays (picker / projection panels / diff-expansion) re-hosted as
  LayoutEngine children.

  The gap-closing pin lives here: the map-machine `Raxol.Harness.Surface`
  REFUSES an overlay in `:full_viewport` (`open_overlay/open_panel/
  expand_focused_diff` -> `{:error, :no_footer}`, surface.ex:3805/3936/4401,
  asserted below as the documented contrast); under the TEA pipeline the
  same overlay is just an `:absolute_layer` dialog child over the transcript
  -- no footer to grow, no refusal. Pure-`update/2`/`view/1` pins carry the
  laws; headless pins prove it actually paints through the real pipeline.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.Headless
  alias Raxol.Headless.EventBuilder
  alias Raxol.Playground.Demos.HarnessOverlayDemo, as: Demo
  alias Raxol.UI.Components.Harness.Picker

  # -- pure helpers (drive update/2 + walk view/1 directly) ----------------

  defp open(model, key), do: dispatch(model, EventBuilder.key(key))

  defp dispatch(model, message) do
    {model, _cmds} = Demo.update(message, model)
    model
  end

  defp type(model, string) do
    string
    |> String.graphemes()
    |> Enum.reduce(model, fn ch, acc -> dispatch(acc, EventBuilder.key(ch)) end)
  end

  # Recursively every node in a view tree, following :children (list or
  # single map), :flow_child, and :overlays[].element -- so an absolute
  # layer's overlay is visited.
  defp walk(node) when is_map(node) do
    children =
      (List.wrap(Map.get(node, :children)) ++
         List.wrap(Map.get(node, :flow_child)) ++
         overlay_elements(node))
      |> Enum.filter(&is_map/1)

    [node | Enum.flat_map(children, &walk/1)]
  end

  defp walk(_), do: []

  defp overlay_elements(node) do
    node |> Map.get(:overlays, []) |> Enum.map(&Map.get(&1, :element))
  end

  defp view_text(node) do
    node
    |> walk()
    |> Enum.flat_map(fn
      %{content: c} when is_binary(c) -> [c]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp has_id?(node, id), do: Enum.any?(walk(node), &(Map.get(&1, :id) == id))

  describe "the gap closes: overlays host as LayoutEngine children" do
    test "closed view is a plain flow tree; opening one wraps it in an :absolute_layer dialog" do
      closed = Demo.view(Demo.init(nil))
      refute match?(%{type: :absolute_layer}, closed)

      open = Demo.view(open(Demo.init(nil), "p"))

      assert %{type: :absolute_layer, flow_child: flow, overlays: [overlay]} =
               open

      assert overlay.dialog == true,
             "the overlay is a backdrop-dimming dialog child, not a grown footer"

      assert has_id?(overlay.element, "overlay-picker"),
             "the picker lives inside the overlay layer..."

      refute has_id?(flow, "overlay-picker"),
             "...not in the transcript flow child"
    end

    test "the map-machine still refuses the SAME overlay in :full_viewport (documented contrast)" do
      # The shelved footer-grow substrate has no alt-screen equivalent for
      # `InlineAuthority.set_footer_rows/2`, so `open_overlay/open_panel/
      # expand_focused_diff` refuse in :full_viewport (surface.ex:3805/3936/
      # 4401). The refusal clauses read only mode/overlay/expansion, so a
      # minimal model exercises the exact real clause -- the gap the TEA
      # overlay-as-layout-child path (this demo) closes.
      model = %{
        mode: :full_viewport,
        overlay: nil,
        expansion: nil,
        focused_index: 0
      }

      assert {:error, :no_footer} = Surface.open_overlay(model, ["a", "b"])
      assert {:error, :no_footer} = Surface.open_panel(model, :memory)
      assert {:error, :no_footer} = Surface.expand_focused_diff(model)
    end

    test "panels and the diff-expansion host as dialog children too" do
      for {key, id} <- [{"1", "overlay-memory"}, {"e", "expansion-header"}] do
        view = Demo.view(open(Demo.init(nil), key))
        assert %{type: :absolute_layer, overlays: [overlay]} = view
        assert overlay.dialog == true
        assert has_id?(overlay.element, id)
      end
    end
  end

  describe "laws (pure update/2 + view/1)" do
    test "one overlay at a time: a panel summon while the picker is open is filter text" do
      model = Demo.init(nil) |> open("p") |> open("1")

      assert {:picker, picker} = model.overlay,
             "still the picker -- '1' never opened a second overlay"

      assert Picker.query(picker) == "1", "'1' was routed to the filter"
    end

    test "esc dismisses the open overlay (never leaves it dangling)" do
      model = Demo.init(nil) |> open("p") |> dispatch(EventBuilder.key(:escape))
      assert model.overlay == nil
    end

    test "the live preview is suppressed while an overlay is open" do
      base = Demo.init(nil)
      assert view_text(Demo.view(base)) =~ "assistant is composing"

      opened = open(base, "p")
      refute view_text(Demo.view(opened)) =~ "assistant is composing"
      assert view_text(Demo.view(opened)) =~ "Command Palette"

      reclosed = dispatch(opened, EventBuilder.key(:escape))
      assert view_text(Demo.view(reclosed)) =~ "assistant is composing"
    end

    test "honest degenerate refusal: a cramped viewport refuses, then recovers" do
      cramped =
        Demo.init(nil)
        |> dispatch(Event.new(:resize, %{width: 80, height: 4}))
        |> open("p")

      assert cramped.overlay == nil, "no room -> no overlay"
      assert cramped.notice =~ "cannot host overlay"

      recovered =
        cramped
        |> dispatch(Event.new(:resize, %{width: 80, height: 24}))
        |> open("p")

      assert {:picker, _} = recovered.overlay
    end

    test "filter narrows the ranked list via the EventBuilder char shape (the picker fix)" do
      model = Demo.init(nil) |> open("p") |> type("quit")
      {:picker, picker} = model.overlay
      labels = picker |> Picker.ranked() |> Enum.map(& &1.key)

      assert "Quit the session" in labels
      refute "Approve the pending tool call" in labels
    end

    test "enter selects the current match: overlay closes, pick notice set" do
      model =
        Demo.init(nil)
        |> open("p")
        |> type("quit")
        |> dispatch(EventBuilder.key(:enter))

      assert model.overlay == nil
      assert model.notice =~ "picked: Quit the session"
    end

    test "the diff-expansion scrolls with j/k, clamped, and q dismisses" do
      # Shrink the viewport so the scroll window is smaller than the diff
      # (at the default 24 rows the whole diff fits and there is nothing to
      # scroll -- itself the honest clamp).
      opened =
        Demo.init(nil)
        |> dispatch(Event.new(:resize, %{width: 80, height: 10}))
        |> open("e")

      assert {:expansion, %{scroll_top: 0}} = opened.overlay

      up_at_top = dispatch(opened, EventBuilder.key("k"))

      assert {:expansion, %{scroll_top: 0}} = up_at_top.overlay,
             "clamped at top"

      scrolled = dispatch(opened, EventBuilder.key("j"))
      assert {:expansion, %{scroll_top: 1}} = scrolled.overlay

      assert dispatch(scrolled, EventBuilder.key("q")).overlay == nil
    end
  end

  describe "headless: the overlay actually paints through the pipeline" do
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

    defp start_demo(id) do
      {:ok, session} = Headless.start(Demo, id: id)
      Process.sleep(200)
      session
    end

    defp press(session, key) do
      :ok = Headless.send_key(session, key)
      Process.sleep(120)
      session
    end

    test "the picker paints as a dialog over the transcript, and esc removes it" do
      session = start_demo(:ov_paint)

      {:ok, closed} = Headless.screenshot(session)
      refute closed =~ "Command Palette"
      assert closed =~ "Refactor calculate", "transcript is present"
      assert closed =~ "assistant is composing", "preview present when closed"

      press(session, "p")
      {:ok, opened} = Headless.screenshot(session)
      assert opened =~ "Command Palette", "the overlay painted..."
      assert opened =~ "Approve the pending tool call", "...with its items"

      assert opened =~ "Refactor calculate",
             "...over the still-present transcript"

      refute opened =~ "assistant is composing",
             "preview suppressed under overlay"

      press(session, :escape)
      {:ok, reclosed} = Headless.screenshot(session)
      refute reclosed =~ "Command Palette"
      assert reclosed =~ "assistant is composing"

      Headless.stop(session)
    end

    test "typing filters the visible list" do
      session = start_demo(:ov_filter)
      press(session, "p")

      for ch <- ["q", "u", "i", "t"], do: press(session, ch)

      {:ok, filtered} = Headless.screenshot(session)
      assert filtered =~ "Quit the session"
      refute filtered =~ "Approve the pending tool call"

      Headless.stop(session)
    end

    test "a projection panel and the diff-expansion also paint as overlays" do
      session = start_demo(:ov_panel)

      press(session, "1")
      {:ok, memory} = Headless.screenshot(session)
      assert memory =~ "Memory"
      assert memory =~ "session_id"

      press(session, :escape)
      press(session, "e")
      {:ok, expansion} = Headless.screenshot(session)
      assert expansion =~ "lib/orders/total.ex"

      Headless.stop(session)
    end
  end
end
