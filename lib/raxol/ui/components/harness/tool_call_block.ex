defmodule Raxol.UI.Components.Harness.ToolCallBlock do
  @moduledoc """
  Renders one tool invocation from the harness protocol stream.

  Render-dual of the event pair `item_started{item_id, item_type: :tool_use}`
  followed by `item_completed{item_type: :tool_use, content: %{name, args}}`
  (see `docs/proposals/in-flight/harness-spec-protocol.md` sec 3, family
  `:loop`). It is a pure projection of `name` + `args` + `status` -- it holds
  no protocol state of its own; the caller re-inits or updates props as the
  envelope's events arrive (`:pending` on `item_started`, then `:running`,
  landing on `:done`/`:failed` when `item_completed` closes the item).

  Renders as one row: a status glyph, the tool name (bold), and a compact,
  width-bounded rendering of `args`.
  """

  alias Raxol.UI.Components.Progress.Spinner
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextMeasure

  use Raxol.UI.Components.Base.Component

  @type status :: :pending | :running | :done | :failed

  @type t :: %{
          id: String.t() | atom(),
          name: String.t(),
          args: map() | String.t(),
          status: status(),
          frame: non_neg_integer(),
          style: map(),
          theme: map()
        }

  # Compact-args are meant to be a glanceable summary, not the full payload;
  # bound their display width rather than let one huge tool arg blow out the row.
  @max_args_width 60

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "tool-call-#{:erlang.unique_integer([:positive])}"
        ),
      name: Keyword.get(props, :name, ""),
      args: Keyword.get(props, :args, %{}),
      status: Keyword.get(props, :status, :pending),
      frame: Keyword.get(props, :frame, 0),
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
      StyleHelper.merge_component_styles(state, context, :tool_call_block)

    row_style = Map.put_new(base_style, :gap, 1)

    {glyph, color} = status_glyph(state.status, state.frame)
    args_label = compact_args(state.args)

    children =
      [
        Raxol.View.Components.text(
          id: "#{state.id}-glyph",
          content: glyph,
          style: %{fg: color}
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-name",
          content: state.name,
          style: %{bold: true}
        )
      ] ++ args_children(state.id, args_label)

    %{type: :row, style: row_style, gap: 1, children: children}
  end

  @doc """
  Glyph and colour for a tool-call/tool-result status.

  `:running` returns a spinner-frame character (reuses
  `Raxol.UI.Components.Progress.Spinner`'s frame table so a caller driving
  `frame` from a tick subscription gets real animation); `:done` is a green
  check, `:failed` a red cross; anything else (including `:pending`) falls
  back to a neutral marker.
  """
  @spec status_glyph(status(), non_neg_integer()) :: {String.t(), atom()}
  def status_glyph(:running, frame),
    do: {Spinner.spinner(nil, frame, type: :dots), :cyan}

  def status_glyph(:done, _frame), do: {"✓", :green}
  def status_glyph(:failed, _frame), do: {"✗", :red}
  def status_glyph(_status, _frame), do: {"○", :white}

  @doc """
  Formats `args` (a map or a preformatted string) into a compact,
  width-bounded single-line summary suitable for an inline row.
  """
  @spec compact_args(map() | String.t()) :: String.t()
  def compact_args(args) when is_binary(args), do: truncate(args)
  def compact_args(args) when is_map(args) and map_size(args) == 0, do: ""

  def compact_args(args) when is_map(args) do
    args
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> wrap_parens()
    |> truncate()
  end

  def compact_args(_args), do: ""

  defp args_children(_id, ""), do: []

  defp args_children(id, label) do
    [
      Raxol.View.Components.text(
        id: "#{id}-args",
        content: label,
        style: %{dim: true}
      )
    ]
  end

  defp wrap_parens(text), do: "(" <> text <> ")"

  defp truncate(text) do
    if TextMeasure.display_width(text) > @max_args_width do
      {left, _rest} =
        TextMeasure.split_at_display_width(text, @max_args_width - 1)

      left <> "…"
    else
      text
    end
  end
end
