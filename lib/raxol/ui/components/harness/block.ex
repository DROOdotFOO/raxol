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

  `render/2` returns a plain view map (`%{type: :column, ...}`), no
  interactive `Base.Component` behaviour -- this unit renders plain text
  bodies only. T5 mounts the rich per-kind components (already merged:
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

  alias Raxol.UI.Components.Harness.MarkdownBody
  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  require Logger

  @recovered_telemetry_event [:raxol, :harness, :block, :recovered]

  @type kind :: :message | :reasoning | :tool_call | :diff | :approval | :opaque
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

  @known_kinds [:message, :reasoning, :tool_call, :diff, :approval]

  @default_fold_by_kind %{
    message: :expanded,
    reasoning: :folded,
    tool_call: :expanded,
    diff: :folded,
    approval: :expanded,
    opaque: :expanded
  }

  @default_fold_after_seal :deny

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
      emit_recovered(kind, e)
      opaque_fallback(kind, events, opts)
  end

  defp normalize_kind(kind) when kind in @known_kinds, do: kind
  defp normalize_kind(_kind), do: :opaque

  defp emit_recovered(kind, exception) do
    reason = Exception.message(exception)

    Logger.warning(
      "Harness.Block recovered from #{inspect(kind)} projection failure: #{reason}"
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
    build_render(block, width, context)
  rescue
    e ->
      emit_recovered(block.kind, e)
      render_fallback(block)
  end

  defp build_render(block, width, context) do
    # Resolve the prominence fade colour ONCE per render (nil = neutral,
    # no fade), then thread it into every text-producing branch --
    # header, content, and outcome all carry the SAME `:fg`, and the
    # per-line content map never re-runs the H-K solver.
    fg = prominence_fg(block, context)
    header = header_view(block, width, fg)
    outcome_children = outcome_row_view(block.outcome, fg)
    completion_children = completion_rows(block, fg, context)

    body_children =
      case block.fold do
        :folded -> [header]
        :expanded -> [header | content_lines_view(block, width, context, fg)]
      end

    Components.column(
      gap: 0,
      children: body_children ++ outcome_children ++ completion_children
    )
  end

  defp render_fallback(block) do
    Components.column(
      gap: 0,
      children: [
        Components.text(
          content: "[unrenderable #{inspect(block.kind)} block]",
          style: %{dim: true}
        )
      ]
    )
  end

  defp header_view(block, width, fg) do
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

  @doc """
  The block's resolved prominence fade colour (`"#RRGGBB"`), or `nil`
  when `context[:prominence]` is absent, `1.0`, or not a number -- the
  neutral case every row helper leaves styles untouched for. This is the
  ONE solver call every faded row of a block shares (see the moduledoc's
  "Prominence" section). Public so `Raxol.Harness.Surface`'s user-echo
  sigil can carry the SAME resolved colour as the block it prefixes
  (single-fg rule: the chevron fades with its block, never staying
  anchor-bright over demoted text).
  """
  @spec prominence_fg(t(), map()) :: String.t() | nil
  def prominence_fg(block, context) do
    case Map.get(context, :prominence, 1.0) do
      p when is_number(p) and p >= 1.0 ->
        nil

      p when is_number(p) ->
        Prominence.resolve(@chrome_fg, p, prominence_opts(block, context))

      _other ->
        nil
    end
  end

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

  defp header_style(:reasoning), do: %{dim: true}
  defp header_style(:opaque), do: %{dim: true}
  defp header_style(_kind), do: %{}

  defp content_style(:reasoning), do: %{dim: true}
  defp content_style(:opaque), do: %{dim: true}
  defp content_style(_kind), do: %{}

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

  defp format_args(nil), do: ""
  defp format_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp format_args(args) when is_map(args) do
    body =
      args
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

    "(#{body})"
  end

  defp format_args(""), do: ""
  defp format_args(args) when is_binary(args), do: "(#{args})"
  defp format_args([]), do: ""
  defp format_args(args), do: "(#{inspect(args)})"

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
    if Map.get(context, :markdown, false) do
      body =
        MarkdownBody.render(markdown_source(block), %{
          width: width,
          mode: markdown_mode(block)
        })

      [fade_view(body, fg)]
    else
      plain_content_lines(block, fg)
    end
  end

  defp content_lines_view(block, _width, _context, fg),
    do: plain_content_lines(block, fg)

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

  defp plain_content_lines(block, fg) do
    block
    |> body_lines()
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

  defp body_lines(%__MODULE__{kind: :tool_call, content: %{result: result}}) do
    split_lines(result)
  end

  defp body_lines(%__MODULE__{
         kind: :approval,
         content: %{blast_radius: br, options: options}
       }) do
    split_lines(br) ++ options_lines(options)
  end

  defp body_lines(%__MODULE__{content: %{text: text}}) do
    split_lines(text)
  end

  defp body_lines(_block), do: []

  defp options_lines(nil), do: []
  defp options_lines([]), do: []

  defp options_lines(options) when is_list(options) do
    ["options: " <> Enum.map_join(options, ", ", &to_display_text/1)]
  end

  defp options_lines(other), do: ["options: " <> to_display_text(other)]

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

  defp outcome_parts(outcome) do
    [
      exit_part(Map.get(outcome, :exit_code)),
      duration_part(Map.get(outcome, :duration_ms)),
      cost_part(Map.get(outcome, :cost))
    ]
    |> Enum.reject(&is_nil/1)
  end

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
  @role_paths [[:role], [:content, :role]]
  @name_paths [[:name], [:content, :name]]
  @args_paths [[:args], [:content, :args]]
  @action_paths [[:action]]
  @blast_radius_paths [[:blast_radius]]
  @options_paths [[:options]]
  @path_paths [[:path], [:content, :path]]
  @old_paths [[:old], [:content, :old]]
  @new_paths [[:new], [:content, :new]]
  @language_paths [[:language], [:content, :language]]

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

  defp extract_content(_kind, events), do: %{text: extract_text(events)}

  # Speaker attribution for `:message` blocks, read defensively from the
  # source events' payloads (`role` -- contract-only-grows: producers that
  # never send it keep working). The normalization direction is a safety
  # decision, not a convenience: the user echo is a claim of AUTHORSHIP
  # ("you said this"), so mislabeling machine output as the user is the
  # harmful direction. Anything that is not an exact user marker --
  # absent, unknown, or hostile (`"\e[2Juser"`) -- resolves `:assistant`,
  # the unmarked voice.
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

    %{action: action, blast_radius: blast_radius, options: options}
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
