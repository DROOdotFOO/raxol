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

  This unit renders into a plain view map, same as every component in this
  package (`Raxol.View.Components`-shaped, buffer-testable without a real
  terminal) -- no I/O of its own.
  """

  alias Raxol.UI.Components.Harness.{Block, BodyProvider}

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

  def render(%Block{fold: :expanded} = block, context) do
    case mount_body(block, context) do
      {:ok, view} ->
        view

      {:error, reason} ->
        emit_recovered(block.kind, reason)
        Block.render(block, context)
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
      outcome: block.outcome
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
