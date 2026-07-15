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
  tolerance is deliberate: the contract only grows (methodology R6), and
  this module must never crash when it meets a field it doesn't know yet.

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
  chooses (B) soft-owned history or (C) live-region-only with a wider live
  window; leave the default `:deny` for (A) seal-time-only.

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
  `[:raxol, :harness, :projection, :recovered]` with metadata
  `%{kind:, reason:}` -- a recovery is never silent.

  ## Rendering

  `render/2` returns a plain view map (`%{type: :column, ...}`), no
  interactive `Base.Component` behaviour -- this unit renders plain text
  bodies only. T5 mounts the rich per-kind components (already merged:
  `Harness.MessageBlock`, `Harness.ReasoningBlock`, `Harness.ToolCallBlock`,
  `Harness.ToolResultBlock`, `Harness.DiffViewer`, `Harness.ApprovalPrompt`,
  ...) as the fold-aware block bodies; this module is the data + text-only
  fallback layer underneath that.

  Expanded render = header line (fold glyph + kind glyph + first-line
  summary) + full content lines + an outcome row. Folded render = the header
  line alone + the outcome row. The outcome row is omitted entirely when
  `exit_code`, `duration_ms`, and `cost` are all `nil`; otherwise it renders
  only the fields that are present.

  ## Prominence (T8)

  `context[:prominence]` (`0.0..1.0`) resolves the header/content/outcome
  text colors through `Raxol.UI.Harness.Prominence` -- the H-K salience
  solver, ground-aware. `context[:ground]` overrides the ground lightness
  (default: OSC-11-detected, see
  `Raxol.UI.Theming.SalienceTheme.detect_ground/0`).
  `context[:legibility_floor]` (default `false`) is threaded through to
  `Prominence.resolve/3`: the default is the **pure salience-gradient
  fade** (context text recedes, legible on promotion); T9 sets it `true`
  only for acting / interactive tiers where blind-reading risk lives (see
  the `Prominence` moduledoc's "Two modes"). **Default is neutral**: when
  `:prominence` is absent from `context`, or is `1.0`, no style is touched
  -- the render is byte-identical to a pre-T8 render (no `:fg` added to any
  style map). This is deliberate (roadmap unit T8's regression guard,
  SAL-P-06): existing callers that never pass `:prominence` see zero change.
  """

  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  require Logger

  @recovered_telemetry_event [:raxol, :harness, :projection, :recovered]

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

  @spec folded?(t()) :: boolean()
  def folded?(%__MODULE__{fold: :folded}), do: true
  def folded?(%__MODULE__{}), do: false

  # --- render -----------------------------------------------------------

  @doc """
  Renders `block` as a plain view map. `context[:width]` sets the wrap/
  truncation budget (defaults to `Raxol.Core.Defaults.terminal_width/0`).
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
    header = header_view(block, width, context)
    outcome_children = outcome_row_view(block.outcome, context)

    body_children =
      case block.fold do
        :folded -> [header]
        :expanded -> [header | content_lines_view(block, context)]
      end

    Components.column(gap: 0, children: body_children ++ outcome_children)
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

  defp header_view(block, width, context) do
    prefix = "#{fold_icon(block.fold)} #{kind_glyph(block.kind)} "
    budget = max(width - TextMeasure.display_width(prefix), 1)
    summary_text = block |> summary() |> TextLayout.truncate(budget, :ellipsis)

    Components.text(
      content: prefix <> summary_text,
      style: prominence_style(header_style(block.kind), context)
    )
  end

  # Chrome neutral baseline (matches DiffViewer's `@chrome_base_fg`) faded
  # per `context[:prominence]` through the T8 mapping layer. Absent or 1.0
  # prominence is a no-op (see moduledoc "Prominence (T8)" -- SAL-P-06).
  @chrome_fg "#B4B4B4"

  defp prominence_style(style, context) do
    case prominence_fg(context) do
      nil -> style
      fg -> Map.put(style, :fg, fg)
    end
  end

  defp prominence_fg(context) do
    case Map.get(context, :prominence, 1.0) do
      p when is_number(p) and p >= 1.0 ->
        nil

      p when is_number(p) ->
        Prominence.resolve(@chrome_fg, p, prominence_opts(context))

      _other ->
        nil
    end
  end

  # Only pass `:ground` through when the caller actually supplied one --
  # `Prominence.resolve/3` defaults it lazily (OSC-11-detected, else the
  # solver's reference ground), and an explicit `ground: nil` would
  # short-circuit that default. `:legibility_floor` is threaded through when
  # present (T9 sets it true for acting tiers; default false = pure fade).
  defp prominence_opts(context) do
    []
    |> put_opt(:ground, Map.get(context, :ground))
    |> put_opt(:legibility_floor, Map.get(context, :legibility_floor))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  defp fold_icon(:folded), do: "▸"
  defp fold_icon(_fold), do: "▾"

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

  defp summary(%__MODULE__{
         kind: :tool_call,
         content: %{name: name, args: args}
       }) do
    name <> format_args(args)
  end

  defp summary(%__MODULE__{kind: :approval, content: %{action: action}}) do
    first_line(action)
  end

  defp summary(%__MODULE__{
         kind: :opaque,
         raw_kind: raw_kind,
         content: %{text: text}
       }) do
    "[#{kind_label(raw_kind)}] " <> first_line(text)
  end

  defp summary(%__MODULE__{content: %{text: text}}) do
    first_line(text)
  end

  defp summary(_block), do: "(empty)"

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

  defp content_lines_view(block, context) do
    block
    |> body_lines()
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      Components.text(
        id: line_id(block, idx),
        content: line,
        style: prominence_style(content_style(block.kind), context)
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

  defp outcome_row_view(outcome, context) do
    case outcome_parts(outcome) do
      [] ->
        []

      parts ->
        [
          Components.text(
            content: Enum.join(parts, " · "),
            style: prominence_style(%{dim: true}, context)
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
  @name_paths [[:name], [:content, :name]]
  @args_paths [[:args], [:content, :args]]
  @action_paths [[:action]]
  @blast_radius_paths [[:blast_radius]]
  @options_paths [[:options]]

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
  defp extract_content(_kind, events), do: %{text: extract_text(events)}

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
    blast_radius = find_in_events(events, @blast_radius_paths)
    options = find_in_events(events, @options_paths) || []

    %{action: action, blast_radius: blast_radius, options: options}
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
