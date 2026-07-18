defmodule Raxol.UI.Components.Harness.ApprovalPrompt do
  @moduledoc """
  The agent-harness approval gate: shows what an action wants to do, its
  blast radius, and a keyboard-driven choice of how far to trust it.

  Render-dual of the harness protocol's approval exchange (see
  `docs/proposals/in-flight/harness-spec-frontend.md`, §4 row A6):

    * Payload in — `approval_requested{action, blast_radius, options}`,
      read by `init/1` as the `:action`, `:blast_radius`, `:options` props.
    * Emitted out — `approval_decision{decision, scope}`, returned as a
      command from `handle_event/3` in the shape
      `{:approval_decision, %{decision: :allow | :deny, scope: :once |
      :session | :root}}` once the user confirms with Enter.

  Built on `Raxol.UI.Components.Modal.Rendering.dialog_surface/4` -- the
  same one-box overlay shell `Modal` itself renders into -- rather than a
  second modal implementation. `render/2` embeds a
  `Raxol.UI.Components.Harness.BlastRadiusPreview` for the safety-critical
  part of the surface. The overlay *positioning* (centering, dimming the
  background) is the caller's job, same as `Modal`'s own demo: wrap this
  component's `render/2` result with
  `Raxol.UI.Components.AbsoluteLayer.dialog_overlay/3`, sized with
  `estimate_height/1`.

  ## Keyboard

  Up/Down arrows and digit keys (`1`-`9`) move the selection; digits jump
  straight to that option's index rather than acting as a shortcut, so
  Enter is always the one and only way to confirm (a mis-timed digit key
  can't fire off a decision by itself). Enter emits the decision for
  whichever option is currently selected.

  ## Default options

  Four choices, matching the harness spec's `:once/:session/:root` scopes
  (Devin's three-button pattern) plus deny:

    * Allow once     -> `%{decision: :allow, scope: :once}`
    * Allow session   -> `%{decision: :allow, scope: :session}`
    * Allow subtree   -> `%{decision: :allow, scope: :root}` -- `:root`
      covers this whole agent spawn subtree, not just the current agent.
    * Deny            -> `%{decision: :deny, scope: :once}` -- denial is
      inherently a single-decision act; there is no persistent "deny for
      session/subtree" concept in this gate, so it always carries the
      narrowest scope.

  None of the options carry inherent color-by-danger -- the only visual
  differentiator between rows is which one currently holds keyboard focus
  (reverse video, one row, per the `tui-design-science` skill's "one
  anchor per screen" rule). Danger lives entirely in the embedded
  `BlastRadiusPreview`, not in how "Deny" or "Allow" are painted, so the
  safe default is never visually fighting the destructive one.
  """

  alias Raxol.UI.Components.Harness.BlastRadiusPreview
  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.Components.Modal.Rendering, as: ModalRendering
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type scope :: :once | :session | :root
  @type option :: %{
          key: atom(),
          label: String.t(),
          decision: :allow | :deny,
          scope: scope()
        }

  @type t :: %{
          id: String.t() | atom(),
          action: term(),
          blast_radius: BlastRadiusPreview.blast_radius(),
          options: [option()],
          selected_index: non_neg_integer(),
          width: pos_integer(),
          style: map(),
          theme: map()
        }

  @default_options [
    %{key: :allow_once, label: "Allow once", decision: :allow, scope: :once},
    %{
      key: :allow_session,
      label: "Allow for session",
      decision: :allow,
      scope: :session
    },
    %{
      key: :allow_root,
      label: "Allow for agent subtree",
      decision: :allow,
      scope: :root
    },
    %{key: :deny, label: "Deny", decision: :deny, scope: :once}
  ]

  @default_width 60
  @frame_rows 4

  @nav_keys %{
    "Up" => :up,
    :up => :up,
    "Down" => :down,
    :down => :down,
    "Enter" => :enter,
    :enter => :enter
  }

  @digit_chars ~w(1 2 3 4 5 6 7 8 9)

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "approval-prompt"),
      action: Keyword.get(props, :action, nil),
      blast_radius: Keyword.get(props, :blast_radius, %{}),
      options: Keyword.get(props, :options, @default_options),
      selected_index: 0,
      width: Keyword.get(props, :width, @default_width),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(%{__struct__: _} = event, state, context),
    do: handle_event(Map.from_struct(event), state, context)

  def handle_event(%{type: :key, data: data}, state, _context)
      when is_map(data) do
    case classify_key(data) do
      :up -> {move_selection(state, -1), []}
      :down -> {move_selection(state, 1), []}
      {:jump, index} -> {select_index(state, index), []}
      :enter -> emit_decision(state)
      :noop -> {state, []}
    end
  end

  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    {:ok, blast_radius_state} =
      BlastRadiusPreview.init(
        id: "#{state.id}-blast-radius",
        blast_radius: state.blast_radius
      )

    blast_radius_view = BlastRadiusPreview.render(blast_radius_state, context)

    content = [
      Components.text(
        id: "#{state.id}-action",
        content: action_description(state.action),
        style: %{bold: true}
      ),
      blank_line(),
      blast_radius_view,
      blank_line(),
      Components.text(
        id: "#{state.id}-options-header",
        content: "Choose a response:",
        style: %{dim: true}
      )
      | option_rows(state)
    ]

    # gap: 0 is load-bearing: the layout engine defaults an unset gap to 1,
    # which doubles every row and overflows the fixed-height dialog surface.
    content_column = %{
      type: :column,
      style: %{width: :fill},
      gap: 0,
      children: content
    }

    ModalRendering.dialog_surface(
      state.width,
      estimate_height(state),
      box_style(state, context),
      [content_column]
    )
  end

  @doc """
  Structural line-count estimate of the prompt's total footprint height
  (frame + content), used to size the `dialog_surface/4` box this
  component renders into and, standalone, by callers positioning the
  overlay before calling `render/2` (e.g. `AbsoluteLayer.dialog_overlay/3`
  needs a matching height to center correctly). Generous by design, like
  `Raxol.UI.Components.Modal.Rendering.estimate_height/1`.
  """
  @spec estimate_height(t()) :: pos_integer()
  def estimate_height(state) do
    action_rows = 1
    options_header_rows = 1
    blast_rows = BlastRadiusPreview.estimate_rows(state.blast_radius)
    options_rows = length(state.options)
    # blank line after the action line, blank line after the blast radius
    spacer_rows = 2

    @frame_rows + action_rows + spacer_rows + blast_rows + options_header_rows +
      options_rows
  end

  # -- Rendering helpers --

  defp box_style(state, context) do
    base = StyleHelper.merge_component_styles(state, context, :approval_prompt)
    Map.merge(%{border: :double, align: :center}, base)
  end

  defp option_rows(state) do
    state.options
    |> Enum.with_index()
    |> Enum.map(fn {option, index} ->
      render_option(state.id, option, index, state.selected_index)
    end)
  end

  defp render_option(id, option, index, selected_index) do
    selected? = index == selected_index
    marker = if selected?, do: "▸", else: " "

    Components.text(
      id: "#{id}-option-#{index}",
      content: "#{marker} #{index + 1}. #{option_label(option)}",
      style: %{reverse: selected?}
    )
  end

  defp option_label(%{label: label}) when is_binary(label), do: label
  defp option_label(option), do: inspect(option)

  defp action_description(action) when is_binary(action) do
    case String.trim(action) do
      "" -> "Approval requested"
      trimmed -> trimmed
    end
  end

  defp action_description(%{} = action) do
    description =
      case Map.get(action, :description) do
        d when is_binary(d) and d != "" -> d
        _ -> "Approval requested"
      end

    case Map.get(action, :tool) do
      tool when is_binary(tool) and tool != "" -> "#{description} (via #{tool})"
      _ -> description
    end
  end

  defp action_description(_action), do: "Approval requested"

  defp blank_line, do: Components.text(content: "")

  # -- Keyboard handling --

  defp classify_key(%{key: :char, char: char}) when char in @digit_chars,
    do: {:jump, String.to_integer(char) - 1}

  defp classify_key(%{key: key}) when is_binary(key) and key in @digit_chars,
    do: {:jump, String.to_integer(key) - 1}

  defp classify_key(%{key: key}), do: Map.get(@nav_keys, key, :noop)
  defp classify_key(_data), do: :noop

  defp move_selection(state, delta) do
    last_index = max(length(state.options) - 1, 0)
    new_index = (state.selected_index + delta) |> max(0) |> min(last_index)
    %{state | selected_index: new_index}
  end

  defp select_index(state, index) do
    if index >= 0 and index < length(state.options) do
      %{state | selected_index: index}
    else
      state
    end
  end

  defp emit_decision(state) do
    case Enum.at(state.options, state.selected_index) do
      nil ->
        {state, []}

      option ->
        {state,
         [
           {:approval_decision,
            %{decision: option.decision, scope: option.scope}}
         ]}
    end
  end
end
