defmodule Raxol.UI.Components.Harness.MessageBlock do
  @moduledoc """
  Renders a completed transcript message: `item_completed{item_type: :message, content}`.

  `content` is a Markdown string. Body rendering is delegated entirely to
  `Raxol.UI.Components.Harness.MarkdownBody`, which adds a streaming-aware
  provisional close (`mode: :streaming`), control-char/ANSI sanitization,
  and a never-raise fallback on top of the plain Markdown parse. `render/2`
  is pure content -> view: no state of its own is read or written.

  ## Speaker separation (prompt-echo rhythm, no tagline)

  Both roles render as BARE prose -- there is no `[assistant]`/`[user]`
  tagline row (killed by the speaker-separation ruling: it was
  role-COLORED, violating doctrine §4.1 "color encodes state, never
  speaker", and spent a row saying something the turn rhythm already
  says). Authorship is carried by the prompt-echo grammar instead:

    * `:assistant` -- unmarked prose after a blank turn-separator row
      (the machine's voice dominates the log and goes unmarked);
    * `:user` -- the composer's chevron sigil echoed into history,
      `❯ text`, applied at `Raxol.Harness.Surface`'s margin/chevron seam
      -- NOT here. The sigil is a per-capability decision (`unicode:
      :none` degrades it to `>`) owned by the surface, the echo must be
      byte-aligned with the composer's live prompt row (same sigil
      source, so echo and prompt can never drift), and a bold sigil next
      to normal-weight user text is two styles on one physical line --
      only the surface's post-`ViewText` string seam can compose that
      (`ViewText.lines/3` is one-line-per-leaf-text-node by contract).

  This module therefore renders the same body-only view for both roles;
  `role` stays in state as the honest speaker record (threaded from
  `Block.extract_content/2` via `BodyProvider`) for surfaces that read
  component state rather than sealed bytes.

  The stable-prefix optimization (cache the parse of the durable prefix of
  a streaming message and only re-parse the live tail) is a documented
  follow-up seam in `MarkdownBody`, not implemented here.

  Behavioral note: sanitization applies in BOTH modes, so even a `:sealed`
  render of control-char-bearing content is intentionally NOT
  byte-identical to the old raw `MarkdownRenderer` parse -- control/ESC
  bytes are stripped, invalid UTF-8 is recovered. Clean content renders
  identically.

  ## Controlled fold vocabulary (harness TEA migration U1-a)

  This component is CONTROLLED (migration doc §2 doctrine): state in via
  props, events out as messages, no `ComponentManager`. It owns no fold
  state -- folded rendering is `Block.render/2`'s seat (and the future
  TranscriptBlock's). What it owns is the fold *vocabulary*: `z` (today's
  transcript fold key, Keymap `char: "z" -> :fold_toggle`) plus
  Enter/Space (`ReasoningBlock`/Tree activation-key precedent) emit the
  wired `:on_toggle` prop as an outgoing message and leave the state
  untouched; the hosting model decides what folding means. A modified
  chord (ctrl/alt) never toggles. With no `:on_toggle` wired every fold
  key is a no-op, exactly the old stateless behavior.

  ## TreeWalker stamping + MCP toggle (F0-mcp seam)

  The rendered root carries `id`, role-invariant `attrs` (`kind`, `mode`,
  and the `component_module` marker `Raxol.MCP.TreeWalker` resolves
  providers through), and `on_click: on_toggle`. The ToolProvider
  callbacks derive one `toggle` semantic action -- only when `on_toggle`
  is actually wired (an unwired block advertises nothing) -- and execute
  it exactly like `Button`: a widget-targeted `%Event{type: :click}` the
  Dispatcher bubbles at this node, so the MCP toggle and a physical click
  dispatch the same `:on_click` message.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.MarkdownBody
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @behaviour Raxol.MCP.ToolProvider

  @type role :: :user | :assistant
  @type mode :: :sealed | :streaming

  @type t :: %{
          id: String.t() | atom(),
          role: role(),
          content: String.t(),
          width: pos_integer(),
          mode: mode(),
          on_toggle: term() | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "harness-message-block-#{:erlang.unique_integer([:positive])}"
        ),
      role: Keyword.get(props, :role, :assistant),
      content: Keyword.get(props, :content, ""),
      width: Keyword.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      mode: Keyword.get(props, :mode, :sealed),
      on_toggle: Keyword.get(props, :on_toggle),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Fold vocabulary: z (transcript fold key) + Enter/Space (activation
  # keys). Controlled: no local state flips -- the wired :on_toggle
  # message is emitted out (empty command list when unwired).
  @impl true
  def handle_event(
        %Event{type: :key, data: %{key: :char, char: "z"} = data},
        state,
        _context
      ) do
    if modified?(data), do: {state, []}, else: {state, toggle_commands(state)}
  end

  def handle_event(%Event{type: :key, data: %{key: key}}, state, _context)
      when key in [:enter, :space] do
    {state, toggle_commands(state)}
  end

  def handle_event(_event, state, _context), do: {state, []}

  defp modified?(data) do
    Map.get(data, :ctrl, false) == true or Map.get(data, :alt, false) == true
  end

  defp toggle_commands(%{on_toggle: nil}), do: []
  defp toggle_commands(%{on_toggle: message}), do: [message]

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_message_block)

    body =
      MarkdownBody.render(state.content, %{width: state.width, mode: state.mode})

    %{
      type: :column,
      id: state.id,
      # Role-invariant on purpose: speaker grammar (the ❯/❮ sigil margin)
      # belongs to the hosting view, never to this node's identity -- the
      # render-equality-across-roles pin depends on it.
      attrs: %{
        kind: :message,
        mode: state.mode,
        component_module: __MODULE__
      },
      on_click: state.on_toggle,
      style: base_style,
      gap: 0,
      children: [body]
    }
  end

  # -- ToolProvider callbacks (mirrors Button's) ---------------------------

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{on_click: handler}) when not is_nil(handler) do
    [
      %{
        name: "toggle",
        description: "Fold or expand the message block",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  def mcp_tools(_node), do: []

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("toggle", _args, context) do
    # Resolved by the Dispatcher through the Bubbler at this widget, so
    # the node's :on_click message dispatches exactly as for a real click.
    {:ok, "Toggled '#{context.widget_id}'",
     [%Event{type: :click, data: %{widget_id: context.widget_id}}]}
  end

  def handle_tool_call(action, _args, _context),
    do: {:error, "Unknown action: #{action}"}
end
