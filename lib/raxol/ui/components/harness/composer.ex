defmodule Raxol.UI.Components.Harness.Composer do
  @moduledoc """
  Harness prompt composer: wraps `Raxol.UI.Components.Input.MultiLineInput`
  with harness-specific submit semantics, input history recall, bracketed
  paste fidelity, and a queued-steer banner. Does not reimplement multi-line
  editing -- cursor movement, selection, and text mutation stay entirely in
  MultiLineInput; this module only decides *when* those primitives fire and
  adds one banner above the prompt.

  ## Submit semantics

  Enter with no modifiers submits (`{:component_event, id, {:submit, text}}`)
  when the buffer is a single logical line (no embedded `\\n`, regardless of
  visual wrap) and non-empty after trimming. Enter with `:shift` or `:alt`
  held, or Enter while the buffer already spans multiple logical lines
  (continuation), inserts a literal newline instead via MultiLineInput's own
  `{:enter}` message. `force_submit/1` is exposed for a consumer (T12
  keybinds) to wire an unconditional submit key (e.g. Ctrl+Enter) that
  bypasses the single-line gate.

  **Legacy terminals and the degraded-mode inlet:** many terminals do not
  encode Shift+Enter or Alt+Enter distinctly (Alt+Enter arrives as ESC CR
  and the ESC is dropped in parsing -- a bare Enter is all this component
  sees), so the modifier branches are unreachable there. The
  modifier-independent primary inlet to a first newline is **backslash
  continuation**: a line ending in `\\` + Enter consumes the backslash and
  inserts a newline instead of submitting. This works over tmux/SSH/mosh
  at any point, including creating the very first newline. Escape rule
  (simplest that round-trips a literal trailing backslash): count the
  trailing backslash run -- an odd run means continuation (the final
  backslash is consumed, the rest stay as typed); an even run means submit
  with the run halved (`\\\\` submits as `\\`). The rule applies only on
  the Enter-submit path; `force_submit/1` and paste submit/insert content
  verbatim. Bracketed paste and a consumer-wired `force_submit/1` remain
  alternate inlets. (An earlier first-focus hint line advertising these
  inlets was removed by V's charged-minimum ruling -- it said nothing the
  first Enter doesn't teach, and the boot frame carries identity, not
  instructions.) The modifier branches activate automatically when F1b
  (kitty keyboard protocol) lands -- zero logic change here.

  ## Input-shape normalization

  `handle_event/3` normalizes every incoming event through
  `Raxol.UI.Harness.InputEvent.normalize/1` before deciding anything.
  Before T27's review round this component matched key events by pattern
  (`%{key: :enter, modifiers: modifiers}`), which only exists on
  `Event.key_event/3`'s test-API shape -- the real terminal driver's two
  shapes (`event_translator.ex`'s boolean `shift:`/`ctrl:`/... fields,
  `input_parser.ex`'s optional fields) have no `:modifiers` key at all, so
  the pattern never matched a REAL keypress. Enter never submitted,
  printable characters never inserted, and everything silently fell
  through to raw `MultiLineInput` delegation for actual terminal input --
  this unit only ever worked in tests that construct `Event.key_event/3`
  directly. `InputEvent.normalize/1` erases that shape difference: Enter
  from a real termbox driver, a real ANSI parser, or `Event.key_event/3`
  all normalize to the same `kind: :key, key: :enter` and reach the same
  `handle_enter_key/2`.

  Printable characters arriving with compound modifiers (e.g. Shift+Alt)
  are `InputEvent.shortcut?/1` (alt held) and fall through to
  `MultiLineInput` delegation, same as before -- canonical compound-
  modifier handling belongs to F1a input canon, not this unit.

  ## Bracketed paste

  The terminal driver already parses `ESC[200~...ESC[201~` into
  `%Raxol.Core.Events.Event{type: :paste, data: %{text: text}}`
  (`Raxol.Terminal.Ansi.InputParser`). This component routes that event
  straight into MultiLineInput's `{:clipboard_content, text}` message -- the
  same path Ctrl+V system-clipboard paste already uses
  (`MultiLineInput.SelectionOps.handle_clipboard_content/2`) -- so pasted
  newlines are inserted verbatim in one edit and never pass through the
  Enter/submit decision above, no matter how many lines the paste contains.

  ## Editing model: logical truth, visual projection

  The embedded MultiLineInput is the EDIT SUBSTRATE and always runs
  `wrap: :none`: its `lines` are the logical `"\\n"`-split lines of the
  draft, its `cursor_pos` a logical `{row, grapheme col}`. Every edit
  (insert/backspace/delete/left/right/home/end) operates on that logical
  truth. Display wrapping is derived ONE-WAY per render/park through
  `Raxol.UI.Components.Harness.Composer.WrapMap` (content-preserving
  `TextLayout` `:pre_wrap`) and never written back -- see that module
  for the corruption class this rules out.

  ## Editing chords (readline vocabulary)

  Word- and line-level editing uses the READLINE chords that actually
  reach a terminal application, computed on the logical draft (word
  boundaries on the logical string, grapheme/`TextMeasure` aware, never
  on the visual projection):

  | Action                | Chords                                             |
  | --------------------- | -------------------------------------------------- |
  | Word left             | Alt+Left, Ctrl+Left, `ESC b` (Option+b as Meta)    |
  | Word right            | Alt+Right, Ctrl+Right, `ESC f` (Option+f as Meta)  |
  | Delete word back      | Ctrl+W, Alt/Option+Backspace (`ESC DEL`)           |
  | Kill to line start    | Ctrl+U                                             |
  | Kill to line end      | Ctrl+K                                             |
  | Line start            | Ctrl+A, Home                                        |
  | Line end              | Ctrl+E, End                                         |

  Word motion skips whitespace then a word run (symmetric both
  directions); at a logical line edge it crosses the newline (word-left
  at column 0 goes to the end of the previous logical line, word-right at
  end-of-line to the start of the next). Delete-word-back removes exactly
  what word-left would skip -- including the joining newline when the
  cursor sits at column 0. Kill-to-start/end operate on the CURRENT
  logical line only (a multi-line backslash-continued draft keeps its
  other lines).

  **macOS Cmd-chord reality:** Cmd+Left/Right/Backspace are almost always
  intercepted by the terminal emulator (Terminal.app, iTerm) and never
  reach this application at all -- confirmed against `InputParser`, they
  deliver no bytes on a default macOS terminal. The readline family above
  is the portable fix and what muscle memory falls back to. Where a
  terminal IS configured to forward a Cmd chord (iTerm can be), Cmd is the
  `meta` modifier and is aliased here: Cmd+Left -> line start, Cmd+Right
  -> line end, Cmd+Backspace -> kill-to-line-start.

  ## History recall + vertical navigation

  Up/Down move the cursor across the wrapped VISUAL rows of the draft
  (goal-column rule, display cells). Up at the first visual row walks a
  bounded ring (default 100) of past submissions, newest first; Down at
  the last visual row while browsing walks back. The in-progress draft
  is saved on the first recalling Up so Down can restore it.
  Shift+Up/Down still forwards to MultiLineInput (shift-selection over
  logical lines).

  ## Queued-steer banner

  `queued_steer: nil | %{text: String.t(), queued_at: term()}` renders (when
  set) one dim, truncated line above the prompt, prefixed with "⏸ " --
  `⏸ steer queued for next boundary: <text>` -- visually distinct from
  editable content. This is AD-2's two-signal model (interrupt vs. steer)
  made visible.

  ## Resize safety

  No absolute width is persisted on this struct. `render/2` derives
  MultiLineInput's width from `context[:available_width]` on every call and
  re-wraps the cached lines for that width, so a resized `context` produces
  a correctly-wrapped prompt without any stored width going stale.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Composer.WrapMap
  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Components.Input.MultiLineInput.RenderHelper
  alias Raxol.UI.FocusHelper
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @default_width 80
  @default_height 3
  @default_max_history 100
  @default_wrap :word
  @steer_prefix "⏸ steer queued for next boundary: "

  @type queued_steer :: %{text: String.t(), queued_at: term()} | nil

  @type t :: %{
          id: String.t() | atom(),
          mli: MultiLineInput.t(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t() | nil,
          queued_steer: queued_steer(),
          max_history: pos_integer(),
          wrap: :none | :char | :word,
          goal_col: non_neg_integer() | nil,
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
        "harness-composer-#{:erlang.unique_integer([:positive])}"
      )

    # The embedded MultiLineInput is the EDIT SUBSTRATE and is always
    # `wrap: :none`: its `lines` are the logical `"\n"`-split lines of
    # the draft and its `cursor_pos` a logical {row, grapheme col} --
    # the single source of truth every edit operates on. Display
    # wrapping is the composer's job (`state.wrap` + `WrapMap`), derived
    # one-way at render/park time and never stored back. Before this
    # split the substrate itself carried display-wrapped lines, and the
    # word-wrapper's whitespace trimming corrupted the draft on every
    # rewrap (V's field repro: " ab" + Backspace x2 deleted the SPACE,
    # not the 'a' -- see the WrapMap moduledoc).
    {:ok, mli} =
      MultiLineInput.init(%{
        id: "#{id}-input",
        value: Map.get(props, :value, ""),
        placeholder: Map.get(props, :placeholder, ""),
        width: Map.get(props, :width, @default_width),
        height: Map.get(props, :height, @default_height),
        wrap: :none,
        focused: Map.get(props, :focused, true)
      })

    state = %{
      id: id,
      mli: mli,
      history: [],
      history_index: nil,
      draft: nil,
      queued_steer: Map.get(props, :queued_steer),
      max_history: Map.get(props, :max_history, @default_max_history),
      wrap: Map.get(props, :wrap, @default_wrap),
      goal_col: nil,
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # -- public helpers (used by consumers: T12 keybinds, T25 editor handoff) --

  @doc "Current composer text (delegates to the wrapped MultiLineInput)."
  @spec value(t()) :: String.t()
  def value(%{mli: %{value: text}}), do: text

  @doc "Replace the composer's content programmatically (e.g. after $EDITOR)."
  @spec set_value(t(), String.t()) :: t()
  def set_value(state, text), do: %{state | mli: set_mli_value(state.mli, text)}

  @doc "Bounded, newest-first list of past submissions."
  @spec history(t()) :: [String.t()]
  def history(%{history: history}), do: history

  @doc """
  The composer's edit point within the lines `render/2` produces at
  `avail_width`: `{row_offset, col}` -- 0-based row offset counted from
  the composer's own first rendered line (the queued-steer banner, when
  present, occupies row 0), 1-based display column.

  This is the terminal-cursor park target for an assembling surface
  (`Raxol.Harness.Surface.paint_footer/1` -> `InlineAuthority`'s
  `:cursor` option): the native cursor sits where the next typed
  grapheme lands. The point is the LOGICAL cursor projected through the
  same `WrapMap` `render/2` derives its rows from -- exact for
  mid-draft positions (after arrow navigation, Home/End, visual
  up/down), not just for end-of-draft typing. Columns are display
  cells (`Raxol.UI.TextMeasure`, CJK/emoji double-width), never
  `String.length/1`; a typed space advances the park because the wrap
  is content-preserving (`TextLayout` `:pre_wrap`), with no trimmed-line
  compensation needed.
  """
  @spec edit_point(t(), pos_integer()) ::
          {non_neg_integer(), pos_integer()}
  def edit_point(state, avail_width)
      when is_integer(avail_width) and avail_width > 0 do
    %{map: map, vrow: vrow, gcol: gcol, vscroll: vscroll} =
      visual_geometry(state, avail_width)

    banner = if state.queued_steer, do: 1, else: 0
    row = banner + (vrow - vscroll)
    col = min(WrapMap.cell_col(map, {vrow, gcol}) + 1, avail_width)

    {row, max(col, 1)}
  end

  @doc """
  The draft's visual rows as plain strings at `avail_width` -- the same
  content-preserving `WrapMap` projection `render/2` and `edit_point/2`
  derive from, so a host rendering the composer as footer line elements on
  the TEA path (LayoutEngine leaves, one `%{type: :text}` node per string)
  stays byte-aligned with `edit_point/2`'s row/col arithmetic.

  This is the seam that lets the composer be hosted by
  `Raxol.UI.Components.Harness.FooterStack` (which measures + fits line
  lists) and lets a `view/1` declare the caret via the F0-cursor root
  `:cursor` key: the host renders these rows, then parks the cursor at
  `edit_point/2`. `render/2`'s own tree (a `:column` of `:row`-of-text
  elements) is substrate-neutral -- ViewText joins each row into one
  line, the LayoutEngine lays it out natively -- but it renders the
  SCROLLED window with cursor/selection runs; this function is the
  plain-strings variant a TEA host feeds `FooterStack` directly.

  A queued-steer banner, when present, is the first row (matching
  `edit_point/2`'s banner accounting). An empty, unfocused draft with a
  placeholder returns the placeholder row (mirrors `render/2`'s placeholder
  branch); otherwise an empty draft is one empty row -- the caret's home.
  Returns the FULL draft (unscrolled); for the short drafts a footer
  composer shows this equals the rendered window (`vscroll` is 0).
  """
  @spec visual_lines(t(), pos_integer()) :: [String.t()]
  def visual_lines(state, avail_width)
      when is_integer(avail_width) and avail_width > 0 do
    mli = state.mli

    if mli.value == "" and not mli.focused and mli.placeholder != "" do
      [truncate_to_width(mli.placeholder, avail_width)]
    else
      banner =
        case state.queued_steer do
          %{text: text} ->
            [truncate_to_width(@steer_prefix <> text, avail_width)]

          _ ->
            []
        end

      map = WrapMap.build(mli.value, avail_width, state.wrap)
      banner ++ WrapMap.lines(map)
    end
  end

  @doc """
  Syncs the edit substrate's stored width -- the width event-time
  projections (visual up/down, history-recall gating) measure against.
  `render/2` and `edit_point/2` always re-derive at the caller-supplied
  width; a resizing consumer calls this so the event-time map agrees
  with what is on screen.
  """
  @spec set_width(t(), integer()) :: t()
  def set_width(state, width) when is_integer(width) and width > 0 do
    %{state | mli: %{state.mli | width: width}}
  end

  def set_width(state, _width), do: state

  @doc """
  Unconditional submit, bypassing the single-line gate -- for a consumer
  keybind (e.g. Ctrl+Enter) that must submit multi-line content directly.
  Returns `{state, []}` unchanged if the trimmed buffer is empty.
  """
  @spec force_submit(t()) :: {t(), [term()]}
  def force_submit(state) do
    text = value(state)

    if String.trim(text) == "" do
      {state, []}
    else
      submit(state, text)
    end
  end

  @impl true
  def update({:set_queued_steer, queued_steer}, state) do
    {%{state | queued_steer: queued_steer}, []}
  end

  def update(props, state) when is_map(props) do
    # :value/:placeholder/:focused describe the embedded MultiLineInput, not
    # the composer map itself -- forward them into the mli (buffer truth)
    # instead of letting merge_props stamp them onto the outer state where
    # they would silently desync from what the input actually contains.
    {mli_props, rest} = Map.split(props, [:value, :placeholder, :focused])

    state =
      if map_size(mli_props) > 0 do
        %{state | mli: sync_mli_props(state.mli, mli_props)}
      else
        state
      end

    Raxol.UI.Components.Base.Component.merge_props(rest, state)
  end

  def update(_msg, state), do: {state, []}

  defp sync_mli_props(mli, props) do
    mli =
      case Map.fetch(props, :value) do
        {:ok, value} -> set_mli_value(mli, value)
        :error -> mli
      end

    struct(mli, Map.take(props, [:placeholder, :focused]))
  end

  # -- events --

  # Migration pattern documented at `Raxol.UI.Harness.InputEvent`'s
  # moduledoc: normalize first, check `shortcut?/1` before `text?/1`/
  # `key/1` (so a modifier-qualified char/key still reaches the right
  # handler WITH its mods), paste short-circuits everything. Enter is
  # special-cased ahead of the generic shortcut/text/key triage because
  # its submit-vs-newline decision depends on mods (shift/alt) rather than
  # being a plain pass/fail shortcut check -- both `handle_shortcut/4`
  # (Alt+Enter, which IS classified `shortcut?`) and the `key` branch
  # (plain Enter, Shift+Enter, neither of which is) route back into the
  # same `handle_enter_key/2`.
  @impl true
  def handle_event(%Event{} = event, state, context) do
    norm = InputEvent.normalize(event)
    {new_state, cmds} = handle_normalized(norm, event, state, context)
    {maybe_reset_goal(new_state, norm), cmds}
  end

  def handle_event(event, state, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli, goal_col: nil}, cmds}
  end

  defp handle_normalized(norm, event, state, context) do
    cond do
      norm.kind == :paste ->
        {new_mli, _cmds} =
          update_mli({:clipboard_content, norm.text}, state.mli)

        {%{state | mli: new_mli}, []}

      InputEvent.shortcut?(norm) ->
        handle_shortcut(norm, state, event, context)

      InputEvent.text?(norm) ->
        insert_char(state, InputEvent.printable_char(norm))

      key = InputEvent.key(norm) ->
        dispatch_key(key, norm.mods, state, event, context)

      true ->
        {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
        {%{state | mli: new_mli}, cmds}
    end
  end

  # The visual up/down goal column survives only consecutive plain
  # up/down presses (the standard goal-column rule: horizontal movement
  # or any edit re-anchors it). Every other event clears it.
  defp maybe_reset_goal(state, %{kind: :key, key: key, mods: mods})
       when key in [:up, :down] do
    if mods.ctrl or mods.alt or mods.meta or mods.shift do
      %{state | goal_col: nil}
    else
      state
    end
  end

  defp maybe_reset_goal(state, _norm), do: %{state | goal_col: nil}

  # Alt+Enter is `shortcut?` (alt held) but is still "insert a newline",
  # not a generic keyboard shortcut -- recognize it here and fall back to
  # the same `handle_enter_key/2` the unmodified/Shift+Enter path in
  # `dispatch_key/5` uses. No other composer-level shortcuts exist today;
  # a consumer (T12 keybinds) wires additional ones (e.g. Ctrl+Enter via
  # `force_submit/1`) outside this component, so anything else
  # ctrl/alt/meta-qualified falls through to MultiLineInput (e.g. Ctrl+C,
  # Ctrl+V, which it already owns).
  defp handle_shortcut(%{key: :enter, mods: mods}, state, _event, _context) do
    handle_enter_key(mods, state)
  end

  # -- readline editing chords (see moduledoc "Editing chords") --------
  #
  # All operate on the LOGICAL draft. Left/Right special keys carry the
  # modifier (Alt/Ctrl = word motion, Meta/Cmd = line motion); the
  # char-shape chords (Ctrl+W/U/K/A/E, ESC-b/ESC-f) arrive as `kind:
  # :char` with the modifier held. Anything not in the vocabulary falls
  # through to MultiLineInput (Ctrl+C/V/X/Z/Y stay its own).

  defp handle_shortcut(%{key: :left, mods: mods}, state, event, context) do
    cond do
      mods.ctrl or mods.alt -> word_left(state)
      mods.meta -> line_start(state)
      true -> delegate(event, state, context)
    end
  end

  defp handle_shortcut(%{key: :right, mods: mods}, state, event, context) do
    cond do
      mods.ctrl or mods.alt -> word_right(state)
      mods.meta -> line_end(state)
      true -> delegate(event, state, context)
    end
  end

  defp handle_shortcut(%{key: :backspace, mods: mods}, state, event, context) do
    cond do
      mods.alt -> delete_word_back(state)
      mods.meta -> kill_to_line_start(state)
      true -> delegate(event, state, context)
    end
  end

  defp handle_shortcut(
         %{kind: :char, char: char, mods: mods},
         state,
         event,
         context
       ) do
    dispatch_readline_char(char, mods, state, event, context)
  end

  defp handle_shortcut(_norm, state, event, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli}, cmds}
  end

  # The char-shape readline chords. Alt+b/Alt+f are readline's word-jump
  # (`ESC b`/`ESC f`, the modifier-independent inlet that survives every
  # terminal); Ctrl+W/U/K/A/E are the control-byte family. Anything else
  # (Ctrl+C/V/X/Z/Y, ...) delegates to MultiLineInput unchanged.
  defp dispatch_readline_char("b", %{alt: true}, state, _e, _c),
    do: word_left(state)

  defp dispatch_readline_char("f", %{alt: true}, state, _e, _c),
    do: word_right(state)

  defp dispatch_readline_char("w", %{ctrl: true}, state, _e, _c),
    do: delete_word_back(state)

  defp dispatch_readline_char("u", %{ctrl: true}, state, _e, _c),
    do: kill_to_line_start(state)

  defp dispatch_readline_char("k", %{ctrl: true}, state, _e, _c),
    do: kill_to_line_end(state)

  defp dispatch_readline_char("a", %{ctrl: true}, state, _e, _c),
    do: line_start(state)

  defp dispatch_readline_char("e", %{ctrl: true}, state, _e, _c),
    do: line_end(state)

  defp dispatch_readline_char(_char, _mods, state, event, context),
    do: delegate(event, state, context)

  defp insert_char(state, nil), do: {state, []}

  # Routed through `{:clipboard_content, char}` -- the same safe insertion
  # path bracketed paste uses -- rather than MultiLineInput's own
  # `{:input, <binary>}` dispatch, which expects an integer codepoint
  # (`<<codepoint::utf8>>`) and crashes on ordinary keystrokes (kept out of
  # this changeset; MultiLineInput is outside T11's write-set). Also
  # correctly handles multi-codepoint graphemes (emoji) that the upstream
  # `byte_size == 1` dispatch drops entirely.
  defp insert_char(state, char) do
    {new_mli, cmds} = update_mli({:clipboard_content, char}, state.mli)
    {%{state | mli: new_mli}, cmds}
  end

  # Reached only when `shortcut?/1` was false, so ctrl/alt/meta are all
  # false here -- only `mods.shift` varies (e.g. Shift+Enter, Shift+Up).
  defp dispatch_key(:enter, mods, state, _event, _context) do
    handle_enter_key(mods, state)
  end

  defp dispatch_key(:up, mods, state, event, context) do
    if mods.shift do
      delegate(event, state, context)
    else
      handle_vertical(:up, state)
    end
  end

  defp dispatch_key(:down, mods, state, event, context) do
    if mods.shift do
      delegate(event, state, context)
    else
      handle_vertical(:down, state)
    end
  end

  defp dispatch_key(_key, _mods, state, event, context),
    do: delegate(event, state, context)

  defp delegate(event, state, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli}, cmds}
  end

  # -- render --

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    avail_width = context[:available_width] || state.mli.width

    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_composer)

    children =
      [
        queued_steer_banner(state.queued_steer, avail_width),
        render_input(state, avail_width, context)
      ]
      |> Enum.reject(&is_nil/1)

    # Stamp the root column with id + semantic attrs (harness TEA migration
    # U2, §4 footer row): the composer becomes an identified node in the
    # `view/1` tree so time-travel, the StructuredScreenshot semantic tree,
    # and the TreeWalker can find it -- the same seam MessageBlock/Block
    # carry. `component_module` marks the provider type; no `on_click` (the
    # composer is driven by typed keys + Enter, not a click-toggle). Its
    # edit-point caret reaches the pipeline via the host's root `:cursor`
    # declaration (F0-cursor seam), computed from `edit_point/2` -- see §5
    # law 6.
    %{
      type: :column,
      id: state.id,
      attrs: %{
        kind: :composer,
        component_module: __MODULE__
      },
      style: base_style,
      gap: 0,
      children: children
    }
  end

  # The draft rendered ONE-WAY through the wrap map: visual rows derived
  # from the logical value at `avail_width`, the logical cursor (and any
  # selection endpoints) projected onto them, the scroll window derived
  # -- nothing here is ever written back to the edit substrate. Each
  # visual row IS `RenderHelper.render_line/4`'s own element -- a `:row`
  # of styled `:text` segments -- the direct declaration both substrates
  # speak: `ViewText`'s inline-`:row` rule joins the segments into one
  # collected line, and the LayoutEngine lays the same row out natively.
  defp render_input(state, avail_width, context) do
    mli = state.mli
    focused = FocusHelper.focused?(mli.id, context) or mli.focused

    merged_theme =
      Map.merge(
        Map.get(context[:theme] || %{}, :multi_line_input, %{}),
        mli.theme || %{}
      )

    if mli.value == "" and not focused and mli.placeholder != "" do
      %{
        type: :column,
        style: merged_theme,
        children: [
          Components.text(
            content: mli.placeholder,
            style: %{color: merged_theme[:placeholder_color] || :gray}
          )
        ]
      }
    else
      render_draft_rows(state, mli, focused, merged_theme, avail_width)
    end
  end

  defp render_draft_rows(state, mli, focused, merged_theme, avail_width) do
    %{map: map, vrow: vrow, gcol: gcol, vscroll: vscroll, height: height} =
      visual_geometry(state, max(avail_width, 1))

    display = %{
      mli
      | width: max(avail_width, 1),
        lines: WrapMap.lines(map),
        cursor_pos: {vrow, gcol},
        scroll_offset: {vscroll, 0},
        focused: focused,
        selection_start: project_selection(map, mli.selection_start),
        selection_end: project_selection(map, mli.selection_end)
    }

    rows =
      display.lines
      |> Enum.slice(vscroll, height)
      |> Enum.with_index(vscroll)
      |> Enum.map(fn {line, index} ->
        RenderHelper.render_line(index, line, display, %{
          components: %{multi_line_input: merged_theme}
        })
      end)

    %{type: :column, style: merged_theme, children: rows}
  end

  defp project_selection(_map, nil), do: nil
  defp project_selection(map, pos), do: WrapMap.to_visual(map, pos)

  # -- private: enter / submit --

  defp handle_enter_key(%{shift: shift, alt: alt}, state) do
    cond do
      shift or alt -> insert_newline(state)
      multiline?(state.mli) -> insert_newline(state)
      true -> maybe_submit(state)
    end
  end

  defp multiline?(mli), do: String.contains?(mli.value, "\n")

  defp insert_newline(state) do
    {new_mli, cmds} = update_mli({:enter}, state.mli)
    {%{state | mli: new_mli}, cmds}
  end

  # Enter-submit path only: backslash continuation is the
  # modifier-independent inlet to a newline (see moduledoc). An odd trailing
  # backslash run means "continue" (consume the final backslash, insert a
  # newline); an even run submits with the run halved so a literal trailing
  # backslash is expressible as `\\`.
  defp maybe_submit(state) do
    text = value(state)

    cond do
      String.trim(text) == "" -> {state, []}
      continuation?(text) -> apply_continuation(state, text)
      true -> submit(state, collapse_trailing_escapes(text))
    end
  end

  defp continuation?(text), do: rem(trailing_backslashes(text), 2) == 1

  defp collapse_trailing_escapes(text) do
    case trailing_backslashes(text) do
      0 -> text
      n -> String.slice(text, 0, String.length(text) - div(n, 2))
    end
  end

  defp trailing_backslashes(text) do
    text
    |> String.reverse()
    |> String.graphemes()
    |> Enum.take_while(&(&1 == "\\"))
    |> length()
  end

  # Builds the continued value directly (base minus the consumed backslash,
  # plus a newline) and derives `lines` by logical split, preserving the
  # trailing empty line. Deliberately NOT routed through MultiLineInput's
  # re-init/ensure_cursor_visible: its split_into_lines drops a trailing
  # empty line (upstream bug (2) in the commit body), which would strand the
  # cursor past the line list and lose the just-created newline on the next
  # edit.
  defp apply_continuation(state, text) do
    base = String.slice(text, 0, String.length(text) - 1)
    new_value = base <> "\n"
    lines = String.split(new_value, "\n")

    mli = %{
      state.mli
      | value: new_value,
        lines: lines,
        cursor_pos: {length(lines) - 1, 0},
        selection_start: nil,
        selection_end: nil
    }

    {%{state | mli: mli}, []}
  end

  defp submit(state, text) do
    history = Enum.take([text | state.history], state.max_history)
    fresh_mli = set_mli_value(state.mli, "")

    new_state = %{
      state
      | mli: fresh_mli,
        history: history,
        history_index: nil,
        draft: nil
    }

    {new_state, [{:component_event, state.id, {:submit, text}}]}
  end

  # -- private: visual vertical navigation + history recall --
  #
  # Up/Down move the LOGICAL cursor across the wrapped VISUAL rows of
  # the draft (goal-column rule: the first vertical press anchors a
  # display-cell column, later presses aim for it, clamped per row --
  # `maybe_reset_goal/2` clears it on anything non-vertical). Only Up
  # at the very first visual row recalls history, and only Down at the
  # very last visual row while already browsing recalls newer -- so
  # mid-draft navigation never swaps the buffer out from under the
  # cursor. Widths: event-time projections use the substrate's stored
  # width (`set_width/2` keeps it synced to the rendered width).

  defp handle_vertical(:up, state) do
    geometry = visual_geometry(state, state.mli.width)

    cond do
      geometry.vrow > 0 ->
        move_to_visual_row(state, geometry, geometry.vrow - 1)

      state.history != [] ->
        recall_older(state)

      true ->
        {state, []}
    end
  end

  defp handle_vertical(:down, state) do
    geometry = visual_geometry(state, state.mli.width)

    cond do
      geometry.vrow < geometry.rows - 1 ->
        move_to_visual_row(state, geometry, geometry.vrow + 1)

      state.history_index != nil ->
        recall_newer(state)

      true ->
        {state, []}
    end
  end

  defp move_to_visual_row(state, geometry, target_vrow) do
    goal =
      state.goal_col ||
        WrapMap.cell_col(geometry.map, {geometry.vrow, geometry.gcol})

    {lrow, lcol} = WrapMap.to_logical(geometry.map, target_vrow, goal)

    mli =
      %{
        state.mli
        | cursor_pos: {lrow, lcol},
          selection_start: nil,
          selection_end: nil,
          desired_col: nil
      }
      |> MultiLineInput.ensure_cursor_visible()

    {%{state | mli: mli, goal_col: goal}, []}
  end

  # The shared logical->visual projection under `render/2`,
  # `edit_point/2`, and vertical navigation: ONE derivation so the
  # rendered rows, the park target, and the row arithmetic can never
  # disagree. `vscroll` is derived (not stored): the window of
  # `mli.height` visual rows containing the cursor, bottom-preferring.
  defp visual_geometry(state, width) do
    map = WrapMap.build(state.mli.value, width, state.wrap)
    {vrow, gcol} = WrapMap.to_visual(map, state.mli.cursor_pos)
    rows = WrapMap.row_count(map)
    height = max(state.mli.height, 1)

    vscroll =
      (vrow - height + 1)
      |> max(0)
      |> min(max(rows - height, 0))

    %{
      map: map,
      vrow: vrow,
      gcol: gcol,
      rows: rows,
      height: height,
      vscroll: vscroll
    }
  end

  # -- private: readline word/line editing (on the LOGICAL draft) ------
  #
  # Word boundaries are computed on the logical line's graphemes (never
  # the visual projection), so a soft wrap is invisible to them and a
  # logical newline IS a boundary. Motion and deletion share
  # `word_left_target/1`/`word_right_target/1`, so delete-word-back can
  # never remove something different from what word-left would skip.
  # MultiLineInput's own word nav is deliberately NOT reused -- its
  # reverse-length boundary math is off by the kept-suffix length (a
  # pre-existing bug in that shared module, left for its own consumers).

  defp word_left(state),
    do: move_cursor_logical(state, word_left_target(state.mli))

  defp word_right(state),
    do: move_cursor_logical(state, word_right_target(state.mli))

  defp line_start(state) do
    {row, _col} = state.mli.cursor_pos
    move_cursor_logical(state, {row, 0})
  end

  defp line_end(state) do
    {row, _col} = state.mli.cursor_pos
    move_cursor_logical(state, {row, logical_line_length(state.mli, row)})
  end

  defp delete_word_back(state) do
    origin = state.mli.cursor_pos
    target = word_left_target(state.mli)

    if target == origin,
      do: {state, []},
      else: delete_logical_range(state, target, origin)
  end

  defp kill_to_line_start(state) do
    {row, col} = state.mli.cursor_pos

    if col == 0,
      do: {state, []},
      else: delete_logical_range(state, {row, 0}, {row, col})
  end

  defp kill_to_line_end(state) do
    {row, col} = state.mli.cursor_pos
    eol = logical_line_length(state.mli, row)

    if col >= eol,
      do: {state, []},
      else: delete_logical_range(state, {row, col}, {row, eol})
  end

  # Sets the logical cursor and clears any selection; ensure_cursor_visible
  # re-derives the substrate's (logical, wrap :none) lines and scroll.
  defp move_cursor_logical(state, {row, col}) do
    mli =
      %{
        state.mli
        | cursor_pos: {row, col},
          selection_start: nil,
          selection_end: nil,
          desired_col: nil
      }
      |> MultiLineInput.ensure_cursor_visible()

    {%{state | mli: mli}, []}
  end

  # Deletes a logical range by staging it as a selection and running the
  # substrate's own selection-backspace (delete_selection normalizes the
  # endpoint order, splices the lines, and parks the cursor at the range
  # start). `from`/`to` are logical {row, grapheme col} positions.
  defp delete_logical_range(state, from, to) do
    mli = %{state.mli | selection_start: from, selection_end: to}
    {new_mli, _cmds} = update_mli({:backspace}, mli)
    {%{state | mli: new_mli}, []}
  end

  defp logical_line_length(mli, row) do
    mli.lines |> Enum.at(row, "") |> String.length()
  end

  # Word-left target: skip a whitespace run then a word run leftward to
  # the word start; at column 0 cross to the end of the previous logical
  # line (so delete-word-back there removes the joining newline).
  defp word_left_target(mli) do
    {row, col} = mli.cursor_pos
    graphemes = mli.lines |> Enum.at(row, "") |> String.graphemes()
    new_col = seek_word_left(graphemes, col)

    cond do
      new_col != col -> {row, new_col}
      row > 0 -> {row - 1, logical_line_length(mli, row - 1)}
      true -> {row, col}
    end
  end

  # Word-right target: skip a whitespace run then a word run rightward to
  # the word end; at end-of-line cross to the start of the next logical
  # line.
  defp word_right_target(mli) do
    {row, col} = mli.cursor_pos
    graphemes = mli.lines |> Enum.at(row, "") |> String.graphemes()
    len = length(graphemes)
    new_col = seek_word_right(graphemes, col, len)

    cond do
      new_col != col -> {row, new_col}
      row < length(mli.lines) - 1 -> {row + 1, 0}
      true -> {row, col}
    end
  end

  defp seek_word_left(graphemes, col) do
    col
    |> skip_left(graphemes, &whitespace?/1)
    |> skip_left(graphemes, &(not whitespace?(&1)))
  end

  defp seek_word_right(graphemes, col, len) do
    col
    |> skip_right(graphemes, len, &whitespace?/1)
    |> skip_right(graphemes, len, &(not whitespace?(&1)))
  end

  defp skip_left(col, graphemes, pred) do
    if col > 0 and pred.(Enum.at(graphemes, col - 1)) do
      skip_left(col - 1, graphemes, pred)
    else
      col
    end
  end

  defp skip_right(col, graphemes, len, pred) do
    if col < len and pred.(Enum.at(graphemes, col)) do
      skip_right(col + 1, graphemes, len, pred)
    else
      col
    end
  end

  defp whitespace?(nil), do: false
  defp whitespace?(grapheme), do: String.trim(grapheme) == ""

  # -- private: history recall --

  defp recall_older(state) do
    next_index =
      case state.history_index do
        nil -> 0
        idx -> min(idx + 1, length(state.history) - 1)
      end

    draft = if state.history_index == nil, do: value(state), else: state.draft
    text = Enum.at(state.history, next_index, "")

    {%{
       state
       | mli: set_mli_value(state.mli, text),
         history_index: next_index,
         draft: draft
     }, []}
  end

  defp recall_newer(%{history_index: 0} = state) do
    text = state.draft || ""

    {%{
       state
       | mli: set_mli_value(state.mli, text),
         history_index: nil,
         draft: nil
     }, []}
  end

  defp recall_newer(state) do
    new_index = state.history_index - 1
    text = Enum.at(state.history, new_index, "")

    {%{state | mli: set_mli_value(state.mli, text), history_index: new_index},
     []}
  end

  defp set_mli_value(mli, text) do
    {:ok, new_mli} =
      MultiLineInput.init(%{
        id: mli.id,
        value: text,
        placeholder: mli.placeholder,
        width: mli.width,
        height: mli.height,
        wrap: mli.wrap,
        focused: true
      })

    last_row = max(length(new_mli.lines) - 1, 0)
    last_line = Enum.at(new_mli.lines, last_row, "")
    %{new_mli | cursor_pos: {last_row, String.length(last_line)}}
  end

  # -- private: delegation to the wrapped MultiLineInput --

  defp delegate_to_mli(event, mli, context) do
    case MultiLineInput.handle_event(event, mli, context) do
      {:noreply, new_mli, cmd} -> {new_mli, wrap_cmd(cmd)}
      _other -> {mli, []}
    end
  end

  defp update_mli(msg, mli) do
    case MultiLineInput.update(msg, mli) do
      {:noreply, new_mli, cmd} -> {new_mli, wrap_cmd(cmd)}
      _other -> {mli, []}
    end
  end

  defp wrap_cmd(nil), do: []
  defp wrap_cmd(cmd) when is_list(cmd), do: cmd
  defp wrap_cmd(cmd), do: [cmd]

  # -- private: render helpers --

  defp queued_steer_banner(nil, _avail_width), do: nil

  defp queued_steer_banner(%{text: text}, avail_width) do
    content = truncate_to_width(@steer_prefix <> text, avail_width)

    Components.text(
      id: "queued-steer-banner",
      content: content,
      style: %{dim: true}
    )
  end

  defp truncate_to_width(text, width) when is_integer(width) and width > 0 do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> "…"
    end
  end

  defp truncate_to_width(text, _width), do: text
end
