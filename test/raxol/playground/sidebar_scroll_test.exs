defmodule Raxol.Playground.SidebarScrollTest do
  @moduledoc """
  End-to-end regression coverage for cursor-follow sidebar scrolling and
  the subtle background-only scrollbar, driven through the real
  Lifecycle/Engine/Renderer pipeline via `Raxol.Headless`.

  `Raxol.UI.ScrollWindowTest` covers the pure windowing math in
  isolation; this file covers the playground's integration of it --
  chrome-aware visible-height budgeting, the full-list/windowed render
  mode switch (category headers only render when the whole list fits,
  since interleaving them into the windowed cursor math would break the
  scroll-by-exactly-one edge contract), and the raw scrollbar cell
  coloring -- at a terminal height short enough to force the sidebar
  list to overflow.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Raxol.Headless
  alias Raxol.Playground.App
  alias Raxol.Playground.Catalog

  @width 80
  @height 20
  @sidebar_width 28

  setup_all do
    case start_supervised({Headless, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    id = :"sidebar_scroll_#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(id) end)
    {:ok, id: id}
  end

  describe "App.init/1 and App.update/2 (model-level)" do
    test "picks up context width/height instead of the 80x24 fallback" do
      model = App.init(%{width: 80, height: @height})
      assert model.terminal_width == 80
      assert model.terminal_height == @height
    end

    test "cursor-follow: scroll_top advances by at most 1 per step as the cursor walks off the bottom edge" do
      model = App.init(%{width: 80, height: @height})
      total = length(Catalog.list_components())

      {_final_model, scroll_tops} =
        Enum.reduce(1..(total - 1), {model, [model.scroll_top]}, fn _,
                                                                    {m, acc} ->
          {m2, []} = App.update(key_event("j"), m)
          {m2, [m2.scroll_top | acc]}
        end)

      scroll_tops = Enum.reverse(scroll_tops)

      scroll_tops
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert abs(b - a) <= 1 end)
    end

    test "cursor never runs past the last component" do
      model = App.init(%{width: 80, height: @height})
      total = length(Catalog.list_components())

      final =
        Enum.reduce(1..(total + 10), model, fn _, m ->
          {m2, []} = App.update(key_event("j"), m)
          m2
        end)

      assert final.cursor == total - 1
    end

    test "k mirrors j back to scroll_top 0 at the top" do
      model = App.init(%{width: 80, height: @height})

      scrolled =
        Enum.reduce(1..15, model, fn _, m ->
          {m2, []} = App.update(key_event("j"), m)
          m2
        end)

      assert scrolled.scroll_top > 0

      back_at_top =
        Enum.reduce(1..15, scrolled, fn _, m ->
          {m2, []} = App.update(key_event("k"), m)
          m2
        end)

      assert back_at_top.cursor == 0
      assert back_at_top.scroll_top == 0
    end
  end

  describe "headless render: short terminal forces the sidebar to scroll" do
    test "initial frame shows the first widget with the cursor marker", %{
      id: id
    } do
      assert {:ok, ^id} =
               Headless.start(App, id: id, width: @width, height: @height)

      Process.sleep(150)

      {:ok, text} = Headless.screenshot(id)
      sidebar = sidebar_text(text)

      assert sidebar =~ "▸ Button"
      assert sidebar =~ "30 widgets"
    end

    test "scrolling past the visible window keeps the marker on screen and scrolls the top items out",
         %{id: id} do
      assert {:ok, ^id} =
               Headless.start(App, id: id, width: @width, height: @height)

      Process.sleep(150)

      # Walk far enough down to guarantee the window has scrolled (visible
      # height is well under 30 components + 8 category headers at h=20).
      for _ <- 1..20, do: Headless.send_key(id, "j")
      Process.sleep(100)

      {:ok, text} = Headless.screenshot(id)
      sidebar = sidebar_text(text)

      # the cursor marker is still visible somewhere in the (bounded) sidebar
      assert sidebar =~ "▸"
      # the first item has scrolled out of the sidebar's own column range
      # (it may still legitimately appear in the right-hand demo panel,
      # which tracks `selected`, not `cursor` -- so we only check the
      # sidebar's own text slice)
      refute sidebar =~ "Button"

      # the box border stays intact -- windowing never grows the sidebar
      # past its allotted height
      assert length(String.split(text, "\n")) <= @height + 1
    end

    test "the sidebar box never exceeds the terminal height while scrolling", %{
      id: id
    } do
      assert {:ok, ^id} =
               Headless.start(App, id: id, width: @width, height: @height)

      Process.sleep(150)

      total = length(Catalog.list_components())

      Enum.each(1..(total - 1), fn _ ->
        Headless.send_key(id, "j")
        {:ok, text} = Headless.screenshot(id)
        lines = String.split(text, "\n", trim: false)
        assert length(lines) <= @height + 1
      end)
    end

    test "the scrollbar thumb paints the rightmost sidebar column with the pastel-blue background, proportionally",
         %{id: id} do
      assert {:ok, ^id} =
               Headless.start(App, id: id, width: @width, height: @height)

      Process.sleep(150)

      for _ <- 1..10, do: Headless.send_key(id, "j")
      Process.sleep(100)

      {:ok, buffer} = Headless.get_buffer(id)
      # box border occupies column 0; interior runs 1..(sidebar_width - 2
      # border chars), so the last interior column -- where the scrollbar
      # cell lands -- is at this absolute index.
      col = @sidebar_width - 2

      backgrounds =
        buffer.cells
        |> Enum.map(&Enum.at(&1, col))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.style.background)

      thumb_rows = Enum.count(backgrounds, &(&1 == {110, 140, 180}))

      # some rows carry the thumb color, but not the entire column (a
      # proportional thumb, not a full-height bar)
      assert thumb_rows > 0
      assert thumb_rows < length(backgrounds)
    end

    test "no scrollbar coloring appears when the filtered list fits entirely",
         %{id: id} do
      assert {:ok, ^id} =
               Headless.start(App, id: id, width: @width, height: @height)

      Process.sleep(150)

      # Filter down to a category small enough to fit without scrolling.
      Headless.send_key(id, "f")
      Process.sleep(50)

      {:ok, buffer} = Headless.get_buffer(id)
      # box border occupies column 0; interior runs 1..(sidebar_width - 2
      # border chars), so the last interior column -- where the scrollbar
      # cell lands -- is at this absolute index.
      col = @sidebar_width - 2

      backgrounds =
        buffer.cells
        |> Enum.map(&Enum.at(&1, col))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.style.background)

      refute Enum.any?(backgrounds, &(&1 == {110, 140, 180}))
    end
  end

  # --- Helpers ---

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  # Slices every line down to just the sidebar box's own columns so
  # assertions don't accidentally match text from the demo panel on the
  # right (which tracks `selected`, independent of sidebar scroll).
  defp sidebar_text(screenshot) do
    screenshot
    |> String.split("\n")
    |> Enum.map_join("\n", &String.slice(&1, 0, @sidebar_width))
  end

  defp safe_stop(id) do
    try do
      Headless.stop(id)
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
