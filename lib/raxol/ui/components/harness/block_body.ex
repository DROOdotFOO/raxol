defmodule Raxol.UI.Components.Harness.BlockBody do
  @moduledoc """
  T5's fold-aware entry point: renders a `%Raxol.UI.Components.Harness.Block{}`
  as its real, merged per-kind component when expanded, and as `Block`'s own
  proven one-line-summary-plus-outcome-row when folded.

  Per `harness-ui-roadmap.md`'s T5 accept criteria ("each block kind renders
  its component; folded forms show one-line summary + outcome row") and the
  D-PA note carried in `Block`'s own moduledoc ("fold semantics post-seal are
  policy... T5 just renders whatever fold state the block carries"): this
  module never re-derives or re-emits fold state, it only reads
  `block.fold` and picks a rendering strategy.

    * `:folded`   -- delegates to `Block.render/2` unchanged. That render
      is already exactly "header line (fold glyph + kind glyph + summary)
      + outcome row" -- reusing it means the folded form is never a second,
      possibly-drifting implementation of the same summary.
    * `:expanded` -- mounts the real component via
      `Raxol.UI.Components.Harness.BodyProvider.mount/3`. On any mount
      failure (schema violation, unknown kind, wrong-kind refusal) *or* an
      uncaught raise from inside the mounted component's `init/1`/`render/2`
      (a bad-shaped-but-present prop -- `BodyProvider.validate/2` only
      checks key presence, never a value's inner shape, see its moduledoc)
      this falls back to `Block.render/2` -- the same total-safety contract
      `Block` itself keeps for its own render/construction failures -- and
      emits the matching telemetry/log, so a fallback is never silent. The
      rescue lives HERE, at this module's own boundary, not inside
      `BodyProvider.mount/3`: this is the module whose moduledoc makes the
      total-safety promise, and `BodyProvider` stays a pure, independently
      test-facing schema seam with no defensive try/rescue of its own.

  ## The completion row survives the expanded mount

  A successfully mounted component's view REPLACES `Block.render/2`'s own
  body entirely -- which would otherwise silently drop
  `Block.completion_rows/2`'s honesty row (see `Block`'s moduledoc, "The
  completion row") for every kind except the opaque/plain-text fallback.
  When the mount succeeds AND `block.content` carries a `:completion` key,
  `render/2` wraps the mounted view and the completion row(s) in one
  `Components.column/1` (unfaded -- `%{dim: true}` only, no prominence
  threading through this seam, kept simple per T5's own scope). A block
  with no `:completion` key mounts and renders exactly as before, no
  wrapping at all -- byte-identical to today's render.

  This unit renders into a plain view map, same as every component in this
  package (`Raxol.View.Components`-shaped, buffer-testable without a real
  terminal) -- no I/O of its own.
  """

  alias Raxol.UI.Components.Harness.{Block, BodyProvider}
  alias Raxol.View.Components

  require Logger

  @recovered_telemetry_event [:raxol, :harness, :block_body, :recovered]

  @doc """
  Renders `block`'s body. `context` is threaded to `Block.render/2` (folded
  case) and to `BodyProvider.mount/3` (expanded case) unchanged; the
  expanded case also passes `block.outcome` through for `:tool_call`'s
  status derivation (see `BodyProvider.mount/3`'s `:outcome` option).
  """
  @spec render(Block.t(), map()) :: map()
  def render(block, context \\ %{})

  def render(%Block{fold: :folded} = block, context),
    do: Block.render(block, context)

  # The machinery register (tool calls, reasoning) is Block.render/2's own
  # in BOTH fold states: folded is the compact one-line form (glyph +
  # referent + receipt), expanded is that same line plus the full dim body
  # -- never a mounted component pair with its own "Tool Result" header
  # (the two-block form this rendering unit removed). `:diff` keeps its
  # mounted DiffViewer as the expanded form (the ± body is the artifact);
  # its folded form is Block's compact `± path · +N -M` line via the
  # folded clause above.
  #
  # `:error` is Block.render/2's own too: its compact alarm line (`✗
  # <message>`, no fold arrow, non-dim) has no mounted-component form -- a
  # fault is a visible line, never a foldable widget, and expanded just
  # appends the full multi-line message. (`ErrorBlock`, the bordered-box
  # component, is a separate standalone widget, not this transcript's
  # inline fault render.)
  def render(%Block{kind: kind} = block, context)
      when kind in [:tool_call, :reasoning, :error],
      do: Block.render(block, context)

  # An edit/write approval carrying a proposed diff (`old`/`new`) is
  # Block.render/2's own in the expanded state too: `Block`'s `:approval`
  # content_lines_view renders the FULL proposed diff through the ONE Pierre
  # engine (`DiffViewer.diff_rows/1`) plus the live answer prompt -- the
  # operator's question is "what will `y` do", and the answer is the diff,
  # never `ApprovalPrompt`'s modal action line (which would show a truncated
  # args gloss, not the change). A bash / non-diff approval has no image to
  # show and keeps its mounted `ApprovalPrompt` via the general clause below.
  def render(%Block{fold: :expanded, kind: :approval} = block, context) do
    # `selector_hosted?` (the TEA harness): the hosting view runs its own
    # footer answer prompt, so the bash/non-diff approval must NOT mount
    # `ApprovalPrompt` (whose "Choose a response" list is a second answer
    # surface) — `Block.render/2` shows referent + blast radius and its
    # `approval_resolution_lines/3` already yields under the same flag.
    if approval_has_diff?(block) or Map.get(context, :selector_hosted?, false) do
      Block.render(block, context)
    else
      expanded_mount(block, context)
    end
  end

  def render(%Block{fold: :expanded} = block, context),
    do: expanded_mount(block, context)

  defp approval_has_diff?(%Block{content: %{old: old, new: new}})
       when is_binary(old) and is_binary(new),
       do: true

  defp approval_has_diff?(_block), do: false

  defp expanded_mount(block, context) do
    case mount_body(block, context) do
      {:ok, view} ->
        wrap_with_completion(view, block, context)

      {:error, reason} ->
        emit_recovered(block.kind, reason)
        Block.render(block, context)
    end
  end

  # A mounted component's view replaces Block.render/2's whole body, so
  # the completion row (otherwise only reachable through that render)
  # has to be re-appended here. Byte-identical, no wrapping at all, when
  # `Block.completion_rows/2` has nothing to add -- both when
  # `block.content` carries no `:completion` key AND when it carries one
  # in a shape `completion_rows/2` doesn't recognise (that helper's own
  # contract: unrecognised shape -> `[]`). Computing `rows` FIRST and
  # branching on it (rather than pattern-matching on the mere presence of
  # the `:completion` key, as an earlier version of this function did) is
  # what keeps this module's own "byte-identical when there is nothing to
  # add" promise honest for that unrecognised-shape case too -- see the
  # moduledoc.
  # `context` is threaded so the absence-row suppression flag
  # (`turn_has_tools?`, see Block.completion_rows/3) reaches the row on
  # the mounted-component path too -- both fold states must obey one
  # policy.
  defp wrap_with_completion(view, %Block{} = block, context) do
    case Block.completion_rows(block, nil, context) do
      [] -> view
      rows -> Components.column(gap: 0, children: [view | rows])
    end
  end

  # The single point where a mounted component's own `init/1`/`render/2`
  # runs (via `BodyProvider.mount/3`) -- a raise here (e.g. a schema-valid
  # but wrong-shaped prop reaching a component's own guard/pattern match,
  # see the moduledoc's `:expanded` note) is converted into the SAME
  # `{:error, reason}` shape `BodyProvider.mount/3` already returns for its
  # own failures, so `render/2`'s `case` above needs no raise-specific
  # branch: one fallback path handles every mount failure. `reason` stays a
  # plain `String.t()` (matching `BodyProvider.mount/3`'s own spec) and
  # names the exception module + message, so `emit_recovered/2`'s existing
  # Logger.warning/telemetry call surfaces it without any change of its
  # own -- the exception module is right there in the recovered reason.
  defp mount_body(block, context) do
    BodyProvider.mount(block.kind, block.content,
      context: context,
      outcome: block.outcome,
      # threads the block's own seal so a live :message body streams with
      # provisional close instead of a plain full parse -- see
      # `BodyProvider.mount/3`'s `:seal` option doc.
      seal: block.seal
    )
  rescue
    e ->
      {:error,
       "component raised #{inspect(e.__struct__)}: #{Exception.message(e)}"}
  end

  defp emit_recovered(kind, reason) do
    Logger.warning(
      "Harness.BlockBody fell back to Block.render/2 for #{inspect(kind)}: #{reason}"
    )

    :telemetry.execute(@recovered_telemetry_event, %{}, %{
      kind: kind,
      reason: reason
    })
  end
end
