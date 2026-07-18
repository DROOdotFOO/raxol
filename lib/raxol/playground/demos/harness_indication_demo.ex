defmodule Raxol.Playground.Demos.HarnessIndicationDemo do
  @moduledoc """
  Playground demo: the **indication container**
  (`Raxol.UI.Components.Harness.Indication`) — the harness's one left-edge
  layout primitive. Content sits at column 2; the left bar (column 0) is a
  single `gutter` strategy rendered down the content's full height. Every
  harness contour is a parametrization of this node:

    * `❯`/`❮` speaker sigils — `{:corners, sigil, nil}` (top glyph only);
    * `∵`…`∴` thought bracket — `{:corners, "∵", "∴"}` (first + last row);
    * a vertical range rule — `{:rule, "·"}` (every row);
    * a plain indented block — `:none`.

  It is a real LayoutEngine node (`:indication`), so it is
  DevTools-inspectable and composable, and its content is polymorphic — a
  binary (fast path) or a view node (rich path), both shown below.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.Indication

  @impl true
  def init(_context), do: %{}

  @impl true
  def update(_message, model), do: {model, []}

  @impl true
  def view(_model) do
    column style: %{gap: 1} do
      [
        text("Indication Container — the harness left-edge primitive",
          style: [:bold]
        ),
        text("gutter at column 0 · content at column 2", style: [:dim]),
        caption("{:corners, \"❯\", nil} — speaker (top-left glyph only)"),
        Indication.speaker("user turn — the sigil marks the outer contour", "❯"),
        Indication.speaker("agent turn — ❮ is the mirrored inverse", "❮"),
        caption("{:corners, \"∵\", \"∴\"} — a bracketed range (first + last row)"),
        Indication.bracket(
          "a thought spanning\nseveral lines:\n∵ opens (premises)\n∴ closes (conclusion)",
          "∵",
          "∴"
        ),
        caption("{:rule, \"·\"} — a vertical range indicator (every row)"),
        Indication.rule(
          "dots run down the\nwhole gutter to mark\nthe span as one unit",
          "·"
        ),
        caption(":none — a plain 2-cell-indented block"),
        Indication.plain("no gutter glyphs, just the indent column"),
        caption("polymorphic content — a view NODE, not a string:"),
        Indication.bracket(node_content(), "∵", "∴")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp caption(str), do: text(str, style: [:dim])

  # Content that is a real sub-tree rather than a preformatted string; the
  # gutter still spans its laid-out height exactly.
  defp node_content do
    column style: %{gap: 0} do
      [
        text("first child (a bold node)", style: [:bold]),
        text("second child"),
        text("third child")
      ]
    end
  end
end
