defmodule Raxol.UI.Components.Harness.Block do
  @moduledoc """
  The projection unit of the harness transcript: one sealed-or-live chunk of
  a session, folded from journal events into a renderable shape.

  See `docs/proposals/in-flight/harness-ui-roadmap.md` (unit T4) and
  `docs/proposals/in-flight/harness-spec-protocol.md` (the event contract
  this module folds). The protocol's `%Event{}` struct does not exist in
  code yet (spec draft only) -- `from_events/3` accepts plain maps shaped
  like it: `%{id:, turn_id:, ts:, family:, type:, tier:, scope:,
  provenance:, payload:}`, all keys optional and read defensively. That
  tolerance is deliberate: the contract only grows, and this module must
  never crash when it meets a field it doesn't know yet.

  ## Struct

  - `kind` -- one of `:message | :reasoning | :tool_call | :diff |
    :approval`, or `:opaque` for anything not in that set (forward-compat:
    an unrecognised kind renders safely instead of crashing).
  - `raw_kind` -- the kind exactly as given to `from_events/3`, kept even
    when normalised to `:opaque` so the opaque render can still show a
    meaningful label.
  - `event_refs` -- the journal event ids this block was folded from.
  - `fold` -- `:expanded | :folded`.
  - `seal` -- `:live | :sealed`. A block is `:live` until `seal/1` is
    called on it (typically when the projection observes the block's
    owning turn/item close).
  - `outcome` -- `%{exit_code:, duration_ms:, cost:}`, each `nil` when not
    present in the source events.
  - `content` -- the kind-specific projection of the source events' payloads
    (never the raw events themselves; see the private `extract_content/2`
    clauses for the per-kind shape).

  ## Purity

  `from_events/3` is a pure function: identical `kind` + `events` + `opts`
  always produce an identical `%Block{}` (no random ids, no timestamps
  generated here -- `duration_ms` is derived only from `ts` fields already
  present on the source events).

  ## Fold semantics and the D-PA gate

  Fold state mutates freely while a block is `:live`. Once `seal/1` marks it
  `:sealed`, whether `fold/2` / `unfold/2` may still change the fold state is
  the paint-authority decision (D-PA, `harness-ui-roadmap.md` sec 0) --
  undecided as of this unit. Rather than hardcode a guess, every fold
  transition takes a `:fold_after_seal` option (`:allow | :deny`, default
  `:deny`) so the eventual D-PA verdict plugs in as a caller-supplied policy
  with no rewrite of this module: pass `fold_after_seal: :allow` once D-PA
  chooses soft-owned history or live-region-only with a wider live window;
  leave the default `:deny` for seal-time-only fold semantics.

  A denied post-seal fold is a silent no-op by design (`fold/2` always
  returns `t()`, never a tagged tuple). Callers that track fold state on
  their side (T9 toggle sites, keybind handlers) must consult
  `fold_allowed?/2` before toggling, so their bookkeeping never desyncs
  from a no-op transition.

  Algebraically: `fold/2` and `unfold/2` are projectors (idempotent --
  folding an already-folded block is a no-op), not involutions;
  `toggle_fold/2` is the involution, pre-seal. `seal/1` is monotonic and
  one-way by design -- there is no unseal. Every transition touches only
  its own field: `content`, `outcome`, `event_refs`, `kind`, and
  `raw_kind` are frozen at construction and never mutated afterwards.

  ## Observability

  Both total-safety rescues (construction fallback to `:opaque`, render
  fallback to the placeholder line) are observable per
  `harness-ui-testing/06-projection.md` sec 4: each emits a
  `Logger.warning/1` and the telemetry event
  `[:raxol, :harness, :block, :recovered]` with metadata
  `%{kind:, reason:}` -- a recovery is never silent. (Distinct from
  `Raxol.Harness.Projection.Recovery`'s stream-level
  `[:raxol, :harness, :projection, :recovered]`, whose metadata is
  `%{reason:, event_id:}`.)

  ## Rendering

  `render/2` returns a plain view map (`%{type: :column, ...}`) by
  default. When the caller supplies `context[:id]` (the harness TEA
  migration's U1 re-hosting), the root `:column` is stamped in place with
  `id` + semantic `attrs` (`component_module`/`kind`/`fold`/`seal`, plus
  `name`/`state`/`tainted` for tool calls) + an `on_click` toggle message
  -- the same seam U1-a/U1-b's block Components use, so `Raxol.MCP.
  TreeWalker` derives the `toggle_fold` action through the
  `attrs.component_module` marker and a bubbled click fires the toggle via
  the Bubbler's existing inline `on_click` path -- see `interactive_wrap/3`.
  Without an id nothing changes: the legacy render is byte- and
  map-identical, which is what the shelved Surface substrate keeps
  consuming. T5 mounts the rich per-kind components (already merged:
  `Harness.MessageBlock`, `Harness.ReasoningBlock`, `Harness.ToolCallBlock`,
  `Harness.ToolResultBlock`, `Harness.DiffViewer`, `Harness.ApprovalPrompt`,
  ...) as the fold-aware block bodies; this module is the data + text-only
  fallback layer underneath that.

  Expanded render = header line (fold glyph + kind glyph + first-line
  summary) + full content lines + an outcome row + a completion row.
  Folded render = the header line alone + the outcome row + a completion
  row. The outcome row is omitted entirely when `exit_code`, `duration_ms`,
  and `cost` are all `nil`; otherwise it renders only the fields that are
  present.

  ## The completion row (design creed: evidence, never a success toast)

  `content[:completion]` -- set by `Raxol.Harness.Projection.BlockBuilder.
  build_turn/3` on a turn's LAST block, only when that turn closed with a
  final `turn_completed` -- is either:

    * `%{evidence: :none}` -- no accepted refs: renders ONE line, the
      LITERAL text `"no evidence provided"`, no glyph, no checkmark --
      the absence is information, never blank.
    * `%{evidence: entries, total: n, type_counts: counts}` (plus an
      optional `cross_turn_count`, see `BlockBuilder`'s moduledoc "Cross-
      turn disclosure") -- renders:
      1. a summary line, `"N evidence refs: 2 tool results, 1 message"`
         (`n`, pluralized, then `counts` -- `[%{type:, count:}]`, already
         sorted descending by count -- joined `", "`, each phrase
         pluralized by ITS OWN count), with a `" (M cross-turn)"` suffix
         appended when `cross_turn_count` (`M`) is present;
      2. up to `length(entries)` per-ref lines (`entries` is capped
         upstream, see `BlockBuilder`), each `"· " <> label` (the label
         already sanitized/clamped -- an unresolvable ref's label is the
         literal `"unresolvable evidence ref"`, rendered exactly like any
         other entry, never dropped), with a trailing literal
         `" [cross-turn]"` when that entry carries `cross_turn: true`
         (a ref the producer's own gate would never have accepted as
         same-turn evidence -- shown, not hidden);
      3. a trailing `"+N more"` line when `n` exceeds `length(entries)`,
         itself suffixed `" (M cross-turn)"` when M of the hidden
         (never-rendered) refs are cross-turn -- so the summary's
         session-wide cross-turn tally is never left pointing at zero
         visibly marked lines.

  Key absent or unrecognised shape renders no row at all -- byte-identical
  to a block that never went through the completion-evidence fold.
  `completion_rows/2` is `Block`'s own render helper for this row, public
  so `Raxol.UI.Components.Harness.BlockBody`'s `:expanded` mount path
  (which otherwise bypasses this module's body entirely) can append the
  same rows after whatever real component it mounts -- see that module's
  moduledoc. Every completion line is styled `%{dim: true}` and fades with
  the same resolved prominence colour as the header/outcome rows.

  ## Prominence

  `context[:prominence]` (`0.0..1.0`) resolves the header/content/outcome
  text colours through `Raxol.UI.Harness.Prominence` -- a salience solver
  that fades a colour toward the background as prominence drops.
  `context[:ground]` overrides the background lightness (default:
  terminal-detected, see `Raxol.UI.Theming.SalienceTheme.detect_ground/0`).
  `context[:legibility_floor]` (default `false`) is threaded through to
  `Prominence.resolve/3`: the default is a pure fade (context text recedes,
  becoming legible again as it is promoted); set it `true` for interactive
  tiers where a minimum legibility must be preserved (see the `Prominence`
  moduledoc's "Two modes").

  A **live `:approval` block auto-engages the needs-input starvation
  guard** (`Prominence.resolve/3`'s `needs_input: true`): a pending
  question is never faded below ordinary context content, whatever
  prominence a demotion sweep hands it. A sealed approval is an answered
  question and fades free. `context[:needs_input]` (boolean) overrides the
  derivation in either direction -- flag any awaiting-input component in,
  or an approval out.

  When `context[:markdown]` is enabled, the Markdown body is faded to the
  same resolved colour as the header, so the whole block dims together.

  **Default is neutral**: when `:prominence` is absent from `context`, or
  is `1.0`, no style is touched -- the render is byte-identical to a render
  without prominence (no `:fg` added to any style map), so existing callers
  that never pass `:prominence` see zero change.

  The colour is resolved once per `render/2` call and threaded into every
  branch, so a multi-line body never re-runs the solver per line.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.DiffViewer
  alias Raxol.UI.Components.Harness.LineDiff
  alias Raxol.UI.Components.Harness.MarkdownBody
  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  require Logger

  @behaviour Raxol.MCP.ToolProvider

  @recovered_telemetry_event [:raxol, :harness, :block, :recovered]

  @type kind ::
          :message
          | :reasoning
          | :tool_call
          | :diff
          | :approval
          | :error
          | :opaque
  @type fold_state :: :expanded | :folded
  @type seal_state :: :live | :sealed
  @type fold_after_seal_policy :: :allow | :deny

  @type outcome :: %{
          exit_code: integer() | nil,
          duration_ms: non_neg_integer() | nil,
          cost: number() | nil
        }

  @type t :: %__MODULE__{
          kind: kind(),
          raw_kind: term(),
          event_refs: [term()],
          fold: fold_state(),
          seal: seal_state(),
          outcome: outcome(),
          content: map()
        }

  @enforce_keys [
    :kind,
    :raw_kind,
    :event_refs,
    :fold,
    :seal,
    :outcome,
    :content
  ]
  defstruct [:kind, :raw_kind, :event_refs, :fold, :seal, :outcome, :content]

  @known_kinds [:message, :reasoning, :tool_call, :diff, :approval, :error]

  # The reasoning register's own signature (V, 2026-07-18) -- the harness
  # marks cognition with the dotted "because/therefore" family instead of
  # the braille everyone else uses. A COLLAPSED thought is prefixed `⁖`;
  # an EXPANDED thought is bracketed `∵` (premises, first line) ... `∴`
  # (conclusion, last line), reading like an arrow through the reasoning.
  # The ACTIVE cycling set (`∴ ஃ ⁂ ⛬`) is the tick-clocked pulse and lives
  # in `Raxol.Harness.Surface` (the animation clock is there). All are
  # width-1, text-presentation (see `glyph_inventory/0`).
  @reasoning_collapsed_glyph "⁖"
  @reasoning_open_glyph "∵"
  @reasoning_close_glyph "∴"

  # Machinery kinds (tool_call/reasoning/diff) default FOLDED: their
  # default form is the one-line compact register (glyph + referent +
  # receipt), per the low-prominence execution-block ruling -- tool output
  # is always subordinate to speech. `z` (fold toggle) peeks the full body.
  #
  # `:error` defaults FOLDED too, but its compact form is a full-weight
  # ALARM line (`✗ <message>`), never the dim machinery register: a fault
  # is signal, and its real message must read plainly on the folded line --
  # never hidden behind a `N lines` receipt or a bare `(empty)`. `z` still
  # peeks a multi-line fault's full body.
  @default_fold_by_kind %{
    message: :expanded,
    reasoning: :folded,
    tool_call: :folded,
    diff: :folded,
    approval: :expanded,
    opaque: :expanded,
    error: :folded
  }

  @default_fold_after_seal :deny

  # The untrusted-content marker glyph, text presentation FORCED: U+26A0
  # alone is a dual-presentation codepoint (some terminals render it as an
  # emoji), so it carries U+FE0E (VARIATION SELECTOR-15). TextMeasure
  # counts the pair as one grapheme, width 1 (FE0E is Grapheme_Extend;
  # width comes from the base codepoint, which is not in any wide range).
  # Defined here, above `glyph_inventory/0`, so that inventory can list it.
  @taint_glyph "⚠︎"
  @taint_marker @taint_glyph <> " untrusted"

  # --- construction ---------------------------------------------------------

  @doc """
  The known block kinds (excludes `:opaque`, which is the forward-compat
  fallback, not a kind a caller asks for).
  """
  @spec known_kinds() :: [kind()]
  def known_kinds, do: @known_kinds

  @doc """
  The default fold state for `kind` (the "fold_defaults" a projection layer
  like T7 assigns per identity sec 2 of `harness-ui-testing/06-projection.md`).
  An unrecognised kind gets `:opaque`'s default.
  """
  @spec default_fold(term()) :: fold_state()
  def default_fold(kind),
    do: Map.fetch!(@default_fold_by_kind, normalize_kind(kind))

  @doc """
  Builds a `%Block{}` as a pure function of `kind` and its source `events`.

  `events` is a list of maps shaped like the (not-yet-coded) protocol
  `%Event{}` -- read defensively, every key optional. A `kind` outside
  `known_kinds/0` normalises to `:opaque`; `raw_kind` keeps the original
  value for display. Never raises: any unexpected shape in `events` falls
  back to an opaque block rather than crashing the caller.

  ## Options

  - `:fold` -- initial fold state, defaults to `default_fold(kind)`.
  - `:seal` -- initial seal state, defaults to `:live`.
  """
  @spec from_events(term(), [map()], keyword()) :: t()
  def from_events(kind, events, opts \\ []) when is_list(events) do
    normalized_kind = normalize_kind(kind)

    %__MODULE__{
      kind: normalized_kind,
      raw_kind: kind,
      event_refs: event_refs(events),
      fold: Keyword.get(opts, :fold, default_fold(normalized_kind)),
      seal: Keyword.get(opts, :seal, :live),
      outcome: extract_outcome(events),
      content: extract_content(normalized_kind, events)
    }
  rescue
    e ->
      emit_recovered(kind, e, __STACKTRACE__)
      opaque_fallback(kind, events, opts)
  end

  defp normalize_kind(kind) when kind in @known_kinds, do: kind
  defp normalize_kind(_kind), do: :opaque

  defp emit_recovered(kind, exception, stacktrace) do
    reason = Exception.message(exception)

    Logger.warning(
      "Harness.Block recovered from #{inspect(kind)} render/projection failure: " <>
        "#{reason}\n" <> Exception.format_stacktrace(stacktrace)
    )

    :telemetry.execute(@recovered_telemetry_event, %{}, %{
      kind: kind,
      reason: reason
    })
  end

  defp opaque_fallback(kind, events, opts) do
    %__MODULE__{
      kind: :opaque,
      raw_kind: kind,
      event_refs: safe_event_refs(events),
      fold: Keyword.get(opts, :fold, :expanded),
      seal: Keyword.get(opts, :seal, :live),
      outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
      content: %{text: safe_inspect(events)}
    }
  end

  defp safe_event_refs(events) do
    event_refs(events)
  rescue
    _ -> []
  end

  defp safe_inspect(term) do
    inspect(term)
  rescue
    _ -> "(unrenderable events)"
  end

  # --- fold / seal transitions -----------------------------------------------

  @doc """
  Marks a block sealed. Idempotent.
  """
  @spec seal(t()) :: t()
  def seal(%__MODULE__{} = block), do: %{block | seal: :sealed}

  @doc """
  Folds `block`. Always allowed while `:live`. Once `:sealed`, gated by
  `opts[:fold_after_seal]` (`:allow | :deny`, default `:deny`) -- see the
  moduledoc's D-PA note. Denied post-seal folds are a no-op (the block is
  returned unchanged), never an error.
  """
  @spec fold(t(), keyword()) :: t()
  def fold(block, opts \\ [])

  def fold(%__MODULE__{seal: :live} = block, _opts),
    do: %{block | fold: :folded}

  def fold(%__MODULE__{seal: :sealed} = block, opts) do
    apply_post_seal_fold(block, :folded, opts)
  end

  @doc """
  Unfolds `block`. Same pre/post-seal semantics as `fold/2`.
  """
  @spec unfold(t(), keyword()) :: t()
  def unfold(block, opts \\ [])

  def unfold(%__MODULE__{seal: :live} = block, _opts),
    do: %{block | fold: :expanded}

  def unfold(%__MODULE__{seal: :sealed} = block, opts) do
    apply_post_seal_fold(block, :expanded, opts)
  end

  @doc """
  Toggles fold state; dispatches to `fold/2` or `unfold/2`.
  """
  @spec toggle_fold(t(), keyword()) :: t()
  def toggle_fold(block, opts \\ [])

  def toggle_fold(%__MODULE__{fold: :folded} = block, opts),
    do: unfold(block, opts)

  def toggle_fold(%__MODULE__{fold: :expanded} = block, opts),
    do: fold(block, opts)

  @doc """
  Whether a fold/unfold transition on `block` would apply under the given
  D-PA policy options -- the same `:fold_after_seal` option `fold/2` and
  `unfold/2` take. Always `true` while `:live`; post-seal, `true` only
  under `fold_after_seal: :allow`.

  Interactive callers that keep their own fold bookkeeping (T9 toggle
  sites) must check this before toggling, since a denied post-seal
  `fold/2` is a silent no-op.
  """
  @spec fold_allowed?(t(), keyword()) :: boolean()
  def fold_allowed?(block, opts \\ [])
  def fold_allowed?(%__MODULE__{seal: :live}, _opts), do: true

  def fold_allowed?(%__MODULE__{seal: :sealed}, opts) do
    Keyword.get(opts, :fold_after_seal, @default_fold_after_seal) == :allow
  end

  defp apply_post_seal_fold(block, new_fold, opts) do
    if fold_allowed?(block, opts) do
      %{block | fold: new_fold}
    else
      block
    end
  end

  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{seal: :live}), do: true
  def live?(%__MODULE__{}), do: false

  @spec sealed?(t()) :: boolean()
  def sealed?(%__MODULE__{seal: :sealed}), do: true
  def sealed?(%__MODULE__{}), do: false

  @doc """
  The speaker of a `:message` block: `:user` when the block's extracted
  content carries an explicit `role: :user` (see `extract_content/2`'s
  role normalization), `:assistant` for every other message and for
  every non-message kind (machinery has no speaker; the unmarked voice
  is the safe default). This is the one derivation the folded header
  glyph and `Raxol.Harness.Surface`'s user-echo seam both read, so the
  two can never disagree about who spoke.
  """
  @spec role(t()) :: :user | :assistant
  def role(%__MODULE__{kind: :message, content: %{role: :user}}), do: :user
  def role(%__MODULE__{}), do: :assistant

  @spec folded?(t()) :: boolean()
  def folded?(%__MODULE__{fold: :folded}), do: true
  def folded?(%__MODULE__{}), do: false

  # --- render -----------------------------------------------------------

  @doc """
  Renders `block` as a plain view map. `context[:width]` sets the wrap/
  truncation budget (defaults to `Raxol.Core.Defaults.terminal_width/0`).

  `context[:markdown]` (default `false`, additive/opt-in) routes a
  `:message`/`:reasoning` block's text content through
  `Raxol.UI.Components.Harness.MarkdownBody` instead of the plain
  line-split body: `:sealed` mode while the block is `:sealed`, `:streaming`
  (provisional-close) while it is still `:live`. Every other kind, and
  every block when the option is omitted, renders exactly as before.

  `context[:prominence]` (see the moduledoc's "Prominence" section) fades
  the header, content, and outcome to one resolved colour. A Markdown body
  fades in lockstep -- its text nodes carry the same colour as the header,
  so a faded header never sits above a bright body.

  Never raises: any unexpected internal shape falls back to a one-line
  placeholder rather than crashing the caller.
  """
  @spec render(t(), map()) :: map()
  def render(block, context \\ %{})

  def render(%__MODULE__{} = block, context) do
    width = Map.get(context, :width, Raxol.Core.Defaults.terminal_width())
    interactive_wrap(build_render(block, width, context), block, context)
  rescue
    e ->
      emit_recovered(block.kind, e, __STACKTRACE__)

      interactive_wrap(
        render_fallback(block, e, __STACKTRACE__),
        block,
        context
      )
  end

  # -- the interactive re-hosting stamp (harness TEA migration U1) ----------
  #
  # When the caller supplies `context[:id]` (a non-empty binary), the root
  # `:column` is stamped in place with `:id`, semantic `:attrs`, and an
  # `:on_click` toggle message -- the SAME seam U1-a/U1-b's block
  # Components use, so the pipeline treats every re-hosted block alike:
  #
  #   * `attrs.component_module: __MODULE__` is the marker
  #     `Raxol.MCP.TreeWalker` resolves a plain-`:column` root's provider
  #     through (no new node type, no type-map growth); `mcp_tools/1` then
  #     derives the `toggle_fold` action.
  #   * `on_click:` carries the toggle message. A `%Event{type: :click}`
  #     bubbled at this node (a real mouse click OR the click
  #     `handle_tool_call/3` emits) fires it through the Bubbler's existing
  #     inline `on_click` path -- so the MCP toggle and a physical click
  #     dispatch the identical message, with zero Bubbler changes.
  #
  # WITHOUT `context[:id]` nothing is stamped: the render stays the legacy
  # column, byte- and map-identical, so the shelved Surface substrate
  # (which never passes an id) is untouched.
  #
  # `attrs` carries the semantic contract the tree consumers read:
  # `kind`/`fold`/`seal` always; a `:tool_call` block adds `name` (the
  # referent), `state` (the SAME outcome derivation the compact glyph
  # renders -- `tool_state/3`, single source, the two can never disagree),
  # and `tainted`.
  #
  # Total: never raises on a weird context value -- a non-binary id means
  # no stamp, same as no id (the rescue path above relies on this).
  defp interactive_wrap(body, block, context) do
    case Map.get(context, :id) do
      id when is_binary(id) and id != "" ->
        body
        |> Map.put(:id, id)
        |> Map.put(:attrs, interactive_attrs(block, context))
        |> Map.put(:on_click, toggle_message(id, context))

      _absent ->
        body
    end
  end

  defp interactive_attrs(%__MODULE__{} = block, context) do
    %{
      component_module: __MODULE__,
      kind: block.kind,
      fold: block.fold,
      seal: block.seal
    }
    |> Map.merge(interactive_kind_attrs(block, context))
  end

  defp interactive_kind_attrs(
         %__MODULE__{kind: :tool_call, content: content} = block,
         context
       )
       when is_map(content) do
    %{
      name: tool_name(content),
      state: tool_state(content, block.outcome, context),
      tainted: Map.get(content, :tainted) == true
    }
  end

  defp interactive_kind_attrs(_block, _context), do: %{}

  # The toggle message an `on_click`/key toggle emits: an app-declared
  # `context[:on_toggle]` term when given, else the default
  # `{:harness_block, :toggle_fold, id}` the host's `update/2` folds on.
  defp toggle_message(id, context) do
    case Map.get(context, :on_toggle) do
      nil -> {:harness_block, :toggle_fold, id}
      message -> message
    end
  end

  # -- handle_event / ToolProvider (the controlled interaction seam) --------

  @doc """
  The real `handle_event/3` of the re-hosted block Component (the
  U1-a/U1-b/Tree convention) -- CONTROLLED per the section-2 doctrine:
  this function never holds or mutates fold state. Enter / Space / the
  `z` key EMIT the stamped `on_click` toggle message as an outgoing
  command; the host app's `update/2` folds the `%Block{}` the model owns
  (respecting its own D-PA `:fold_after_seal` policy -- the component
  cannot pre-judge it). `state` is unchanged (the block has no local
  state to flip -- returning it keeps the direct-host contract shape).

  A `%Event{type: :click}` is left to the Bubbler's inline `on_click`
  path (fired by a real mouse hit or the click `handle_tool_call/3`
  emits), so this module never needs Bubbler registration. Every other
  event returns `{state, []}` (handled, nothing emitted).

  The emitted message is the `on_click` term the render stamped
  (`{:harness_block, :toggle_fold, id}` by default, or the caller's
  `context[:on_toggle]`); a node without one emits nothing.

  `state` is the element map (`%{id:, attrs:, on_click:, ...}`), never
  this module's own struct -- props in, message out.
  """
  @spec handle_event(Event.t(), map(), map()) :: {map(), [term()]}
  def handle_event(%Event{type: :key, data: %{key: key}}, state, _context)
      when key in [:enter, :space],
      do: {state, toggle_commands(state)}

  def handle_event(
        %Event{type: :key, data: %{key: :char, char: "z"}},
        state,
        _context
      ),
      do: {state, toggle_commands(state)}

  def handle_event(_event, state, _context), do: {state, []}

  defp toggle_commands(%{on_click: message}) when not is_nil(message),
    do: [message]

  defp toggle_commands(_state), do: []

  # The `toggle_fold` action is derived ONLY when the node carries an
  # `on_click` toggle message (the render stamped one for a block with an
  # id) -- mirrors Button/ReasoningBlock's `on_click`-gated derivation.
  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{on_click: handler} = node) when not is_nil(handler) do
    attrs = Map.get(node, :attrs, %{})
    kind = Map.get(attrs, :kind, :block)

    [
      %{
        name: "toggle_fold",
        description:
          "Toggle fold on the #{kind} block '#{block_tool_label(attrs, kind)}' " <>
            "(compact line <-> full body)",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  def mcp_tools(_node), do: []

  # The targeted click Event is resolved by the Dispatcher through the
  # Bubbler at this widget's `on_click` inline handler (the same seam
  # Button's F0-mcp click proved), so an MCP toggle and a physical click
  # dispatch the same toggle message -- one path, two entry points.
  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("toggle_fold", _args, context) do
    {:ok, "Requested fold toggle on '#{context.widget_id}'",
     [%Event{type: :click, data: %{widget_id: context.widget_id}}]}
  end

  def handle_tool_call(action, _args, _context),
    do: {:error, "Unknown action: #{action}"}

  defp block_tool_label(attrs, kind) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and name != "" -> name
      _absent -> to_string(kind)
    end
  end

  defp build_render(block, width, context) do
    # Resolve the prominence fade colour ONCE per render (nil = neutral,
    # no fade), then thread it into every text-producing branch --
    # header, content, and outcome all carry the SAME `:fg`, and the
    # per-line content map never re-runs the H-K solver.
    fg = prominence_fg(block, context)
    header = header_view(block, width, fg, context)
    outcome_children = outcome_children(block, fg)
    completion_children = completion_rows(block, fg, context)

    body_children =
      case block.fold do
        :folded -> [header]
        :expanded -> [header | content_lines_view(block, width, context, fg)]
      end

    column =
      Components.column(
        gap: 0,
        children: body_children ++ outcome_children ++ completion_children
      )

    stamp_component(block, column)
  end

  # An approval block's render root is stamped as an `:approval_prompt`
  # component node -- it carries the `id` + `attrs` the MCP TreeWalker and
  # the input Bubbler need to derive answer tools and route answer events
  # at THIS block, while keeping the column's `children`/`gap`/`style`
  # untouched so every children-reading consumer (ViewText flattening,
  # the layout engine, the render pins) sees the exact tree it did before.
  # The LayoutEngine rewrites `:approval_prompt` -> `:column` for
  # positioning (a type alias, exactly like the chart discovery types).
  # `answer_mode: :direct` marks the transcript block form (the harness
  # answer vocabulary); `seal` gates answerability (a sealed question
  # derives no answer tools). Every other kind renders as a plain column.
  defp stamp_component(%__MODULE__{kind: :approval} = block, column) do
    content = block.content || %{}

    column
    |> Map.put(:type, :approval_prompt)
    |> Map.put(:id, approval_node_id(block))
    |> Map.put(:attrs, %{
      seal: block.seal,
      answer_mode: :direct,
      request_id: Map.get(content, :request_id),
      options: Map.get(content, :options, [])
    })
  end

  defp stamp_component(_block, view), do: view

  # The node id keys the derived tools (`<id>.answer_allow`) and the event
  # route -- the request_id (the referent) when present, a stable fallback
  # otherwise. Never raises on a non-string request_id.
  defp approval_node_id(%__MODULE__{content: %{request_id: rid}})
       when is_binary(rid) and rid != "",
       do: "approval-#{rid}"

  defp approval_node_id(_block), do: "approval-prompt"

  # The moduledoc promise: a render fault is NEVER a dead cell. Even when
  # `build_render/3` raises on an unexpected content shape, the block still
  # shows its honest one-line summary (`safe_summary/1` can never itself
  # raise) so the operator sees WHAT the block is (the tool + action of an
  # approval, the first line of a message), plus a visible recovery marker
  # so the fault is not silently swallowed. The real exception + stacktrace
  # is logged at the rescue site (`emit_recovered/3`).
  defp render_fallback(block, exception, stacktrace) do
    Components.column(
      gap: 0,
      children: [
        Components.text(content: safe_summary(block), style: %{}),
        Components.text(
          # Site LEADS the message so it survives a narrow terminal's
          # truncation: `Exception.message/1` for a BadMapError carries a
          # multi-line inspected value that would otherwise push the
          # `file:line` off the visible row (exactly what hid this crash's
          # location in the field). Reason is capped to one short line.
          content:
            "(render error#{safe_site(stacktrace)}: #{safe_reason(exception)})",
          style: %{dim: true}
        )
      ]
    )
  end

  # The first in-repo stack frame of the render fault, appended to the inline
  # message as ` @ Module.fun/arity (file:line)` -- so the on-screen fallback
  # names WHERE the crash was, not only WHY, without waiting on the log. Skips
  # this module's own rescue frames to point at the real culprit (usually a
  # DiffViewer / MarkdownBody child). Never itself raises.
  defp safe_site([_ | _] = stacktrace) do
    frame =
      Enum.find(stacktrace, fn
        {__MODULE__, name, _arity, _loc}
        when name in [:render_fallback, :render] ->
          false

        {mod, _fun, _arity, _loc} ->
          mod |> to_string() |> String.starts_with?("Elixir.Raxol")

        _ ->
          false
      end) || List.first(stacktrace)

    case frame do
      {mod, fun, arity, loc} ->
        file = loc |> Keyword.get(:file, ~c"") |> to_string() |> Path.basename()
        line = Keyword.get(loc, :line)
        arity = if is_integer(arity), do: arity, else: length(List.wrap(arity))
        " @ #{inspect(mod)}.#{fun}/#{arity} (#{file}:#{line})"

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp safe_site(_), do: ""

  defp safe_summary(block) do
    summary(block)
  rescue
    _ -> "#{block.kind} block"
  end

  # The exception's message, surfaced inline so a render fault shows WHY on
  # screen (dev-facing), not only in the log. Never itself raises.
  defp safe_reason(exception) do
    exception
    |> Exception.message()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 80)
  rescue
    _ -> "unknown"
  end

  # -- machinery compact headers (the low-prominence execution register) --
  #
  # Tool, reasoning, and diff blocks render ONE compact line as their
  # header, with no fold arrow: the glyph itself marks the line, the fold
  # key still peeks the body. The line is the block's FINAL sealed form --
  # a merged tool round-trip is one line (glyph + name + lead args +
  # outcome receipt), never a header plus a separate result section.
  # Machinery is dim by default (tool output subordinate to speech); a
  # FAILED tool keeps alarm prominence (never dim -- a failed tool is a
  # signal, not machinery noise).
  defp header_view(%__MODULE__{kind: :tool_call} = block, width, fg, context) do
    line = tool_line(block, context)
    style = if tool_failed?(block.outcome), do: %{}, else: %{dim: true}

    Components.text(
      content: TextLayout.truncate(line, max(width, 1), :ellipsis),
      style: apply_fg(style, fg)
    )
  end

  # The collapsed thought: `⁖ thinking` flush left, the honest quantity
  # (`N lines · <duration>`) flush right -- a space-between register line
  # so the eye reads the marker and the cost at the two edges. Duration is
  # shown only when the block genuinely carries one (never fabricated).
  defp header_view(%__MODULE__{kind: :reasoning} = block, width, fg, _context) do
    Components.text(
      content:
        justify_between(
          "#{@reasoning_collapsed_glyph} thinking",
          reasoning_meta(block),
          max(width, 1)
        ),
      style: apply_fg(%{dim: true}, fg)
    )
  end

  defp header_view(%__MODULE__{kind: :diff} = block, width, fg, _context) do
    Components.text(
      content: TextLayout.truncate(diff_line(block), max(width, 1), :ellipsis),
      style: apply_fg(%{dim: true}, fg)
    )
  end

  # An error is an ALARM line, never a foldable machinery block: NO fold
  # arrow, NEVER dim (a fault is signal, per the compaction ruling), and it
  # shows its REAL message (`error_line/1` reads the honest error text, with
  # an honest specific fallback when the fault genuinely carries none --
  # never a bare `(empty)`). The compact line is line 1 of the fault; `z`
  # peeks the full body (a multi-line fault) via `content_lines_view/4`.
  defp header_view(%__MODULE__{kind: :error} = block, width, fg, _context) do
    Components.text(
      content: TextLayout.truncate(error_line(block), max(width, 1), :ellipsis),
      style: apply_fg(%{}, fg)
    )
  end

  defp header_view(block, width, fg, _context) do
    prefix = "#{fold_icon(block.fold)} #{glyph(block)} "
    budget = max(width - TextMeasure.display_width(prefix), 1)
    summary_text = block |> summary() |> TextLayout.truncate(budget, :ellipsis)

    Components.text(
      content: prefix <> summary_text,
      style: apply_fg(header_style(block.kind), fg)
    )
  end

  # Chrome neutral baseline (matches DiffViewer's neutral chrome colour)
  # faded per `context[:prominence]`. Absent or 1.0 prominence resolves to
  # a nil fade colour (see `prominence_fg/1`), which `apply_fg/2` leaves
  # the style untouched for -- neutral by default.
  @chrome_fg "#B4B4B4"

  # Applies an already-resolved fade colour to a style map. `nil` (the
  # neutral / no-prominence case) leaves the style byte-identical.
  defp apply_fg(style, nil), do: style
  defp apply_fg(style, fg), do: Map.put(style, :fg, fg)

  # The machinery register's prominence ceiling (V's completed-phases
  # ruling): a SEALED tool/reasoning/diff line is subordinate machinery —
  # it renders no brighter than one recency tier down, whatever the
  # context grade says. `:dim` alone reads near-full-strength on many
  # terminals; the fade ramp is the honest register signal.
  @machinery_register_prominence 0.6

  defp prominence_fg(block, context) do
    case effective_prominence(block, Map.get(context, :prominence, 1.0)) do
      p when is_number(p) and p >= 1.0 ->
        nil

      p when is_number(p) ->
        Prominence.resolve(@chrome_fg, p, prominence_opts(block, context))

      _other ->
        nil
    end
  end

  # A FAILED tool keeps alarm prominence (a fault is signal, not
  # machinery noise — same rule as its `header_view/4` style); errors and
  # approvals never clamp (alarm / needs-input registers). Live machinery
  # keeps full prominence until it seals — the fade marks COMPLETION.
  defp effective_prominence(
         %__MODULE__{seal: :sealed, kind: kind} = block,
         p
       )
       when kind in [:tool_call, :reasoning, :diff] and is_number(p) do
    if kind == :tool_call and is_map(block.outcome) and
         tool_failed?(block.outcome),
       do: p,
       else: min(p, @machinery_register_prominence)
  end

  defp effective_prominence(_block, p), do: p

  # Only pass `:ground` through when the caller actually supplied one --
  # `Prominence.resolve/3` defaults it lazily (OSC-11-detected, else the
  # solver's reference ground), and an explicit `ground: nil` would
  # short-circuit that default. `:legibility_floor` is threaded through when
  # present (T9 sets it true for acting tiers; default false = pure fade).
  # `:needs_input` engages the starvation guard (see `needs_input?/2`).
  defp prominence_opts(block, context) do
    []
    |> put_opt(:ground, Map.get(context, :ground))
    |> put_opt(:legibility_floor, Map.get(context, :legibility_floor))
    |> put_opt(:needs_input, needs_input?(block, context))
  end

  # A LIVE approval block is, by definition, waiting on the user -- it
  # auto-engages `Prominence`'s needs-input starvation guard so no
  # demotion sweep can fade the pending question below ordinary context.
  # Once sealed it is an answered question (history), so the auto-flag
  # drops. `context[:needs_input]` overrides the derivation either way
  # (a caller can flag any awaiting-input component in, or an approval
  # out). Returns `nil` (not `false`) when the guard is off so
  # `put_opt/3` omits the key entirely.
  defp needs_input?(block, context) do
    engaged =
      case Map.get(context, :needs_input) do
        value when is_boolean(value) -> value
        _absent -> block.kind == :approval and block.seal == :live
      end

    if engaged, do: true, else: nil
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  defp fold_icon(:folded), do: "▸"
  defp fold_icon(_fold), do: "▾"

  # The folded-header glyph is role-aware for `:message` blocks: a folded
  # USER turn reads `▸ ❯ first line…` (the prompt-echo sigil standing in
  # for the kind glyph, so a folded prompt is still recognisably the
  # user's voice), a folded assistant message keeps `▸ » summary`. The
  # header itself stays at the ordinary margined header column -- only
  # the EXPANDED user echo's chevron enters the margin, and that happens
  # at `Raxol.Harness.Surface`'s margin/chevron seam, never here.
  defp glyph(%__MODULE__{kind: :message} = block) do
    case role(block) do
      :user -> "❯"
      :assistant -> kind_glyph(:message)
    end
  end

  defp glyph(%__MODULE__{kind: kind}), do: kind_glyph(kind)

  defp kind_glyph(:message), do: "»"
  defp kind_glyph(:reasoning), do: "∴"
  defp kind_glyph(:tool_call), do: "⚙"
  defp kind_glyph(:diff), do: "±"
  defp kind_glyph(:approval), do: "⚑"
  defp kind_glyph(_kind), do: "◆"

  @doc """
  Every literal glyph this module can emit into a rendered cell -- the
  fold arrows, the per-kind glyphs, the role/receipt/outcome markers, and
  the tainted-content marker. The one enumerated source the no-emoji
  tripwire (`block_glyph_inventory_test.exs`) sweeps: each MUST measure
  one display column (`Raxol.UI.TextMeasure`) and MUST NOT carry the
  emoji-presentation selector U+FE0F. Dual-presentation bases that some
  terminals default to emoji (U+26A0 WARNING) carry U+FE0E to force the
  monochrome text glyph -- machinery is a text register, never an emoji.
  """
  @spec glyph_inventory() :: [String.t()]
  def glyph_inventory do
    [
      # fold arrows
      "▸",
      "▾",
      # per-kind
      "»",
      "∴",
      "⚙",
      "±",
      "⚑",
      "◆",
      # reasoning register (collapsed prefix + expanded ∵/∴ brackets)
      @reasoning_collapsed_glyph,
      @reasoning_open_glyph,
      # message role
      "❯",
      # tool receipt / outcome markers
      "✓",
      "✗",
      "⊘",
      # tainted-content marker glyph (FE0E-guarded -- see @taint_glyph)
      @taint_glyph
    ]
  end

  # `:reasoning`, `:tool_call`, and `:diff` never reach here -- each has
  # its own compact `header_view/4` clause. `:opaque` still routes through
  # the default header.
  defp header_style(:opaque), do: %{dim: true}
  defp header_style(_kind), do: %{}

  defp content_style(:reasoning), do: %{dim: true}
  defp content_style(:tool_call), do: %{dim: true}
  defp content_style(:opaque), do: %{dim: true}
  defp content_style(_kind), do: %{}

  # -- the compact machinery lines ------------------------------------------

  # The one-line form of a merged tool round-trip: `⚙ name key: value`
  # -- glyph + referent + args, NO receipt. V's ruling: the byte-count /
  # duration / `✓ N lines` receipt was redundant information (the strip
  # already shows elapsed; the z-expanded body shows the output), and the
  # arg braces + quotes were noise. So the collapsed line drops the whole
  # `· <receipt>` suffix and renders args as unquoted `key: value` (see
  # `format_args/1`), never `(key: "value")`.
  #
  # The STATE the receipt used to carry now rides the leading GLYPH
  # (`tool_glyph/3`): `⚙` normal/success, `✗` a failed exit (alarm), `⊘`
  # a sealed tool that produced no result (the honest absence). A pending
  # footer preview keeps `⚙` -- the col-0 margin spinner already animates
  # "running" there, so no `running…` text is needed. The one surviving
  # suffix is the taint marker: `⚠︎ untrusted` is a security provenance
  # signal, not a receipt, so it is never dropped.
  defp tool_line(%__MODULE__{content: content} = block, context) do
    name = tool_name(content)
    glyph = tool_glyph(content, block.outcome, context)
    args = format_args(Map.get(content, :args))

    "#{glyph} #{name}#{args}#{tool_taint_suffix(content)}"
  end

  defp tool_name(content) do
    case Map.get(content, :name) do
      n when is_binary(n) and n != "" -> n
      _absent -> "(tool)"
    end
  end

  # The compact tool glyph carries the outcome state the receipt suffix
  # used to spell out -- one monochrome text cell (all in
  # `glyph_inventory/0`), never a verbose ` · ✓ …` tail:
  #
  #   * pending footer preview (`context[:pending?]`, no result/exit) ->
  #     `⚙`; the margin spinner animates "running", so the line stays plain.
  #   * non-zero `exit_code` -> `✗` (a failure is signal; the header stays
  #     non-dim -- see `header_view(:tool_call)`).
  #   * sealed with NO result and NO exit -> `⊘`, the honest absence (a
  #     claim of action with no receipt is never silent).
  #   * otherwise (a result, or exit 0) -> `⚙`.
  defp tool_glyph(content, outcome, context) do
    case tool_state(content, outcome, context) do
      :running -> kind_glyph(:tool_call)
      :failed -> "✗"
      :no_result -> "⊘"
      :ok -> kind_glyph(:tool_call)
    end
  end

  # The one outcome-state derivation BOTH the compact glyph and the
  # interactive `attrs.state` read (see `interactive_kind_attrs/2`), so
  # the rendered glyph and the derived tool metadata can never disagree:
  # `:running` (pending footer preview, no answer yet), `:failed`
  # (non-zero exit), `:no_result` (sealed with no result and no exit --
  # the honest absence), `:ok` otherwise.
  defp tool_state(content, outcome, context) do
    result = Map.get(content, :result)
    exit_code = Map.get(outcome, :exit_code)

    cond do
      awaiting_result?(result, outcome, context) -> :running
      is_integer(exit_code) and exit_code != 0 -> :failed
      is_nil(result) and is_nil(exit_code) -> :no_result
      true -> :ok
    end
  end

  # The taint marker is a security provenance signal (never a receipt), so
  # it survives the receipt drop as the collapsed line's one ` · ` suffix.
  defp tool_taint_suffix(content) do
    if Map.get(content, :tainted) == true, do: " · " <> @taint_marker, else: ""
  end

  # The ALARM line for an `:error` block -- glyph `✗` + the REAL fault text
  # (line 1; `z` peeks the rest), read defensively from the fault payload.
  # An error event carries its message on `reason` (see
  # `Raxol.Agent.Contract`'s `:error` event, payload `%{reason}`), which the
  # generic `@text_paths` never read -- hence the old `[error] (empty)`
  # render. When the fault genuinely carries no message, fall back to an
  # honest specific line (naming `where`, else that there is no message),
  # never a bare `(empty)`.
  defp error_line(%__MODULE__{content: content}) do
    message = content |> Map.get(:text) |> to_display_text() |> String.trim()
    where = content |> Map.get(:where) |> to_display_text() |> String.trim()

    cond do
      message != "" -> "✗ " <> first_line(message)
      where != "" -> "✗ error from " <> first_line(where)
      true -> "✗ error (no message)"
    end
  end

  # Awaiting = rendered in the footer live tail (`pending?`), no result
  # yet, and no exit code (a non-nil exit counts as an answer). `pending?`
  # is set ONLY by the footer preview -- it keeps a pending tool's glyph a
  # plain `⚙` (the margin spinner animates "running") instead of the sealed
  # `⊘` absence, so the live tool line and its sealed form stay coherent.
  defp awaiting_result?(result, outcome, context) do
    is_nil(result) and is_nil(Map.get(outcome, :exit_code)) and
      Map.get(context, :pending?, false) == true
  end

  defp tool_failed?(outcome) do
    exit_code = Map.get(outcome, :exit_code)
    is_integer(exit_code) and exit_code != 0
  end

  # The right-edge meta of a collapsed thought: the honest line count and,
  # when the block carries one, the thinking duration. The `⁖ thinking`
  # left edge is built in `header_view/4`; the count is the honest quantity
  # (never the first line of the thought: collapsed means collapsed).
  defp reasoning_meta(%__MODULE__{content: content, outcome: outcome}) do
    count = (content || %{}) |> Map.get(:text) |> split_lines() |> length()
    line_part = "#{count} #{if count == 1, do: "line", else: "lines"}"

    case (outcome || %{}) |> Map.get(:duration_ms) |> reasoning_duration() do
      nil -> line_part
      dur -> line_part <> " · " <> dur
    end
  end

  defp reasoning_duration(ms) when is_integer(ms) and ms >= 1000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp reasoning_duration(ms) when is_integer(ms) and ms >= 0, do: "#{ms}ms"
  defp reasoning_duration(_absent), do: nil

  # Space-between: `left` flush start, `right` flush end, padded to `width`.
  # When they cannot both fit the right meta is dropped and the left is
  # truncated -- the marker survives, the meta is the expendable part (it
  # re-appears when the terminal is wider).
  defp justify_between(left, right, width)
       when is_binary(right) and right != "" do
    gap =
      width - TextMeasure.display_width(left) - TextMeasure.display_width(right)

    if gap >= 1 do
      left <> String.duplicate(" ", gap) <> right
    else
      TextLayout.truncate(left, width, :ellipsis)
    end
  end

  defp justify_between(left, _right, width),
    do: TextLayout.truncate(left, width, :ellipsis)

  # `± path · +N -M` -- the diff block's compact line; the ± body stays
  # the expanded form. Counts come from the same LCS the expanded
  # DiffViewer walks, so the two can never disagree.
  defp diff_line(%__MODULE__{content: content}) do
    path =
      case content |> Map.get(:path) |> to_display_text() do
        "" -> "(no path)"
        p -> p
      end

    {added, removed} = diff_stat(content)
    "#{kind_glyph(:diff)} #{path} · +#{added} -#{removed}"
  end

  defp diff_stat(content) do
    old = content |> Map.get(:old) |> to_display_text()
    new = content |> Map.get(:new) |> to_display_text()

    LineDiff.diff(old, new)
    |> Enum.reduce({0, 0}, fn
      {:insert, _line}, {added, removed} -> {added + 1, removed}
      {:delete, _line}, {added, removed} -> {added, removed + 1}
      {:equal, _line}, acc -> acc
    end)
  end

  @doc """
  One-line summary of `block` (kind-aware) -- the folded-header text and
  the jump-picker's label source (see
  `command_palette_surface_test.exs`'s "jump picker" describe).
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{
        kind: :tool_call,
        content: %{name: name, args: args}
      }) do
    name <> format_args(args)
  end

  def summary(%__MODULE__{kind: :approval, content: %{action: action}}) do
    first_line(action)
  end

  def summary(%__MODULE__{kind: :diff, content: %{path: path}}) do
    case path do
      "" -> "(no path)"
      p -> p
    end
  end

  def summary(%__MODULE__{
        kind: :opaque,
        raw_kind: raw_kind,
        content: %{text: text}
      }) do
    "[#{kind_label(raw_kind)}] " <> first_line(text)
  end

  def summary(%__MODULE__{content: %{text: text}}) do
    first_line(text)
  end

  def summary(_block), do: "(empty)"

  @doc """
  The honest per-block search corpus: `"<kind> · <summary>"` (the same
  shape `Raxol.Harness.Surface.open_jump_picker/1`'s labels already
  use) followed by ` · ` plus the block's BODY text, when that body
  carries content beyond what `summary/1` already shows -- `summary/1`
  only ever surfaces line 1 of message-shaped content, or the header
  fields (name/args, path) for the other kinds.

  Body per kind, read defensively from `block.content` (every field
  may be missing or `nil`; a non-map `content` degrades to the
  `kind · summary` prefix alone, same as a body that turns out empty):

    * `:message`, `:reasoning`, `:opaque` -- `content.text`, the FULL
      text (`summary/1` shows only its first line).
    * `:tool_call` -- `content.result` (`summary/1` already carries
      name + args).
    * `:approval` -- the FULL `content.action` (`summary/1` only shows
      its first line) plus `content.options`: a list whose BINARY
      entries are joined in. Non-binary entries (atoms, maps, anything
      else a producer might send) are skipped rather than risking a
      `to_string/1` call on an arbitrary term -- a named, honest
      limitation: a block whose options are atoms contributes no
      option text to the corpus.
    * `:diff` -- `content.old` and `content.new` (`summary/1` already
      carries the path).

  No sanitization happens here: `Raxol.Harness.Surface.ViewText.lines/3`
  is the ONE trust boundary for control-byte stripping and display-width
  truncation (see that module's moduledoc). Pure; never raises,
  regardless of `content`'s shape.

  ## Bounding the work (`max_graphemes`)

  `search_text/1` returns the FULL corpus (`max_graphemes: :infinity`).
  `search_text/2` bounds it: the clamp is applied AT THE SOURCE -- every
  body field is `String.slice`d to `max_graphemes` (which walks at most
  `max_graphemes` graphemes and stops, never scanning the tail) BEFORE
  it is concatenated or joined, and the assembled corpus is clamped once
  more. So a caller on a synchronous input path (see
  `Raxol.Harness.Surface.open_search_picker/1`) never pays O(body-size)
  to build a bounded label out of an unbounded, untrusted body -- the
  flatten/concat that used to run over the whole body now runs over at
  most `max_graphemes` graphemes. The named, honest consequence: body
  content past the cap is not part of the corpus (and so not
  searchable), same as before -- but now the *work*, not just the
  *output*, is bounded.
  """
  @spec search_text(t()) :: String.t()
  def search_text(block), do: search_text(block, :infinity)

  @spec search_text(t(), pos_integer() | :infinity) :: String.t()
  def search_text(%__MODULE__{kind: kind} = block, max_graphemes) do
    # Clamp the prefix too: `summary/1` returns line 1, but a single-line
    # body makes "line 1" the whole body, so an unclamped prefix would
    # re-introduce an O(body) concat below. `summary/1`'s own scan is the
    # accepted `open_jump_picker/1` baseline; clamping here keeps the
    # search path at parity with it, adding no unbounded term of its own.
    prefix = clamp_graphemes("#{kind} · #{summary(block)}", max_graphemes)

    case search_body_text(kind, search_content(block), max_graphemes) do
      body when is_binary(body) and body != "" ->
        clamp_graphemes(prefix <> " · " <> body, max_graphemes)

      _empty ->
        prefix
    end
  end

  defp search_content(%__MODULE__{content: content}) when is_map(content),
    do: content

  defp search_content(_block), do: %{}

  defp search_body_text(kind, content, max)
       when kind in [:message, :reasoning, :opaque],
       do: search_text_field(content, :text, max)

  defp search_body_text(:tool_call, content, max),
    do: search_text_field(content, :result, max)

  defp search_body_text(:approval, content, max) do
    join_search_parts(
      [
        search_text_field(content, :action, max),
        search_options_text(content, max)
      ],
      max
    )
  end

  defp search_body_text(:diff, content, max) do
    join_search_parts(
      [
        search_text_field(content, :old, max),
        search_text_field(content, :new, max)
      ],
      max
    )
  end

  defp search_body_text(_kind, _content, _max), do: nil

  # Clamp AT THE SOURCE: every field is bounded to `max` graphemes before
  # it is ever concatenated or joined, so no caller scans past the cap.
  defp search_text_field(content, key, max) do
    case Map.get(content, key) do
      text when is_binary(text) -> clamp_graphemes(text, max)
      _other -> nil
    end
  end

  defp search_options_text(content, max) do
    case Map.get(content, :options) do
      options when is_list(options) ->
        case Enum.filter(options, &is_binary/1) do
          [] -> nil
          strings -> clamp_graphemes(Enum.join(strings, " "), max)
        end

      _other ->
        nil
    end
  end

  defp join_search_parts(parts, max) do
    case Enum.reject(parts, &(&1 in [nil, ""])) do
      [] -> nil
      kept -> clamp_graphemes(Enum.join(kept, " "), max)
    end
  end

  defp clamp_graphemes(string, :infinity), do: string

  defp clamp_graphemes(string, max) when is_integer(max) and max >= 0,
    do: String.slice(string, 0, max)

  defp kind_label(raw_kind) when is_atom(raw_kind), do: Atom.to_string(raw_kind)
  defp kind_label(raw_kind) when is_binary(raw_kind), do: raw_kind
  defp kind_label(raw_kind), do: inspect(raw_kind)

  defp first_line(nil), do: "(empty)"

  defp first_line(text) when is_binary(text) do
    case text
         |> String.split("\n")
         |> Enum.find("", &(String.trim(&1) != "")) do
      "" -> "(empty)"
      line -> line
    end
  end

  defp first_line(other), do: first_line(to_display_text(other))

  # Args as a SPACE-led, unquoted `key: value` list -- V's ruling: no
  # braces, no quotes. `⚙ glob pattern: **/README*`, never
  # `⚙ glob(pattern: "**/README*")`. The leading space is emitted here (not
  # by the caller) so an empty arg set contributes NOTHING -- `⚙ name` with
  # no trailing space. Values render via `format_arg_value/1` (a binary
  # unquoted, newlines flattened to keep the collapsed line one row; any
  # other term still `inspect`ed for honesty). Callers (`tool_line/2`,
  # `summary/1`) concatenate directly onto the tool name.
  defp format_args(nil), do: ""
  defp format_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp format_args(args) when is_map(args) do
    body =
      args
      |> Enum.sort_by(fn {k, _v} -> arg_sort_key(k) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{format_arg_value(v)}" end)

    " " <> body
  end

  defp format_args(""), do: ""
  defp format_args(args) when is_binary(args), do: " " <> format_arg_value(args)
  defp format_args([]), do: ""
  defp format_args(args), do: " " <> inspect(args)

  # A binary value renders UNQUOTED (V's ruling), with newlines flattened
  # so a multi-line value (an edit tool's `new_string`) can never break the
  # single collapsed row -- the header's own truncation then trims the tail.
  # Any non-binary term is still `inspect`ed: an honest, unambiguous render
  # beats a lossy `to_string/1` on an arbitrary term.
  defp format_arg_value(v) when is_binary(v),
    do: String.replace(v, ~r/[\r\n]+/, " ")

  defp format_arg_value(v), do: inspect(v)

  # The referent leads: a path/file argument is WHAT the tool acts on, so it
  # sorts ahead of every other arg (a plain alphabetical sort put
  # `new_string` before `path` and let the header truncate the path away --
  # exactly backwards). Everything else keeps its alphabetical order behind
  # the lead key. The header's own `TextLayout.truncate(_, :ellipsis)` then
  # trims the TAIL (the bulky `new_string`/`content`), never the path.
  @arg_lead_keys ~w(path file filename file_path dir directory)

  defp arg_sort_key(key) do
    key_str = to_string(key)
    lead = if key_str in @arg_lead_keys, do: 0, else: 1
    {lead, key_str}
  end

  # Opt-in Markdown wire-in per `context[:markdown]`, message/reasoning
  # kinds only. When enabled, the block's text content is rendered by
  # `MarkdownBody` (`:sealed` full parse while sealed, `:streaming`
  # provisional-close while live) and then FADED to the same resolved
  # prominence colour as the header, so a faded header never sits above a
  # bright Markdown body. Every other combination -- markdown disabled,
  # or a non-message/reasoning kind -- falls through to the plain
  # per-line rendering unchanged.
  defp content_lines_view(
         %__MODULE__{kind: kind, content: %{text: _}} = block,
         width,
         context,
         fg
       )
       when kind in [:message, :reasoning] do
    body =
      if Map.get(context, :markdown, false) do
        [
          fade_view(
            MarkdownBody.render(markdown_source(block), %{
              width: width,
              mode: markdown_mode(block)
            }),
            fg
          )
        ]
      else
        plain_content_lines(block, fg)
      end

    case kind do
      :reasoning -> bracket_reasoning(body, fg)
      _message -> body
    end
  end

  # An edit/write approval carries the PROPOSED DIFF (`old`/`new`), so its
  # expanded body is the diff itself -- rendered through the ONE Pierre diff
  # engine (`DiffViewer.diff_rows/1`: syntax fg under diff bg, intra-line
  # word emphasis, gutter bars, hunk folding), NOT the compact one-line
  # register and NOT truncated args. The `± path` line leads (the referent,
  # path first), then the Pierre diff rows, then the tail (blast radius +
  # the live answer prompt / sealed receipt). Every other approval (bash,
  # ...) keeps its plain `tool:`/`args:` referent via `plain_content_lines`.
  # The diff render is block-level and mode-agnostic: the same flat rows
  # flatten identically in inline_log and full-viewport.
  defp content_lines_view(%__MODULE__{kind: :approval} = block, width, ctx, fg) do
    case approval_proposed_diff(block, width) do
      [] ->
        plain_content_lines(block, fg, ctx)

      diff_rows ->
        [approval_diff_header(block, fg) | diff_rows] ++
          approval_tail_lines(block, fg, ctx)
    end
  end

  defp content_lines_view(block, _width, _context, fg),
    do: plain_content_lines(block, fg)

  # An EXPANDED thought is bracketed by the because/therefore arrows: `∵`
  # opens (premises), `∴` closes (conclusion) -- reading like an arrow
  # through the reasoning. Both dim (the low-prominence cognition register,
  # matching the collapsed `⁖` header), each on its own line so the pair
  # frames the body exactly the way a folded thought's `⁖` marks it.
  defp bracket_reasoning(body, fg) do
    marker = fn glyph ->
      Components.text(content: glyph, style: apply_fg(%{dim: true}, fg))
    end

    [marker.(@reasoning_open_glyph) | body] ++ [marker.(@reasoning_close_glyph)]
  end

  # The Pierre diff rows for a proposed edit/write approval, or `[]` when
  # the approval carries no before/after image (bash and every other
  # non-file tool). Shared engine with the sealed `:diff` block's own
  # z-expanded body, so the diff the operator APPROVES is rendered by the
  # exact same code that renders the diff that gets SEALED after it runs.
  defp approval_proposed_diff(
         %__MODULE__{content: %{old: old, new: new} = content},
         width
       )
       when is_binary(old) and is_binary(new) do
    DiffViewer.diff_rows(
      path: to_display_text(Map.get(content, :path)),
      old: old,
      new: new,
      language: Map.get(content, :language),
      width: width
    )
  end

  defp approval_proposed_diff(_block, _width), do: []

  # `± path` leads the proposed diff (path-first, the referent), matching
  # the sealed `:diff` block's own `± path · +N -M` compact identity so the
  # two lifecycle stages of one edit read as the same thing.
  defp approval_diff_header(%__MODULE__{content: content}, fg) do
    path =
      case content |> Map.get(:path) |> to_display_text() do
        "" -> "(no path)"
        p -> p
      end

    Components.text(
      content:
        "#{kind_glyph(:diff)} #{path}" <>
          preview_match_note(Map.get(content, :preview_match)),
      style: apply_fg(%{}, fg)
    )
  end

  # When the producer could not locate the edit target exactly, the diff is
  # a PROPOSED change that will not apply as-is -- say so on the header,
  # honestly, rather than let a clean diff imply a clean apply. Plain text
  # (no emoji glyph -- the no-emoji register rule, see `glyph_inventory/0`).
  defp preview_match_note(m) when m in [:not_found, "not_found"],
    do: " · target not located (proposed)"

  defp preview_match_note(m) when m in [:ambiguous, "ambiguous"],
    do: " · target not unique (proposed)"

  defp preview_match_note(_exact), do: ""

  # The non-diff tail of a diff approval's body: the blast radius and then
  # the live answer prompt (numbered options + y/n aliases) or the sealed
  # decision receipt -- the same lines `body_lines(:approval)` builds for a
  # bash approval, minus the referent (the diff IS the referent here).
  defp approval_tail_lines(%__MODULE__{seal: seal, content: content}, fg, ctx) do
    (split_lines(Map.get(content, :blast_radius)) ++
       approval_resolution_lines(seal, content, ctx))
    |> Enum.map(fn line ->
      Components.text(content: line, style: apply_fg(%{}, fg))
    end)
  end

  defp markdown_source(%__MODULE__{content: %{text: text}}),
    do: to_display_text(text)

  # The seal->mode mapping lives in exactly one place --
  # `MarkdownBody.mode_for_seal/1` -- so this call site and
  # `BodyProvider`'s `:message` props can never drift apart.
  defp markdown_mode(%__MODULE__{seal: seal}),
    do: MarkdownBody.mode_for_seal(seal)

  # Recursively applies the resolved prominence colour to every text node
  # in a rendered view tree (the MarkdownBody result), so the Markdown
  # body fades in lockstep with the header/outcome. `nil` fg is the
  # neutral case -- the tree is returned byte-identical, so a
  # no-prominence markdown render is untouched.
  defp fade_view(view, nil), do: view

  defp fade_view(%{type: :text, style: style} = node, fg),
    do: %{node | style: apply_fg(style, fg)}

  defp fade_view(%{children: children} = node, fg),
    do: %{node | children: Enum.map(children, &fade_view(&1, fg))}

  defp fade_view(node, _fg), do: node

  defp plain_content_lines(block, fg, ctx \\ %{}) do
    block
    |> body_lines(ctx)
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      Components.text(
        id: line_id(block, idx),
        content: line,
        style: apply_fg(content_style(block.kind), fg)
      )
    end)
  end

  defp line_id(block, idx) do
    refs = Enum.map_join(block.event_refs, "-", &to_display_text/1)
    "block-#{refs}-line-#{idx}"
  end

  defp body_lines(
         %__MODULE__{kind: :tool_call, content: %{result: result}},
         _ctx
       ) do
    split_lines(result)
  end

  # A live approval renders the REFERENT (the exact tool + args the agent
  # will run), the blast radius, then the live prompt (numbered options +
  # the y/n aliases). A sealed approval renders the same referent + blast
  # radius, then the DECISION RECEIPT (who decided what, when) -- or, when
  # a turn was canceled while the question was still live, an honest
  # "canceled before answer" line. `seal` is the whole discriminator, so
  # this clause matches the full struct rather than the content map.
  defp body_lines(
         %__MODULE__{kind: :approval, seal: seal, content: content},
         ctx
       ) do
    referent_lines(content) ++
      split_lines(Map.get(content, :blast_radius)) ++
      approval_resolution_lines(seal, content, ctx)
  end

  defp body_lines(%__MODULE__{content: %{text: text}}, _ctx) do
    split_lines(text)
  end

  defp body_lines(_block, _ctx), do: []

  # The referent: what the agent will actually execute. Each line is
  # omitted when the producer did not carry that field (a producer that
  # only supplied a human-readable `action` shows no tool/args lines,
  # rather than empty "tool: " chrome).
  #
  # This is the PLAIN referent (tool + args) for a bash/other approval. An
  # edit/write approval carries the before/after image (`old`/`new`) and is
  # never routed here: its referent is the PROPOSED DIFF, rendered through
  # the Pierre engine as styled view rows by `content_lines_view/4`'s own
  # `:approval` clause (a string-line `body_lines` path could not carry the
  # diff's syntax fg / bg wash / gutter bars). So a diff approval never
  # reaches `body_lines(:approval)` at all.
  defp referent_lines(content), do: plain_referent_lines(content)

  defp plain_referent_lines(content) do
    [
      referent_line("tool: ", Map.get(content, :tool_name)),
      referent_line("args: ", Map.get(content, :args))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp referent_line(_label, nil), do: nil
  defp referent_line(_label, ""), do: nil
  defp referent_line(label, value), do: label <> to_display_text(value)

  # LIVE: the question is still open -- render the choices with their
  # answer keys so the operator can see exactly what pressing each key
  # does. Numbered options are the producer's actual options (the ACP
  # `PermissionOption` list); the y/n aliases pick the first allow/deny
  # option (see `Raxol.Harness.Surface`'s answer resolution).
  # When the hosting view runs its own footer selector (the TEA harness:
  # `selector_hosted?: true` in the render context), the in-body option
  # list would say the same thing twice — the block keeps the QUESTION
  # (referent/diff) and the selector owns the ANSWER affordance. Every
  # other host (Surface, standalone renders) keeps the in-body prompt.
  defp approval_resolution_lines(:live, content, ctx) do
    if Map.get(ctx, :selector_hosted?, false),
      do: [],
      else: approval_option_lines(Map.get(content, :options))
  end

  # SEALED: an answered (or canceled) question -- one receipt line. Deny is
  # as first-class as allow; a turn canceled before the answer (decision
  # `:cancel`, or absent because the turn ended without one) renders its
  # resolution honestly rather than pretending it was answered. The receipt
  # is never suppressed — it is the permanent record, not an affordance.
  defp approval_resolution_lines(:sealed, content, _ctx),
    do: [approval_receipt_line(content)]

  defp approval_option_lines(options) when is_list(options) and options != [] do
    numbered =
      options
      |> Enum.with_index(1)
      |> Enum.map(fn {opt, index} -> "[#{index}] " <> option_label(opt) end)

    [affordance_hint(options) | numbered]
  end

  defp approval_option_lines(_no_options),
    do: ["awaiting approval — no options offered"]

  # The answer affordances, built from the REAL options so the hint can
  # never claim a key the request does not actually offer (referent-honest):
  # `y` names the first allow-class option and `n` the first reject-class
  # one, each shown ONLY when such an option exists; the digit range covers
  # exactly the options present. So a request with no reject option shows no
  # `n deny`, and one with a single option shows only `1`.
  defp affordance_hint(options) do
    parts =
      option_key_hint("y", options, :allow) ++
        option_key_hint("n", options, :deny) ++
        ["1-#{length(options)} to choose"]

    "answer: " <> Enum.join(parts, " · ")
  end

  defp option_key_hint(key, options, want) do
    case Enum.find(options, &(option_decision(&1) == want)) do
      nil -> []
      option -> [key <> " " <> option_label(option)]
    end
  end

  # An option's decision class from its ACP kind -- MUST agree with
  # `Raxol.Harness.Surface`'s own `y`/`n` resolution (that module maps the
  # same kinds), so the hint the operator reads matches the key they press.
  defp option_decision(%{kind: kind}), do: kind_decision(kind)
  defp option_decision(%{"kind" => kind}), do: kind_decision(kind)
  defp option_decision(_option), do: nil

  defp kind_decision(k)
       when k in [:allow_once, :allow_always, "allow_once", "allow_always"],
       do: :allow

  defp kind_decision(k)
       when k in [:reject_once, :reject_always, "reject_once", "reject_always"],
       do: :deny

  defp kind_decision(_other), do: nil

  # Options arrive atom-keyed from internal producers AND string-keyed off
  # the wire (`%{"name" => "Allow", ...}`) — both shapes must label, or the
  # answer hint degrades to an inspect dump of the raw map.
  defp option_label(%{name: name}) when is_binary(name), do: name
  defp option_label(%{"name" => name}) when is_binary(name), do: name
  defp option_label(%{label: label}) when is_binary(label), do: label
  defp option_label(%{"label" => label}) when is_binary(label), do: label
  defp option_label(%{option_id: id}) when is_binary(id), do: id
  defp option_label(%{"option_id" => id}) when is_binary(id), do: id
  defp option_label(opt) when is_binary(opt), do: opt
  defp option_label(opt), do: to_display_text(opt)

  defp approval_receipt_line(content) do
    who = approval_actor(content)

    case normalize_decision(Map.get(content, :decision)) do
      :allow -> "✓ allowed" <> approval_scope_suffix(content) <> who
      :deny -> "✗ denied" <> who
      :cancel -> "⊘ canceled before answer"
      _unanswered -> "⊘ canceled before answer"
    end
  end

  # Reconciles the vocabulary drift across the request/answer/journal
  # layers: the UI/protocol answer uses `:allow`/`:deny`, the blast-radius
  # gate journal uses `:approved`/`:denied`. Both (and their wire-string
  # forms) fold to one render vocabulary here. Anything unrecognised (or
  # absent) is treated as "no decision" -> the canceled-before-answer line,
  # the fail-closed reading.
  defp normalize_decision(d) when d in [:allow, "allow", :approved, "approved"],
    do: :allow

  defp normalize_decision(d) when d in [:deny, "deny", :denied, "denied"],
    do: :deny

  defp normalize_decision(d) when d in [:cancel, "cancel", :cancelled],
    do: :cancel

  defp normalize_decision(_other), do: nil

  defp approval_scope_suffix(content) do
    case Map.get(content, :scope) do
      s when s in [:once, "once"] -> " (once)"
      s when s in [:session, "session"] -> " (session)"
      s when s in [:root, "root"] -> " (subtree)"
      _absent -> ""
    end
  end

  defp approval_actor(content) do
    case Map.get(content, :decided_by) do
      who when is_binary(who) and who != "" -> " by " <> who
      _absent -> ""
    end
  end

  defp split_lines(nil), do: []
  defp split_lines(""), do: []
  defp split_lines(text), do: text |> to_display_text() |> String.split("\n")

  @doc """
  Renders the completion-evidence row(s) for `block.content[:completion]`
  (see the moduledoc's "The completion row" section) -- one line, styled
  `%{dim: true}` faded to the same resolved `fg` the header/outcome rows
  carry (`nil` when prominence is absent/neutral, matching every other
  row's default). Public (unlike every other row helper in this module)
  so `Raxol.UI.Components.Harness.BlockBody`'s `:expanded` mount path can
  append the same row after a mounted real component's own view -- that
  module bypasses this render entirely once expanded, so the row would
  otherwise silently vanish for every kind except the plain-text fallback.

  Returns `[]` when the key is absent or its shape isn't recognised --
  byte-identical to a render that never carries a `:completion` key at
  all.

  Suppression policy (V field ruling, 2026-07-17): the caller may pass a
  render context carrying `turn_has_tools?: false` -- the Surface's own
  window-derived "no tool ran in this turn" fact -- and the ABSENCE row
  (only that row; evidence rows are never suppressed) renders as `[]`:
  on a pure chat turn no evidence could ever have existed, so "no
  evidence provided" is noise, not honesty. The policy lives HERE (the
  render layer) and never in the projection: the attached
  `%{evidence: :none}` marker is part of the offset-law-governed
  transcript identity and stays unconditional there. Absent the flag
  (or `turn_has_tools?: true`) the row renders -- fail-safe toward
  showing the alarm.
  """
  @spec completion_rows(t(), String.t() | nil, map()) :: [map()]
  def completion_rows(block, fg \\ nil, context \\ %{})

  def completion_rows(
        %__MODULE__{content: %{completion: %{evidence: :none}}},
        _fg,
        %{turn_has_tools?: false}
      ) do
    []
  end

  def completion_rows(
        %__MODULE__{content: %{completion: %{evidence: :none}}},
        fg,
        _context
      ) do
    [completion_text("no evidence provided", fg)]
  end

  def completion_rows(
        %__MODULE__{
          content: %{
            completion:
              %{
                evidence: entries,
                total: total,
                type_counts: type_counts
              } = completion
          }
        },
        fg,
        _context
      )
      when is_list(entries) do
    cross_turn_count = Map.get(completion, :cross_turn_count)

    summary =
      completion_text(
        completion_summary_line(total, type_counts, cross_turn_count),
        fg
      )

    entry_rows =
      Enum.map(entries, &completion_text(completion_entry_line(&1), fg))

    [summary | entry_rows] ++
      completion_more_row(total, entries, cross_turn_count, fg)
  end

  def completion_rows(%__MODULE__{}, _fg, _context), do: []

  defp completion_text(content, fg) do
    Components.text(content: content, style: apply_fg(%{dim: true}, fg))
  end

  # A cross-turn entry's line carries the literal "[cross-turn]" marker
  # -- the same-turn line shape is otherwise UNCHANGED (no-churn pin).
  defp completion_entry_line(%{label: label, cross_turn: true}),
    do: "· " <> label <> " [cross-turn]"

  defp completion_entry_line(%{label: label}), do: "· " <> label

  defp completion_summary_line(total, type_counts, cross_turn_count) do
    breakdown = Enum.map_join(type_counts, ", ", &completion_type_phrase/1)
    base = "#{total} #{pluralize("evidence ref", total)}: #{breakdown}"

    case cross_turn_count do
      n when is_integer(n) and n > 0 -> base <> " (#{n} cross-turn)"
      _no_cross_turn -> base
    end
  end

  defp completion_type_phrase(%{type: type, count: count}) do
    "#{count} #{pluralize(completion_type_label(type), count)}"
  end

  defp completion_type_label(:tool_result), do: "tool result"
  defp completion_type_label(:tool_use), do: "tool use"

  defp completion_type_label(other),
    do: other |> Atom.to_string() |> String.replace("_", " ")

  defp pluralize(word, 1), do: word
  defp pluralize(word, _other_count), do: word <> "s"

  defp completion_more_row(total, entries, cross_turn_count, fg) do
    remaining = total - length(entries)

    if remaining > 0 do
      suffix = hidden_cross_turn_suffix(entries, cross_turn_count)
      [completion_text("+#{remaining} more" <> suffix, fg)]
    else
      []
    end
  end

  # A cross-turn ref pushed past the entry cap is tallied in the summary
  # line but carries no visible "[cross-turn]" entry line of its own --
  # without this suffix the render would read as internally inconsistent
  # (a cross-turn count with zero marked lines). Hidden = the session-
  # wide tally minus the SHOWN entries that already carry their own
  # marker; when every cross-turn ref is visible (or there are none),
  # the tail row stays exactly "+N more".
  defp hidden_cross_turn_suffix(entries, cross_turn_count)
       when is_integer(cross_turn_count) do
    hidden =
      cross_turn_count - Enum.count(entries, &Map.get(&1, :cross_turn))

    if hidden > 0, do: " (#{hidden} cross-turn)", else: ""
  end

  defp hidden_cross_turn_suffix(_entries, _absent), do: ""

  # Which blocks still get the separate dim outcome row:
  #
  #   * `:tool_call` -- NEVER. The compact line's receipt already carries
  #     exit/duration/cost; a second row would be the two-line form this
  #     unit exists to remove.
  #   * `:reasoning` / `:diff`, folded -- never: the compact line IS the
  #     whole folded render (one-line law); expanded, the row returns
  #     (duration is peekable with the body).
  #   * everything else -- as before.
  defp outcome_children(%__MODULE__{kind: :tool_call}, _fg), do: []

  defp outcome_children(%__MODULE__{kind: kind, fold: :folded}, _fg)
       when kind in [:reasoning, :diff],
       do: []

  defp outcome_children(block, fg), do: outcome_row_view(block.outcome, fg)

  defp outcome_row_view(outcome, fg) do
    case outcome_parts(outcome) do
      [] ->
        []

      parts ->
        [
          Components.text(
            content: Enum.join(parts, " · "),
            style: apply_fg(%{dim: true}, fg)
          )
        ]
    end
  end

  # A live block that has not completed yet carries NO outcome (the struct
  # default is `nil`, and only a sealed round-trip fills the
  # `%{exit_code, duration_ms, cost}` map). `nil` -- or any non-map -- means
  # "no receipt to show", which renders as no outcome row, never a crash: a
  # `Map.get(nil, _)` here is `BadMapError: expected a map`, and an awaiting
  # `:approval` reaches this path with exactly that nil outcome.
  defp outcome_parts(outcome) when is_map(outcome) do
    [
      exit_part(Map.get(outcome, :exit_code)),
      duration_part(Map.get(outcome, :duration_ms)),
      cost_part(Map.get(outcome, :cost))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp outcome_parts(_absent), do: []

  defp exit_part(nil), do: nil
  defp exit_part(code) when is_integer(code), do: "exit #{code}"
  defp exit_part(code), do: "exit #{inspect(code)}"

  defp duration_part(nil), do: nil
  defp duration_part(ms) when is_number(ms), do: format_duration(ms)
  defp duration_part(ms), do: inspect(ms)

  defp cost_part(nil), do: nil

  defp cost_part(cost) when is_number(cost),
    do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)

  defp cost_part(cost), do: inspect(cost)

  defp format_duration(ms) when is_number(ms) and ms >= 1000,
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  defp format_duration(ms), do: "#{trunc(ms)}ms"

  defp to_display_text(nil), do: ""
  defp to_display_text(text) when is_binary(text), do: text
  defp to_display_text(other), do: inspect(other)

  # --- event/payload extraction (defensive: never assumes a key exists) -----

  @exit_code_paths [[:exit_code], [:content, :exit_code]]
  @cost_paths [[:cost], [:usage, :cost], [:content, :cost]]
  @duration_paths [[:duration_ms], [:content, :duration_ms]]
  @text_paths [[:content], [:text], [:output], [:diff]]
  # A fault's message: `reason` FIRST (the `:error` event's own payload
  # key), then the generic text keys as a defensive fallback. `where` is the
  # optional fault origin. Both are absent-tolerant (`find_in_events/2`
  # returns nil), so `error_line/1` degrades to its honest specific line.
  @error_text_paths [[:reason], [:message], [:content], [:text]]
  @where_paths [[:where], [:content, :where]]
  @role_paths [[:role], [:content, :role]]
  @name_paths [[:name], [:content, :name]]
  @args_paths [[:args], [:content, :args]]
  @action_paths [[:action]]
  @blast_radius_paths [[:blast_radius]]
  @options_paths [[:options]]
  # The REFERENT of an approval question -- the actual tool the agent will
  # run, not just a human-readable summary that could diverge from it (see
  # `extract_approval_content/1`'s "referent, not proxy" note). ACP carries
  # the tool identity inside its `tool_call`; the producer flattens it onto
  # the `approval_requested` payload so the block renders what the agent
  # will actually execute.
  @tool_name_paths [[:tool_name], [:content, :tool_name]]
  # The correlation id an answer must echo back so the agent can match the
  # response to the parked permission request. Carried on the block so the
  # surface's answer path reads it straight off the live block (the
  # referent), never a side-channel.
  @request_id_paths [[:request_id]]
  # The decision receipt, carried by the `approval_decided` event the
  # answer produces and folded into the SAME block by
  # `Raxol.Harness.Projection.BlockBuilder`. Every field is absent on a
  # still-live approval -- read defensively, staying `nil` until answered.
  @decision_paths [[:decision]]
  @option_id_paths [[:option_id]]
  @scope_paths [[:scope]]
  @decided_by_paths [[:decided_by]]
  @decided_at_paths [[:decided_at]]
  @path_paths [[:path], [:content, :path]]
  @old_paths [[:old], [:content, :old]]
  @new_paths [[:new], [:content, :new]]
  @language_paths [[:language], [:content, :language]]
  @preview_match_paths [[:preview_match], [:content, :preview_match]]

  defp event_refs(events) when is_list(events) do
    Enum.map(events, fn
      event when is_map(event) -> Map.get(event, :id)
      _other -> nil
    end)
  end

  defp event_refs(_events), do: []

  defp extract_outcome(events) do
    %{
      exit_code: find_in_events(events, @exit_code_paths),
      duration_ms:
        duration_from_timestamps(events) ||
          find_in_events(events, @duration_paths),
      cost: find_in_events(events, @cost_paths)
    }
  end

  defp duration_from_timestamps(events) do
    with start_ts when is_integer(start_ts) <- event_ts(events, :item_started),
         end_ts when is_integer(end_ts) <- event_ts(events, :item_completed),
         true <- end_ts >= start_ts do
      div(end_ts - start_ts, 1000)
    else
      _ -> nil
    end
  end

  defp event_ts(events, type) do
    case find_event_by_type(events, type) do
      event when is_map(event) -> Map.get(event, :ts)
      _other -> nil
    end
  end

  defp find_event_by_type(events, type) when is_list(events) do
    Enum.find(events, fn
      event when is_map(event) -> Map.get(event, :type) == type
      _other -> false
    end)
  end

  defp find_event_by_type(_events, _type), do: nil

  defp extract_content(:tool_call, events),
    do: extract_tool_call_content(events)

  defp extract_content(:approval, events), do: extract_approval_content(events)
  defp extract_content(:diff, events), do: extract_diff_content(events)

  defp extract_content(:message, events),
    do: %{text: extract_text(events), role: extract_role(events)}

  # A fault carries its message on `reason` (see `Raxol.Agent.Contract`'s
  # `:error` event), and MAY carry a `where`. Both are read here so
  # `error_line/1` can render the honest message (with a `where`-named
  # fallback), instead of the generic `@text_paths` extraction that never
  # read `reason` and produced the `[error] (empty)` regression.
  defp extract_content(:error, events),
    do: %{
      text: events |> find_in_events(@error_text_paths) |> to_display_text(),
      where: find_in_events(events, @where_paths)
    }

  defp extract_content(_kind, events), do: %{text: extract_text(events)}

  # Speaker attribution for `:message` blocks, read defensively from the
  # source events' payloads (`role` -- contract-only-grows: producers that
  # never send it keep working). The normalization direction is a safety
  # decision, not a convenience: the user echo is a claim of AUTHORSHIP
  # ("you said this"), so mislabeling machine output as the user is the
  # harmful direction. Anything that is not an exact user marker --
  # absent, unknown, or hostile (an ESC-prefixed "user" with control
  # bytes smuggled in) -- resolves `:assistant`, the unmarked voice.
  defp extract_role(events) do
    events |> find_in_events(@role_paths) |> normalize_role()
  end

  defp normalize_role(:user), do: :user
  defp normalize_role("user"), do: :user
  defp normalize_role(_other), do: :assistant

  defp extract_text(events) do
    events
    |> preferred_events()
    |> find_in_events(@text_paths)
    |> to_display_text()
  end

  defp preferred_events(events) when is_list(events) do
    events
    |> Enum.filter(&(event_type(&1) == :item_completed))
    |> case do
      [] -> events
      completed -> completed
    end
    |> Enum.reverse()
  end

  defp preferred_events(_events), do: []

  defp event_type(event) when is_map(event), do: Map.get(event, :type)
  defp event_type(_event), do: nil

  defp extract_tool_call_content(events) do
    name = events |> find_in_events(@name_paths) |> to_display_text()
    args = find_in_events(events, @args_paths)
    result = tool_result_content(events)
    tainted? = find_taint(events)

    %{name: name, args: args, result: result, tainted: tainted?}
  end

  defp tool_result_content(events) when is_list(events) do
    events
    |> Enum.filter(&(payload_get(&1, [:item_type]) == :tool_result))
    |> List.last()
    |> case do
      nil -> nil
      event -> event |> payload_get([:content]) |> to_display_text()
    end
  end

  defp tool_result_content(_events), do: nil

  defp find_taint(events) when is_list(events) do
    Enum.any?(events, &(event_get(&1, [:provenance, :trust]) == :tainted))
  end

  defp find_taint(_events), do: false

  # An approval block folds TWO events when answered: the
  # `approval_requested` (the question -- action/tool/args/options) and the
  # `approval_decided` (the receipt -- decision/option/who/when). Both are
  # searched by `find_in_events/2`; the request carries no decision key and
  # the decision carries no action key, so first-match extraction keeps
  # them cleanly separated. A still-live approval folds only the request,
  # leaving every decision field `nil` -- which is exactly how `Block`'s
  # own render distinguishes a pending question from an answered one.
  #
  # `tool_name`/`args` are the REFERENT, not a proxy: the block renders the
  # exact tool + arguments the agent will run, never a summary that could
  # drift from what actually executes. `action` stays the human-readable
  # gloss; the two coexist.
  defp extract_approval_content(events) do
    action = events |> find_in_events(@action_paths) |> to_display_text()
    # No `|| %{}` fallback here: a blast radius no producer ever supplied
    # must stay distinguishable from one a producer explicitly declares
    # empty. `nil` means "not declared" --
    # `Raxol.UI.Components.Harness.BlastRadiusPreview` renders that as its
    # own explicit "not declared, treat as unsafe" warning rather than the
    # calm "No tracked effects." line it renders for a genuine `%{}`.
    blast_radius = find_in_events(events, @blast_radius_paths)
    options = find_in_events(events, @options_paths) || []

    %{
      action: action,
      request_id: find_in_events(events, @request_id_paths),
      tool_name: find_in_events(events, @tool_name_paths),
      args: find_in_events(events, @args_paths),
      blast_radius: blast_radius,
      options: options,
      # The PROPOSED DIFF (edit_file/write_file): when the producer computed
      # the before/after image at approval time it lifts `path`/`old`/`new`
      # here (the same field names `extract_diff_content/1` uses), so the
      # block can render exactly what `y` will do -- the consequences of the
      # answer, not truncated args. Absent for a bash/other approval, which
      # keeps its command line as the referent.
      path: find_in_events(events, @path_paths),
      old: find_in_events(events, @old_paths),
      new: find_in_events(events, @new_paths),
      language: find_in_events(events, @language_paths),
      # `:exact | :not_found | :ambiguous` -- when the producer could not
      # locate the edit target exactly, the diff is a PROPOSED change that
      # will NOT apply as-is; the approval body says so rather than showing
      # a clean diff that lies about what `y` will do (see
      # `approval_diff_header/2`).
      preview_match: find_in_events(events, @preview_match_paths),
      decision: find_in_events(events, @decision_paths),
      option_id: find_in_events(events, @option_id_paths),
      scope: find_in_events(events, @scope_paths),
      decided_by: find_in_events(events, @decided_by_paths),
      decided_at: find_in_events(events, @decided_at_paths)
    }
  end

  # No producer resolves the `:diff` kind yet (T7's BlockBuilder only ever
  # emits :message/:reasoning/:tool_call/:approval; see
  # `Raxol.Harness.Projection.BlockBuilder`) -- there is no wire convention
  # to conform to. `:path`/`:old`/`:new`/`:language` mirror
  # `Raxol.UI.Components.Harness.DiffViewer`'s own prop names (T5's
  # BodyProvider content-map contract), the component this content feeds.
  # A flat `:text` field (the generic fallback every other kind gets)
  # cannot carry old-vs-new distinctly, so `:diff` needs its own shape.
  defp extract_diff_content(events) do
    %{
      path: events |> find_in_events(@path_paths) |> to_display_text(),
      old: events |> find_in_events(@old_paths) |> to_display_text(),
      new: events |> find_in_events(@new_paths) |> to_display_text(),
      language: find_in_events(events, @language_paths)
    }
  end

  defp find_in_events(events, paths) when is_list(events) do
    Enum.find_value(events, fn event ->
      Enum.find_value(paths, fn path -> payload_get(event, path) end)
    end)
  end

  defp find_in_events(_events, _paths), do: nil

  defp payload_get(event, path) when is_map(event) do
    event |> Map.get(:payload) |> safe_get_in(path)
  end

  defp payload_get(_event, _path), do: nil

  defp event_get(event, path) when is_map(event), do: safe_get_in(event, path)
  defp event_get(_event, _path), do: nil

  defp safe_get_in(nil, _path), do: nil
  defp safe_get_in(map, [key]) when is_map(map), do: Map.get(map, key)

  defp safe_get_in(map, [key | rest]) when is_map(map),
    do: safe_get_in(Map.get(map, key), rest)

  defp safe_get_in(_value, _path), do: nil
end
