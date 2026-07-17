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
  """

  alias Raxol.UI.Components.Harness.MarkdownBody
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type role :: :user | :assistant
  @type mode :: :sealed | :streaming

  @type t :: %{
          id: String.t() | atom(),
          role: role(),
          content: String.t(),
          width: pos_integer(),
          mode: mode(),
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
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_message_block)

    body =
      MarkdownBody.render(state.content, %{width: state.width, mode: state.mode})

    %{
      type: :column,
      style: base_style,
      gap: 0,
      children: [body]
    }
  end
end
