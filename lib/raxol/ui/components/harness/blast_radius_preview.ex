defmodule Raxol.UI.Components.Harness.BlastRadiusPreview do
  @moduledoc """
  Renders the blast radius of an agent-harness action: everything it will
  touch, grouped by effect kind, with destructive/irreversible effects made
  impossible to miss.

  Render-dual of the `blast_radius` field carried by the harness's
  `approval_requested` payload (see
  `docs/proposals/in-flight/harness-spec-frontend.md`, §4 row A6). Typically
  embedded inside `Raxol.UI.Components.Harness.ApprovalPrompt`, but stands
  alone for the playground and for testing.

  ## Props

    * `:blast_radius` - `%{writes: [path], deletes: [path], commands:
      [string], network: [host], reversible: boolean}`. Every key is
      optional; missing lists default to `[]`, missing `:reversible`
      defaults to `true` (a missing/absent flag is not itself a danger
      signal -- but deletes are still shown loud regardless, see below).

  ## Visual hierarchy

  Per the `tui-design-science` skill: hue carries *identity* (what kind of
  effect this is), weight carries *importance* (how much attention it
  needs) -- kept independent so red stays reserved for the one thing it
  means.

    * `:deletes` are always red + bold. Deleting earns a second look even
      inside an otherwise-reversible action.
    * `:commands` are yellow (caution -- unpredictable side effects),
      `:network` is cyan (informational -- reaching outside the sandbox),
      `:writes` carry no hue, just weight.
    * When `blast_radius.reversible == false`, every group loses its
      dim/default weight and renders bold -- nothing here is a "minor"
      effect anymore -- and a standalone `IRREVERSIBLE` marker leads the
      list, in red (the one other case the alarm hue is reserved for).
    * When `blast_radius.reversible == true`, `:commands` / `:network` /
      `:writes` render dim -- present, but not competing with the deletes
      group for attention.

  Every group is glyph-prefixed, not color-only, so the hierarchy survives
  for colorblind readers: `✗` delete, `▲` run, `ℹ` network, `•` write.
  """

  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type blast_radius :: %{
          optional(:writes) => [String.t()],
          optional(:deletes) => [String.t()],
          optional(:commands) => [String.t()],
          optional(:network) => [String.t()],
          optional(:reversible) => boolean()
        }

  @type t :: %{
          id: String.t() | atom(),
          blast_radius: blast_radius(),
          style: map(),
          theme: map()
        }

  @groups [
    {:deletes, "Delete", "✗", :red, true},
    {:commands, "Run", "▲", :yellow, false},
    {:network, "Network", "ℹ", :cyan, false},
    {:writes, "Write", "•", nil, false}
  ]

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "blast-radius-preview-#{:erlang.unique_integer([:positive])}"
        ),
      blast_radius: Keyword.get(props, :blast_radius, %{}),
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
      StyleHelper.merge_component_styles(state, context, :blast_radius_preview)

    br = state.blast_radius
    reversible = Map.get(br, :reversible, true)

    sections =
      [
        marker_section(state.id, reversible)
        | group_sections(state.id, br, reversible)
      ]
      |> Enum.reject(&is_nil/1)

    children =
      case sections do
        [] ->
          [Components.text(content: "No tracked effects.", style: %{dim: true})]

        list ->
          list |> Enum.intersperse(blank_line()) |> List.flatten()
      end

    # gap: 0 is load-bearing: the layout engine defaults an unset gap to 1,
    # which would double every row; section spacing is the explicit
    # interspersed blank lines, counted by estimate_rows/1.
    %{type: :column, style: base_style, gap: 0, children: children}
  end

  @doc """
  Structural row-count estimate of this preview's rendered height (content
  rows only -- no outer frame/padding), for callers that need to size an
  enclosing overlay before `render/2` has run (see
  `Raxol.UI.Components.Harness.ApprovalPrompt.estimate_height/1`). Generous
  by design, mirroring `Raxol.UI.Components.Modal.Rendering.estimate_height/1`.
  """
  @spec estimate_rows(blast_radius()) :: pos_integer()
  def estimate_rows(blast_radius) do
    reversible = Map.get(blast_radius, :reversible, true)
    marker? = not reversible

    groups =
      Enum.map(@groups, fn {key, _label, _glyph, _color, _always} ->
        Map.get(blast_radius, key, [])
      end)

    non_empty = Enum.count(groups, &(&1 != []))
    item_rows = Enum.reduce(groups, 0, fn items, acc -> acc + length(items) end)
    section_count = non_empty + bool_to_int(marker?)
    gap_rows = max(section_count - 1, 0)

    case section_count do
      0 -> 1
      _ -> bool_to_int(marker?) + non_empty + item_rows + gap_rows
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp marker_section(_id, true), do: nil

  defp marker_section(id, false) do
    [
      Components.text(
        id: "#{id}-irreversible",
        content: "⚠ IRREVERSIBLE — this action cannot be undone",
        fg: :red,
        style: %{bold: true}
      )
    ]
  end

  defp group_sections(id, blast_radius, reversible) do
    Enum.map(@groups, fn {key, label, glyph, color, always_loud} ->
      group_section(
        id,
        key,
        label,
        glyph,
        color,
        Map.get(blast_radius, key, []),
        always_loud,
        reversible
      )
    end)
  end

  defp group_section(
         _id,
         _key,
         _label,
         _glyph,
         _color,
         [],
         _always_loud,
         _reversible
       ),
       do: nil

  defp group_section(
         id,
         key,
         label,
         glyph,
         color,
         items,
         always_loud,
         reversible
       ) do
    loud? = always_loud or not reversible

    header =
      Components.text(
        id: "#{id}-#{key}-header",
        content: "#{glyph} #{label} (#{length(items)})",
        fg: color,
        style: %{bold: loud?}
      )

    item_nodes =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        render_item(id, key, item, index, color, loud?)
      end)

    [header | item_nodes]
  end

  defp render_item(id, key, item, index, color, loud?) do
    Components.text(
      id: "#{id}-#{key}-#{index}",
      content: "  #{item}",
      fg: if(loud?, do: color, else: nil),
      style: %{dim: not loud?}
    )
  end

  defp blank_line, do: Components.text(content: "")
end
