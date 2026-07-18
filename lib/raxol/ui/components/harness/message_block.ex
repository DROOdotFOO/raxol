defmodule Raxol.UI.Components.Harness.MessageBlock do
  @moduledoc """
  Renders a completed transcript message: `item_completed{item_type: :message, content}`.

  `content` is a Markdown string. Body rendering is delegated entirely to
  `Raxol.UI.Components.Harness.MarkdownBody`, which adds a streaming-aware
  provisional close (`mode: :streaming`), control-char/ANSI sanitization,
  and a never-raise fallback on top of the plain Markdown parse -- this
  module only adds a dim, accent-colored role prefix
  (`role: :user | :assistant`) above it so turns are visually
  distinguishable without shouting. `render/2` is pure content -> view: no
  state of its own is read or written.

  The stable-prefix optimization (cache the parse of the durable prefix of
  a streaming message and only re-parse the live tail) is a documented
  follow-up seam in `MarkdownBody`, not implemented here.

  Behavioral note: sanitization applies in BOTH modes, so even a `:sealed`
  render of control-char-bearing content is intentionally NOT
  byte-identical to the old raw `MarkdownRenderer` parse -- control/ESC
  bytes are stripped, invalid UTF-8 is recovered. Clean content renders
  identically.
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.Components.Harness.MarkdownBody
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

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
      id: Ids.default_id(props, "harness-message-block"),
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
      children: [role_header(state), body]
    }
  end

  defp role_header(%{id: id, role: role}) do
    Components.text(
      id: "#{id}-role",
      content: "[#{role}]",
      style: %{dim: true, fg: role_accent(role)}
    )
  end

  defp role_accent(:user), do: :green
  defp role_accent(:assistant), do: :cyan
  defp role_accent(_), do: :white
end
