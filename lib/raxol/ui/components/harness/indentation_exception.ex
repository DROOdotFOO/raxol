defmodule Raxol.UI.Components.Harness.IndentationException do
  @moduledoc """
  The explicit escape hatch from the indication law (V's general rule):
  **every transcript body record renders inside an
  `Raxol.UI.Components.Harness.Indication` container — or inside this
  wrapper.** There is no third state; an unwrapped record is a bug the
  transcript's normalizer refuses to paint silently.

  The wrapper is deliberately content-free chrome: the LayoutEngine lays
  its `content` out exactly where the wrapper sits (no indent, no
  gutter, full width). Its whole value is the DECLARATION — a reviewer
  grepping `IndentationException` finds every full-bleed surface in the
  transcript, and a new widget cannot skip the icon-column convention by
  accident, only by writing this name.

  Legitimate exceptions today:

    * the Pierre diff rows (an approval's proposed image / an expanded
      `:diff` body) — the gutter bars and line numbers ARE the diff's
      own left contour; double-gutter would misalign the panes;
    * pad/blank rows the window inserts (not records at all).

  Everything else — dialogue, machinery lines, thoughts, markers —
  speaks `Indication`.
  """

  @doc "Wrap `content` as a declared full-bleed transcript record."
  @spec wrap(map(), keyword()) :: map()
  def wrap(content, opts \\ []) when is_map(content) do
    %{
      type: :indentation_exception,
      content: content,
      id: Keyword.get(opts, :id),
      attrs: %{component_module: __MODULE__}
    }
  end
end
