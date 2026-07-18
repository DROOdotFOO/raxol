defmodule Raxol.UI.Components.Harness.Indication do
  @moduledoc """
  The **indication container** — the harness's one left-edge layout
  primitive (V, 2026-07-18). Everything that touches the terminal's left
  border is an instance of this: the content sits at a 2-cell indent
  (column 2), and the **left bar** (column 0) is a single unit — a `gutter`
  strategy — that renders down the content's *full height*.

  This unifies every contour the harness draws:

    * speaker sigils (`❯` user / `❮` agent) — a `{:corners, sigil, nil}`
      gutter (top glyph only);
    * an expanded thought bracketed `∵` … `∴` — a `{:corners, "∵", "∴"}`
      gutter (top AND bottom glyph, one container spanning the block);
    * a persistent single marker — `{:top, glyph}` (a one-line thought keeps
      its icon for free);
    * a vertical range indicator — `{:rule, glyph}` (small dots down the
      whole gutter);
    * a plain indented block — `:none`.

  A NEW visual is a new gutter clause, never a structural change — that is
  the whole point of making the left bar one unit.

  ## Node shape

  `container/2` builds a `:indication` view node the `Raxol.UI.Layout.Engine`
  lays out directly (it mirrors `:absolute_layer`): the engine positions the
  content at column 2, measures its height, then stamps the gutter at column
  0 per the strategy. Because it is a real node (not a line transform), it is
  DevTools-inspectable and composable inside any container.

  ## Polymorphic content (one field, two speeds)

  `content` is either a **binary** (the fast path — the engine emits it as a
  single text node, no sub-tree to build or measure) or a **view node** (the
  rich path — laid out normally). A pre-formatted string carries its own
  line breaks (`\\n`); it is treated as already wrapped.
  """

  @typedoc "The left-bar strategy — how column 0 is drawn down the range."
  @type gutter ::
          :none
          | {:top, String.t()}
          | {:corners, String.t() | nil, String.t() | nil}
          | {:rule, String.t()}

  @typedoc "Fast path (binary) or rich path (view node)."
  @type content :: String.t() | map()

  @doc """
  Build an `:indication` node.

  Options:
    * `:gutter` — a `t:gutter/0` strategy (default `:none`)
    * `:gutter_style` — style map applied to every gutter glyph (default `%{}`)
    * `:id` — node id (for DevTools / MCP tree walking)
    * `:attrs` — extra semantic attrs merged into the node's `:attrs`
  """
  @spec container(content(), keyword()) :: map()
  def container(content, opts \\ []) do
    gutter = Keyword.get(opts, :gutter, :none)

    %{
      type: :indication,
      content: content,
      gutter: gutter,
      gutter_style: Keyword.get(opts, :gutter_style, %{}),
      id: Keyword.get(opts, :id),
      attrs:
        Map.merge(
          %{component_module: __MODULE__, gutter: gutter},
          Keyword.get(opts, :attrs, %{})
        )
    }
  end

  @doc "A speaker turn: `sigil` at the top-left corner, bold. (`❯`/`❮`.)"
  @spec speaker(content(), String.t(), keyword()) :: map()
  def speaker(content, sigil, opts \\ []) do
    container(
      content,
      Keyword.merge(
        [gutter: {:corners, sigil, nil}, gutter_style: %{bold: true}],
        opts
      )
    )
  end

  @doc "A bracketed range: `top` at the first row, `bottom` at the last, dim. (`∵`…`∴`.)"
  @spec bracket(content(), String.t(), String.t(), keyword()) :: map()
  def bracket(content, top, bottom, opts \\ []) do
    container(
      content,
      Keyword.merge(
        [gutter: {:corners, top, bottom}, gutter_style: %{dim: true}],
        opts
      )
    )
  end

  @doc "A vertical range rule: `glyph` down the whole gutter, dim."
  @spec rule(content(), String.t(), keyword()) :: map()
  def rule(content, glyph, opts \\ []) do
    container(
      content,
      Keyword.merge([gutter: {:rule, glyph}, gutter_style: %{dim: true}], opts)
    )
  end

  @doc "A plain 2-cell-indented block: no gutter glyphs."
  @spec plain(content(), keyword()) :: map()
  def plain(content, opts \\ []) do
    container(content, Keyword.merge([gutter: :none], opts))
  end
end
