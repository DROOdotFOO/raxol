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

  ## Keyboard — two answer modes

  `:select` (the default, the standalone modal): Up/Down arrows and digit
  keys (`1`-`9`) move the selection; digits jump straight to that
  option's index rather than acting as a shortcut, so Enter is always
  the one and only way to confirm (a mis-timed digit key can't fire off
  a decision by itself). Enter emits the decision for whichever option
  is currently selected.

  `:direct` (`answer_mode: :direct`, the transcript approval BLOCK): the
  harness answer vocabulary, mirroring `Raxol.UI.Harness.Keymap`'s
  Track-D binds byte-for-byte — `y`/`n` alias the first allow/deny
  option, `1`-`9` pick the Nth option by position, and every recognized
  key emits the raw ANSWER HINT out as `{:approval_answer, %{answer:
  :allow | :deny | {:option, index}}}` (`index` 0-based, Keymap parity).
  The component is CONTROLLED (§2 of the TEA-migration doctrine: the
  Bubbler discards returned component state), so the decision rides the
  command channel and the owner's `update/2` applies it — resolving the
  hint against the block's real options and refusing honestly when it
  cannot (the retired `Raxol.Harness.Surface.resolve_approval_answer/2`
  on the old live path; `HarnessApp.Model` now, and the demo's update in
  the playground). Arrows and Enter are
  no-ops here: the block form has no selection cursor. Frontier holds,
  `needs_input`, and the answer-key guard are Surface/model-level and
  deliberately NOT this component's business — it renders and emits.

  ## MCP: the headless-approval story

  The module implements `Raxol.MCP.ToolProvider` over the node
  `Raxol.UI.Components.Harness.Block` stamps for an approval block
  (`type: :approval_prompt`, attrs carrying `seal`/`options`). A LIVE
  block derives answer tools built from the request's REAL options
  (affordance honesty — never a key the request does not offer):
  `answer_allow`/`answer_deny` only when an option of that class exists,
  `answer_option` with the exact `1..N` range. Each invocation dispatches
  the same answer key a human would press, so an MCP client answering an
  approval programmatically rides the identical seam as the keyboard. A
  sealed approval derives nothing — an answered question offers no keys.

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

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.BlastRadiusPreview
  alias Raxol.UI.Components.Modal.Rendering, as: ModalRendering
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @behaviour Raxol.MCP.ToolProvider

  @type answer_mode :: :select | :direct
  @type answer_hint :: :allow | :deny | {:option, non_neg_integer()}
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
          answer_mode: answer_mode(),
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
      id:
        Keyword.get(
          props,
          :id,
          "approval-prompt-#{:erlang.unique_integer([:positive])}"
        ),
      action: Keyword.get(props, :action, nil),
      blast_radius: Keyword.get(props, :blast_radius, %{}),
      options: Keyword.get(props, :options, @default_options),
      answer_mode: Keyword.get(props, :answer_mode, :select),
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
    handle_key(answer_mode(state), data, state)
  end

  def handle_event(_event, state, _context), do: {state, []}

  # :direct — the harness answer vocabulary (see the moduledoc). Emits the
  # raw hint unconditionally, exactly as the Keymap binds do: a digit past
  # the option list still emits `{:option, i}`, because refusing it
  # honestly (against the block's REAL options) is the owning model's
  # job, never this component's. Arrows/Enter fall through to :noop —
  # there is no selection cursor to move in the block form.
  defp handle_key(:direct, data, state) do
    case answer_hint(data) do
      nil -> {state, []}
      hint -> {state, [{:approval_answer, %{answer: hint}}]}
    end
  end

  # :select — the standalone modal's select-then-confirm vocabulary.
  defp handle_key(_select, data, state) do
    case classify_key(data) do
      :up -> {move_selection(state, -1), []}
      :down -> {move_selection(state, 1), []}
      {:jump, index} -> {select_index(state, index), []}
      :enter -> emit_decision(state)
      :noop -> {state, []}
    end
  end

  # Shape-tolerant mode read: a state built by `init/1` carries the mode
  # top-level; a node-built state (the Bubbler rebuilds component state
  # from the element map) carries it under `:attrs`, as
  # `Raxol.UI.Components.Harness.Block` stamps it. Absent either way, the
  # modal default applies.
  defp answer_mode(%{answer_mode: mode}), do: mode
  defp answer_mode(%{attrs: %{answer_mode: mode}}), do: mode
  defp answer_mode(_state), do: :select

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
  defp option_label(%{name: name}) when is_binary(name), do: name
  defp option_label(%{"name" => name}) when is_binary(name), do: name
  defp option_label(%{"label" => label}) when is_binary(label), do: label
  defp option_label(option) when is_binary(option), do: option
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

  # The :direct answer vocabulary, one-to-one with `Raxol.UI.Harness.Keymap`'s
  # Track-D binds: `y` -> :allow, `n` -> :deny, a digit -> `{:option, i}`
  # with `i` 0-BASED (Keymap uses `Enum.with_index/1` over "1".."9", so "3"
  # is index 2). Anything else -> nil (a no-op, no message out). The hint is
  # raw and unresolved: the owning model turns it into a concrete option_id
  # and refuses honestly if it can't.
  defp answer_hint(%{key: :char, char: "y"}), do: :allow
  defp answer_hint(%{key: :char, char: "n"}), do: :deny

  defp answer_hint(%{key: :char, char: char}) when char in @digit_chars,
    do: {:option, String.to_integer(char) - 1}

  defp answer_hint(%{key: "y"}), do: :allow
  defp answer_hint(%{key: "n"}), do: :deny

  defp answer_hint(%{key: key}) when is_binary(key) and key in @digit_chars,
    do: {:option, String.to_integer(key) - 1}

  defp answer_hint(_data), do: nil

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

  # -- MCP ToolProvider: the headless-approval story --------------------
  #
  # Derives answer tools from the LIVE approval NODE (the map
  # `Raxol.UI.Components.Harness.Block` stamps: `attrs.seal`,
  # `attrs.answer_mode`, `attrs.options`). Only a live, `:direct`-mode
  # block with real options is answerable; a sealed or select-mode block
  # derives nothing. Every offered tool is affordance-honest -- it exists
  # only when the request actually offers an option of that class, and
  # `answer_option`'s schema range is exactly the options present.

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(node) do
    attrs = tool_attrs(node)

    if answerable?(attrs) do
      build_answer_tools(options_of(attrs))
    else
      []
    end
  end

  # An answer is a programmatic answer key: `handle_tool_call` presses the
  # same key a human would (`y`/`n`/digit), returning it as the ONE event
  # a real keypress would generate, so the MCP path and the keyboard path
  # dispatch through the identical seam. Refuses -- never a phantom answer
  # -- when the approval is already sealed, the class has no option, or a
  # number is out of range.
  @impl Raxol.MCP.ToolProvider
  def handle_tool_call(action, args, %{widget_state: node}) do
    attrs = tool_attrs(node)

    case seal_of(attrs) do
      :sealed ->
        {:error, "this approval is already answered"}

      _live ->
        answer_call(action, args, options_of(attrs))
    end
  end

  def handle_tool_call(action, _args, _context),
    do: {:error, "unknown action: #{action}"}

  defp answer_call("answer_allow", _args, options) do
    press_class(options, :allow, "y")
  end

  defp answer_call("answer_deny", _args, options) do
    press_class(options, :deny, "n")
  end

  defp answer_call("answer_option", args, options) do
    n = length(options)

    case option_arg(args) do
      index when is_integer(index) and index >= 1 and index <= n ->
        option = Enum.at(options, index - 1)

        {:ok, "answer: #{option_label(option)} (#{index})",
         [key_press(Integer.to_string(index))]}

      index when is_integer(index) ->
        {:error, "option #{index} out of range (1-#{n})"}

      _absent ->
        {:error, "answer_option requires an :option number (1-#{n})"}
    end
  end

  defp answer_call(action, _args, _options),
    do: {:error, "unknown action: #{action}"}

  defp press_class(options, class, key) do
    case first_option_of_class(options, class) do
      nil ->
        {:error, "no #{class} option is offered by this approval"}

      option ->
        {:ok, "answer: #{option_label(option)} (#{key})", [key_press(key)]}
    end
  end

  # Builds the answer tools from the request's REAL options: `answer_allow`
  # /`answer_deny` only when an option of that class exists, `answer_option`
  # always (a live block has >= 1 option here), with a `1..N` schema and a
  # description naming every option (referent honesty).
  defp build_answer_tools(options) do
    [
      allow_tool(options),
      deny_tool(options),
      option_tool(options)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp allow_tool(options), do: class_tool(options, :allow, "answer_allow")
  defp deny_tool(options), do: class_tool(options, :deny, "answer_deny")

  defp class_tool(options, class, name) do
    case first_option_of_class(options, class) do
      nil ->
        nil

      option ->
        %{
          name: name,
          description: "Answer this approval: #{option_label(option)}",
          inputSchema: %{type: "object", properties: %{}}
        }
    end
  end

  defp option_tool(options) do
    n = length(options)
    labels = Enum.map_join(options, ", ", &option_label/1)

    %{
      name: "answer_option",
      description: "Answer by option number (1-#{n}): #{labels}",
      inputSchema: %{
        type: "object",
        properties: %{
          option: %{type: "integer", minimum: 1, maximum: n}
        },
        required: ["option"]
      }
    }
  end

  # A live, direct-mode block with at least one option is answerable.
  defp answerable?(attrs) do
    seal_of(attrs) == :live and
      Map.get(attrs, :answer_mode, :select) == :direct and
      options_of(attrs) != []
  end

  # Node-shape tolerant reads: a Block-stamped node carries these under
  # `:attrs`; a bare attrs map (as a caller/test may pass) is read directly.
  defp tool_attrs(%{attrs: attrs}) when is_map(attrs), do: attrs
  defp tool_attrs(node) when is_map(node), do: node
  defp tool_attrs(_node), do: %{}

  defp options_of(attrs), do: Map.get(attrs, :options, [])
  defp seal_of(attrs), do: Map.get(attrs, :seal)

  defp first_option_of_class(options, class),
    do: Enum.find(options, &(option_class(&1) == class))

  # An option's decision class, from its ACP `:kind` (allow_*/reject_*) or
  # a modal option's explicit `:decision`. Unknown -> nil, so it never
  # counts as either an allow or a deny affordance.
  defp option_class(%{kind: kind}), do: class_from_kind(kind)
  defp option_class(%{"kind" => kind}), do: class_from_kind(kind)
  defp option_class(%{decision: d}) when d in [:allow, :deny], do: d
  defp option_class(_option), do: nil

  defp class_from_kind(k)
       when k in [:allow_once, :allow_always, "allow_once", "allow_always"],
       do: :allow

  defp class_from_kind(k)
       when k in [:reject_once, :reject_always, "reject_once", "reject_always"],
       do: :deny

  defp class_from_kind(_kind), do: nil

  defp option_arg(args) when is_map(args) do
    case Map.get(args, "option", Map.get(args, :option)) do
      n when is_integer(n) -> n
      n when is_binary(n) -> parse_int(n)
      _other -> nil
    end
  end

  defp option_arg(_args), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp key_press(char),
    do: %Event{type: :key, data: %{key: :char, char: char}}
end
