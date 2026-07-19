defmodule Raxol.UI.Components.Harness.ChoicePrompt do
  @moduledoc """
  The chevron choice prompt: a confirm/cancel pair PLUS a free-text
  third way, every row fronted by the dialogue chevron (V's ruling: when
  a question is live the chevron is preserved — extended, never
  replaced).

  ```
  ❯ confirm [enter]                 ← label quiet, hint bold
  ❯ cancel [escape]                 ← label quiet, hint bold
  ❯ ▏explain what to do instead     ← chevron high prominence, caret at
                                      the start, placeholder low
  ```

  ## The key contract

    * **Idle (empty draft).** The `[enter]` / `[escape]` hints show on
      the option rows and mean exactly what they say: Enter confirms,
      Escape cancels — from anywhere.
    * **Typing (non-empty draft).** The hints DISAPPEAR (the keys are
      repurposed): Enter submits the draft, Escape clears it (hints
      return). Shift/Alt+Enter inserts a newline — the free-text way is
      a real multi-line composer (`Raxol.UI.Components.Harness.Composer`
      is the edit substrate: WrapMap wrapping, readline chords).
    * **Arrows.** Up/Down move focus `confirm ⇅ cancel ⇅ input`. Inside
      a multi-line draft the arrows navigate the TEXT first; only at the
      boundary do they hop out — Up on the draft's first visual row
      lands on `cancel`, then `confirm`, and stops (no wrap-around).
    * **Typing from an option row** refocuses the input and inserts —
      the free-text way is never more than one keystroke away.
    * **Enter on an option row** activates that option.

  ## Prominence

  The focused row's chevron is bold at full strength — and so are the
  `[enter]`/`[escape]` key hints: they are the answer affordances and
  must read at a glance (V's ruling). Everything discretionary —
  unfocused rows, the placeholder — sits at the faded low-prominence
  register sealed machinery uses
  (`Raxol.UI.Harness.Prominence.resolve/3`): the question and its ways
  out are the loud part, the rest is quiet until chosen.

  ## Controlled (§2 doctrine)

  State in via props, commands out — the component never acts on its
  own answer. Emitted commands (the `Composer` convention):

    * `{:component_event, id, :confirm}`
    * `{:component_event, id, :cancel}`
    * `{:component_event, id, {:submit, text}}`

  The draft is left intact on submit — the host owns the lifecycle
  (usually it unmounts the prompt on any of the three).

  ## Cursor (law 6)

  `edit_point/2` lowers the caret for the host's root `:cursor` key:
  component-relative `{row, col}` (0-based row, 1-based display col,
  chevron cells included) when the input row holds focus, `nil` when an
  option row does (a parked caret would point at state the keys don't
  reach).
  """

  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.{InputEvent, Prominence}

  use Raxol.UI.Components.Base.Component

  @sigil "❯"
  @sigil_cols 2
  @low_prominence 0.5
  @chrome_fg "#B4B4B4"
  @default_width 60

  @type focus :: :confirm | :cancel | :input

  @type t :: %{
          id: String.t() | atom(),
          composer: Composer.t(),
          focus: focus(),
          width: pos_integer(),
          confirm_label: String.t(),
          cancel_label: String.t(),
          placeholder: String.t(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    id =
      Map.get(
        props,
        :id,
        "harness-choice-prompt-#{:erlang.unique_integer([:positive])}"
      )

    width = Map.get(props, :width, @default_width)

    {:ok, composer} =
      Composer.init(
        id: "#{id}-composer",
        width: max(width - @sigil_cols, 1),
        focused: true,
        value: Map.get(props, :value, "")
      )

    {:ok,
     %{
       id: id,
       composer: composer,
       focus: :input,
       width: width,
       confirm_label: Map.get(props, :confirm_label, "confirm"),
       cancel_label: Map.get(props, :cancel_label, "cancel"),
       placeholder: Map.get(props, :placeholder, "explain what to do instead"),
       style: Map.get(props, :style, %{}),
       theme: Map.get(props, :theme, %{})
     }}
  end

  @doc "Current draft text (delegates to the embedded Composer)."
  @spec value(t()) :: String.t()
  def value(state), do: Composer.value(state.composer)

  @doc """
  The caret for the host's root `:cursor` key — `{row, col}` relative to
  this component's first row (0-based row; 1-based display column,
  chevron cells included), or `nil` when an option row holds focus.
  """
  @spec edit_point(t(), pos_integer() | nil) ::
          {non_neg_integer(), pos_integer()} | nil
  def edit_point(state, avail_width \\ nil)

  def edit_point(%{focus: :input} = state, avail_width) do
    {row, col} =
      Composer.edit_point(state.composer, text_width(state, avail_width))

    {2 + row, col + @sigil_cols}
  end

  def edit_point(_state, _avail_width), do: nil

  # ── events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event(event, state, context) do
    norm = InputEvent.normalize(event)

    cond do
      norm.kind == :paste ->
        forward_to_input(event, state, context)

      InputEvent.key(norm) == :up ->
        navigate_up(event, state, context)

      InputEvent.key(norm) == :down ->
        navigate_down(event, state, context)

      InputEvent.key(norm) == :enter ->
        handle_enter(norm, event, state, context)

      InputEvent.key(norm) == :escape ->
        handle_escape(state)

      InputEvent.text?(norm) ->
        forward_to_input(event, state, context)

      state.focus == :input ->
        forward(event, state, context)

      true ->
        {state, []}
    end
  end

  # -- arrows: text first, boundary hop second (never wrap) --------------

  defp navigate_up(_event, %{focus: :confirm} = state, _ctx), do: {state, []}

  defp navigate_up(_event, %{focus: :cancel} = state, _ctx),
    do: {%{state | focus: :confirm}, []}

  defp navigate_up(event, %{focus: :input} = state, context) do
    {row, _col} = Composer.edit_point(state.composer, text_width(state, nil))

    if row == 0 do
      {%{state | focus: :cancel}, []}
    else
      forward(event, state, context)
    end
  end

  defp navigate_down(_event, %{focus: :confirm} = state, _ctx),
    do: {%{state | focus: :cancel}, []}

  defp navigate_down(_event, %{focus: :cancel} = state, _ctx),
    do: {%{state | focus: :input}, []}

  # Inside the draft Down navigates the text; the composer clamps at the
  # last visual row itself (its history recall never engages — this
  # component routes Enter itself, so the composer's history stays
  # empty). There is nothing below the input row to hop to.
  defp navigate_down(event, %{focus: :input} = state, context),
    do: forward(event, state, context)

  # -- enter / escape ------------------------------------------------------

  # Shift/Alt+Enter authors a newline in the draft (the multi-line way);
  # on an option row it is meaningless and ignored.
  defp handle_enter(%{mods: %{shift: true}}, event, state, context),
    do: newline_or_ignore(event, state, context)

  defp handle_enter(%{mods: %{alt: true}}, event, state, context),
    do: newline_or_ignore(event, state, context)

  defp handle_enter(_norm, _event, %{focus: :confirm} = state, _ctx),
    do: {state, [emit(state, :confirm)]}

  defp handle_enter(_norm, _event, %{focus: :cancel} = state, _ctx),
    do: {state, [emit(state, :cancel)]}

  defp handle_enter(_norm, _event, %{focus: :input} = state, _ctx) do
    text = value(state)

    if String.trim(text) == "" do
      {state, [emit(state, :confirm)]}
    else
      {state, [emit(state, {:submit, text})]}
    end
  end

  defp newline_or_ignore(event, %{focus: :input} = state, context),
    do: forward(event, state, context)

  defp newline_or_ignore(_event, state, _context), do: {state, []}

  # Escape: a non-empty draft clears (the hints return); an empty one
  # cancels — exactly what the `[escape]` hint on the cancel row claims.
  defp handle_escape(state) do
    if value(state) == "" do
      {state, [emit(state, :cancel)]}
    else
      {%{
         state
         | composer: Composer.set_value(state.composer, ""),
           focus: :input
       }, []}
    end
  end

  # -- forwarding ----------------------------------------------------------

  # Typing (or pasting) from anywhere lands in the draft: refocus the
  # input if an option row held focus, then forward to the composer.
  defp forward_to_input(event, state, context),
    do: forward(event, %{state | focus: :input}, context)

  defp forward(event, state, context) do
    {composer, _cmds} = Composer.handle_event(event, state.composer, context)
    {%{state | composer: composer}, []}
  end

  defp emit(state, event), do: {:component_event, state.id, event}

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    tw = text_width(state, context[:available_width])
    faded = Prominence.resolve(@chrome_fg, @low_prominence)
    empty? = value(state) == ""

    %{
      type: :column,
      id: state.id,
      attrs: %{kind: :choice_prompt, component_module: __MODULE__},
      style: state.style,
      gap: 0,
      children:
        [
          option_row(
            state.confirm_label,
            "[enter]",
            state.focus == :confirm,
            empty?,
            faded
          ),
          option_row(
            state.cancel_label,
            "[escape]",
            state.focus == :cancel,
            empty?,
            faded
          )
        ] ++ input_rows(state, tw, empty?, faded)
    }
  end

  # An option row: chevron + label (+ the key hint while the draft is
  # empty). The focused row's chevron is bold full-strength and its label
  # full-strength; an unfocused row sits at the faded register. The hint
  # is ALWAYS bold full-strength — it is the answer affordance and must
  # be visible at a glance (V's ruling), whichever row holds focus.
  defp option_row(label, hint, focused?, show_hint?, faded) do
    {sigil_style, label_style} =
      if focused? do
        {%{bold: true}, %{}}
      else
        {%{dim: true, fg: faded}, %{dim: true, fg: faded}}
      end

    hint_segment =
      if show_hint?,
        do: [%{type: :text, content: " " <> hint, style: %{bold: true}}],
        else: []

    %{
      type: :row,
      style: %{},
      gap: 0,
      children:
        [
          %{type: :text, content: @sigil <> " ", style: sigil_style},
          %{type: :text, content: label, style: label_style}
        ] ++ hint_segment
    }
  end

  # The input row(s): chevron + draft (or the quiet placeholder). A
  # multi-line draft hangs its continuation rows at the content indent,
  # the composer-row convention.
  defp input_rows(state, tw, empty?, faded) do
    sigil_style =
      if state.focus == :input,
        do: %{bold: true},
        else: %{dim: true, fg: faded}

    if empty? do
      [
        %{
          type: :row,
          style: %{},
          gap: 0,
          children: [
            %{type: :text, content: @sigil <> " ", style: sigil_style},
            %{
              type: :text,
              content: state.placeholder,
              style: %{dim: true, fg: faded}
            }
          ]
        }
      ]
    else
      state.composer
      |> Composer.visual_lines(tw)
      |> Enum.with_index()
      |> Enum.map(fn
        {line, 0} ->
          %{
            type: :row,
            style: %{},
            gap: 0,
            children: [
              %{type: :text, content: @sigil <> " ", style: sigil_style},
              %{type: :text, content: line, style: %{}}
            ]
          }

        {line, _index} ->
          %{
            type: :row,
            style: %{},
            gap: 0,
            children: [
              %{type: :text, content: "  ", style: %{}},
              %{type: :text, content: line, style: %{}}
            ]
          }
      end)
    end
  end

  defp text_width(state, avail_width),
    do: max((avail_width || state.width) - @sigil_cols, 1)
end
