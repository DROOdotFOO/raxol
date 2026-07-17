defmodule Raxol.Playground.HarnessToolBlockDemoTest do
  @moduledoc """
  U1-d autotest: the `HarnessToolBlockDemo` driven headlessly and via MCP,
  pinning the CURRENT tool-render contract (the tool-render unit f74184a9e +
  the U1 re-hosting). The demo IS the fixture (harness TEA migration sec 7).

  §7 pins covered here:

    * the compact format EXACTLY -- `⚙ name key: value`, no parens, no
      quotes, no `· ✓ N B` receipt (screenshot bytes);
    * glyph-state transitions -- `⚙` ok / `✗` failed / `⊘` no-result, and
      the `⚠︎ untrusted` taint suffix (drive `[c]`/`[x]`, re-read);
    * cluster tightness -- the four tool lines are adjacent with NO blank
      row inside the cluster, and one blank row on each dialogue side;
    * spinner frame advance across SCRIPTED ticks -- `[t]` (the injected
      clock) advances the running-line margin braille glyph, never a wall
      clock;
    * fold via `send_key` -- `[z]` expands the focused compact line to its
      full result body;
    * MCP derivation live -- each block stamps its root `:column` with an
      id + `attrs.component_module`, so it derives `<id>.toggle_fold`, the
      tool flips fold through the same seam a physical click uses, and the
      block root is addressable in the StructuredScreenshot.

  Prominence note: the alarm-prominence law is pinned at `Block.render/2`'s
  output map (a failed/error header carries no `dim`, a successful
  machinery one does) -- a pure, flake-free falsifier that does not depend
  on the backend. (U1-a's backends layer now also translates `:dim` to the
  cell `:faint` bit, so it round-trips to the buffer too; the map remains
  the authoritative layer this test pins.)
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test
  import Raxol.MCP.Test.Assertions

  alias Raxol.Harness.StatusStrip
  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessToolBlockDemo
  alias Raxol.UI.Components.Harness.Block

  @settle_ms 200

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

  # -- headless render contract ---------------------------------------------

  describe "compact format (screenshot bytes)" do
    test "each tool line is `glyph name key: value` -- no parens, quotes, or receipt" do
      id = start_headless()
      text = screenshot!(id)

      ok = line_with(text, "mix")
      assert ok =~ "⚙ mix task: test"
      # no arg braces / quotes, no ` · ✓ N B · Nms` receipt tail
      refute ok =~ "("
      refute ok =~ "\""
      refute ok =~ "✓"
      refute ok =~ ~r/\d+ B/

      # ⊘ absence, ✗ failure, and the surviving taint suffix
      assert line_with(text, "glob") =~ "⊘ glob pattern: **/README*"
      assert line_with(text, "git") =~ "✗ git command: push origin main"
      taint = line_with(text, "web_fetch")
      assert taint =~ "⚙ web_fetch url:"
      assert taint =~ "· ⚠︎ untrusted"

      Headless.stop(id)
    end
  end

  describe "glyph-state transitions" do
    test "the live tail tool moves ⚙running -> ✗failed -> ⚙ok as its outcome changes" do
      id = start_headless()

      # Initially running: a plain ⚙ on the cargo line (spinner in margin).
      assert line_with(screenshot!(id), "cargo") =~
               "⚙ cargo command: build --release"

      # [x] seals it failed -> ✗ leads the line.
      :ok = Headless.send_key(id, "x")
      Process.sleep(@settle_ms)

      assert line_with(screenshot!(id), "cargo") =~
               "✗ cargo command: build --release"

      # [c] reseals it ok -> back to ⚙.
      :ok = Headless.send_key(id, "c")
      Process.sleep(@settle_ms)

      assert line_with(screenshot!(id), "cargo") =~
               "⚙ cargo command: build --release"

      Headless.stop(id)
    end
  end

  describe "cluster tightness (blank-row rhythm)" do
    test "the four sealed tools cluster tight; blanks fall on the dialogue sides only" do
      id = start_headless()
      lines = screenshot!(id) |> String.split("\n")

      mix = index_of(lines, "mix task")
      glob = index_of(lines, "glob pattern")
      web = index_of(lines, "web_fetch")
      git = index_of(lines, "git command")

      # Adjacent machinery blocks: no interior blank -> consecutive rows.
      assert glob == mix + 1
      assert web == glob + 1
      assert git == web + 1

      # A blank row sits above the cluster (after the opening message) and
      # below it (before the closing message) -- the tool run is set off
      # from surrounding speech, never blank-separated within.
      assert blank?(lines, mix - 1)
      assert blank?(lines, git + 1)

      Headless.stop(id)
    end
  end

  describe "spinner frame advance (scripted clock)" do
    test "[t] ticks advance the running-line margin braille glyph, deterministically" do
      id = start_headless()
      [f0, f1, f2 | _] = StatusStrip.spinner_glyphs()

      assert running_margin_glyph(screenshot!(id)) == f0

      :ok = Headless.send_key(id, "t")
      Process.sleep(@settle_ms)
      assert running_margin_glyph(screenshot!(id)) == f1

      :ok = Headless.send_key(id, "t")
      Process.sleep(@settle_ms)
      assert running_margin_glyph(screenshot!(id)) == f2

      Headless.stop(id)
    end

    test "with no tick, the glyph never moves (event-clocked, not wall-clock)" do
      id = start_headless()
      before = running_margin_glyph(screenshot!(id))
      Process.sleep(150)
      # A second screenshot with zero intervening events: identical glyph.
      assert running_margin_glyph(screenshot!(id)) == before
      Headless.stop(id)
    end
  end

  describe "fold via send_key" do
    test "[z] expands the focused compact tool line to its full result body" do
      id = start_headless()

      # Focus starts on tool_ok (folded). Its result body is not shown yet.
      refute screenshot!(id) =~ "42 tests, 0 failures"

      assert {:ok, %{blocks: %{tool_ok: %{fold: :folded}}}} =
               Headless.get_model(id)

      :ok = Headless.send_key(id, "z")
      Process.sleep(@settle_ms)

      assert {:ok, %{blocks: %{tool_ok: %{fold: :expanded}}}} =
               Headless.get_model(id)

      text = screenshot!(id)
      assert text =~ "42 tests, 0 failures"
      # Still the same compact header line above the body.
      assert line_with(text, "mix") =~ "⚙ mix task: test"

      Headless.stop(id)
    end
  end

  describe "alarm prominence (Block.render map -- the authoritative layer)" do
    test "a failed tool header is non-dim; a successful one is dim" do
      id = start_headless()
      {:ok, %{blocks: blocks}} = Headless.get_model(id)

      ok_header =
        Block.render(blocks.tool_ok, %{width: 76}) |> first_child_style()

      fail_header =
        Block.render(blocks.tool_fail, %{width: 76}) |> first_child_style()

      assert ok_header == %{dim: true}
      refute Map.get(fail_header, :dim, false)

      Headless.stop(id)
    end
  end

  # -- MCP derivation --------------------------------------------------------

  describe "MCP: derived tools + toggle seam + StructuredScreenshot" do
    test "each block derives a namespaced toggle_fold tool from the live tree" do
      session =
        start_session(HarnessToolBlockDemo,
          width: 80,
          height: 24,
          settle_ms: @settle_ms
        )

      names = session |> get_tools() |> Enum.map(& &1[:name])

      assert "tool_ok.toggle_fold" in names
      assert "tool_fail.toggle_fold" in names
      assert "tool_none.toggle_fold" in names

      stop_session(session)
    end

    test "invoking the derived tool flips the block's fold through the real seam" do
      session =
        start_session(HarnessToolBlockDemo,
          width: 80,
          height: 24,
          settle_ms: @settle_ms
        )

      assert %{blocks: %{tool_ok: %{fold: :folded}}} = get_model(session)

      call_tool(session, "tool_ok.toggle_fold", %{})

      assert %{blocks: %{tool_ok: %{fold: :expanded}}} = get_model(session)
      assert screenshot(session) =~ "42 tests, 0 failures"

      stop_session(session)
    end

    test "the StructuredScreenshot exposes the stamped block roots by id" do
      session =
        start_session(HarnessToolBlockDemo,
          width: 80,
          height: 24,
          settle_ms: @settle_ms
        )

      # The re-hosted block stamps its root :column with an id (the
      # U1-a/U1-b seam), so it is addressable in the widget summary.
      assert_component(session, "tool_ok", fn c -> c[:type] == :column end)
      assert_component(session, "tool_fail", fn c -> c[:type] == :column end)

      stop_session(session)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp start_headless do
    id = :"tool_demo_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(HarnessToolBlockDemo, id: id, width: 80, height: 24)

    Process.sleep(@settle_ms)
    id
  end

  defp screenshot!(id) do
    {:ok, text} = Headless.screenshot(id)
    text
  end

  defp line_with(text, substr) do
    text
    |> String.split("\n")
    |> Enum.find("", &String.contains?(&1, substr))
  end

  defp index_of(lines, substr) do
    Enum.find_index(lines, &String.contains?(&1, substr))
  end

  defp blank?(lines, index) when index >= 0 do
    case Enum.at(lines, index) do
      nil -> false
      line -> String.trim(line) == ""
    end
  end

  defp blank?(_lines, _index), do: false

  # The running (cargo) line begins at column 0 with the braille margin
  # glyph (every other row is margined 2 cells). The first grapheme of
  # that line IS the spinner frame.
  defp running_margin_glyph(text) do
    text
    |> line_with("cargo")
    |> String.graphemes()
    |> List.first()
  end

  defp first_child_style(view) do
    view |> Map.get(:children) |> List.first() |> Map.get(:style)
  end
end
