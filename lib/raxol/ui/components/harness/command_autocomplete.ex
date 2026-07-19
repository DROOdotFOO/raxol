defmodule Raxol.UI.Components.Harness.CommandAutocomplete do
  @moduledoc """
  The slash-command autocomplete POPUP (V's contract: renders on top of
  the existing layer with an explicit background, no global backdrop —
  a popup, not a dialog). Focus never leaves the composer: Up/Down move
  the popup's SELECTION, Tab completes the draft, Enter executes — the
  host owns those keys; this component is pure state + render.

  ## Controlled (§2 doctrine)

  Derived state only: the candidate list is
  `Raxol.UI.Harness.CommandRegistry.match/1` of the current query — the
  popup can never show a command the registry would not run (shown =
  provable). The host re-supplies the query on every draft change
  (`set_query/2` resets the selection); `move/2` clamps at the
  boundaries (no wrap-around — the arrow grammar every harness widget
  speaks).

  ## Render

  One row per candidate, `/name` left and the description right, every
  cell carrying the explicit popup background; the selected row takes
  the brighter background + bold name, unselected rows sit at the faded
  register. `height/1` and `width/1` are exposed so the host can anchor
  the popup's bottom edge directly above the composer row.
  """

  alias Raxol.UI.Harness.{CommandRegistry, Prominence}
  alias Raxol.UI.TextMeasure

  use Raxol.UI.Components.Base.Component

  @max_rows 6
  @default_width 44
  @low_prominence 0.5
  @chrome_fg "#B4B4B4"
  # The explicit popup background pair — base plane + selected row.
  @bg "#262626"
  @bg_selected "#3A3A3A"

  @type t :: %{
          id: String.t() | atom(),
          query: String.t(),
          selected: non_neg_integer(),
          width: pos_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    {:ok,
     %{
       id:
         Map.get(
           props,
           :id,
           "harness-command-autocomplete-#{:erlang.unique_integer([:positive])}"
         ),
       query: Map.get(props, :query, ""),
       selected: 0,
       width: Map.get(props, :width, @default_width),
       style: Map.get(props, :style, %{}),
       theme: Map.get(props, :theme, %{})
     }}
  end

  @doc "The candidates for the current query (window-capped for render)."
  @spec matches(t()) :: [CommandRegistry.entry()]
  def matches(%{query: query}), do: CommandRegistry.match(query)

  @doc "New query (the host's draft changed) — the selection resets."
  @spec set_query(t(), String.t()) :: t()
  def set_query(state, query) when is_binary(query),
    do: %{state | query: query, selected: 0}

  @doc "Move the selection by ±1, clamped at the ends (no wrap-around)."
  @spec move(t(), -1 | 1) :: t()
  def move(state, delta) when delta in [-1, 1] do
    count = length(matches(state))
    %{state | selected: clamp(state.selected + delta, count)}
  end

  @doc "The selected entry, or nil when nothing matches."
  @spec selected_entry(t()) :: CommandRegistry.entry() | nil
  def selected_entry(state) do
    entries = matches(state)
    Enum.at(entries, min(state.selected, max(length(entries) - 1, 0)))
  end

  @doc """
  The Tab completion for the selected entry — `"/name "` for a command
  that takes text (park the caret before the args), `"/name"` otherwise.
  Nil when nothing matches.
  """
  @spec completion(t()) :: String.t() | nil
  def completion(state) do
    case selected_entry(state) do
      nil -> nil
      %{name: name, args: :text} -> "/" <> name <> " "
      %{name: name} -> "/" <> name
    end
  end

  @doc "Rendered popup height in rows (window-capped)."
  @spec height(t()) :: non_neg_integer()
  def height(state), do: state |> visible_window() |> length()

  @doc "The popup's display width."
  @spec width(t()) :: pos_integer()
  def width(state), do: state.width

  # A container has no keys of its own — the host routes Up/Down/Tab/
  # Enter itself (focus stays in the composer, V's contract).
  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, _context) do
    faded = Prominence.resolve(@chrome_fg, @low_prominence)
    window = visible_window(state)

    %{
      type: :column,
      id: state.id,
      attrs: %{kind: :command_autocomplete, component_module: __MODULE__},
      style: state.style,
      gap: 0,
      children:
        Enum.map(window, fn {entry, index} ->
          entry_row(entry, index == state.selected, state.width, faded)
        end)
    }
  end

  # The visible window: the selection is always inside it (scroll the
  # window, never lose the highlighted row).
  defp visible_window(state) do
    entries = matches(state) |> Enum.with_index()
    total = length(entries)

    start =
      cond do
        total <= @max_rows -> 0
        state.selected < @max_rows -> 0
        true -> min(state.selected - @max_rows + 1, total - @max_rows)
      end

    Enum.slice(entries, start, @max_rows)
  end

  defp entry_row(entry, selected?, width, faded) do
    bg = if selected?, do: @bg_selected, else: @bg
    name = "/" <> entry.name

    name_style =
      if selected?, do: %{bold: true, bg: bg}, else: %{fg: faded, bg: bg}

    desc_style = %{dim: true, fg: faded, bg: bg}

    name_w = TextMeasure.display_width(name)
    desc = "  " <> entry.description
    pad = max(width - name_w - TextMeasure.display_width(desc), 0)

    %{
      type: :row,
      style: %{},
      gap: 0,
      children: [
        %{type: :text, content: name, style: name_style},
        %{type: :text, content: desc, style: desc_style},
        # background fill to the popup's right edge — the explicit
        # background must read as a plane, not a text-shaped smear
        %{type: :text, content: String.duplicate(" ", pad), style: %{bg: bg}}
      ]
    }
  end

  defp clamp(_value, 0), do: 0
  defp clamp(value, count), do: value |> max(0) |> min(count - 1)
end
