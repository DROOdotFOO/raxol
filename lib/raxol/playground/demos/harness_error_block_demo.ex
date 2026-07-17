defmodule Raxol.Playground.Demos.HarnessErrorBlockDemo do
  @moduledoc """
  Playground demo: the harness `:error` and `:opaque` blocks on the
  CURRENT render contract (`Raxol.UI.Components.Harness.Block`).

  ## The error-kind decision, documented (harness TEA migration sec 7)

  The spec left "wire ErrorBlock to a kind?" open; the tool-render unit
  decided it: **`:error` is a first-class `Block` kind** (in
  `Block.known_kinds/0` and the fold defaults). A fault renders as an
  ALARM LINE -- `✗ <real message>` -- never the dim machinery register
  and never a fold-arrowed `◆ [error] (empty)` opaque: the message is
  read honestly from the fault payload (`reason`, then the generic text
  keys), with an honest specific fallback when the fault truly carries
  none. `Raxol.UI.Components.Harness.ErrorBlock` (the bordered-box
  widget) stays a standalone Component; the transcript's inline fault
  render is `Block`'s own alarm line. This demo hosts that ruling:

    * `err_full`  -- a real multi-line fault: the alarm line is the
      fault's first line, `[z]` peeks the full body;
    * `err_where` -- no message, but a `where`: `✗ error from <where>`;
    * `err_bare`  -- no message at all: `✗ error (no message)` --
      the absence is information, never a bare `(empty)`;
    * `opq`       -- an event of a kind this UI does not know
      (`:telemetry_probe`), rendered through the `:opaque` forward-compat
      fallback: fold arrow + `◆ [telemetry_probe] <first line>`, dim --
      unknown material renders safely, labeled by its raw kind.

  A sealed tool block sits alongside to pin the separation law: errors
  are NOT machinery -- they never join the tight tool cluster, a blank
  row sets a fault off from its neighbours, and the alarm line keeps
  full prominence (non-dim) while machinery around it stays dim.

  Every block is a `%Block{}` in the model (controlled doctrine),
  rendered with `context[:id]` so each is a first-class interactive
  node: `[z]` / a targeted click / the derived `toggle_fold` MCP tool
  fold and expand through `Block.handle_event/3` and this app's
  `update/2` (`fold_after_seal: :allow` -- peeking sealed history is
  this app's D-PA choice).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.Block

  @content_width 76

  @block_order [:tool_ctx, :err_full, :err_where, :err_bare, :opq]

  @impl true
  def init(_context) do
    %{blocks: initial_blocks(), focus: :err_full}
  end

  @impl true
  def update(message, model) do
    case message do
      {:harness_block, :toggle_fold, id} ->
        {toggle_block_by_string(model, id), []}

      key_match("z") ->
        {toggle_block(model, model.focus), []}

      key_match("j") ->
        {move_focus(model, 1), []}

      key_match("k") ->
        {move_focus(model, -1), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 0} do
      [
        text("Harness Error Block Demo", style: [:bold]),
        text(" ")
      ] ++
        transcript_rows(model) ++
        [
          text(" "),
          text(status_line(model), style: [:dim]),
          text("[j/k] focus  [z] fold/expand", style: [:dim])
        ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- transcript assembly --------------------------------------------------

  # Same separator law as the tool demo: only machinery (tool_call/diff)
  # clusters tight. An `:error` is signal, not machinery -- every fault
  # gets its blank row, even against a tool neighbour.
  defp transcript_rows(model) do
    @block_order
    |> Enum.map(fn key -> {key, Map.fetch!(model.blocks, key)} end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{_prev_key, prev}, {key, block}] ->
      separator(prev, block) ++ [block_row(key, block, model)]
    end)
    |> prepend_first_row(model)
  end

  defp prepend_first_row(rows, model) do
    [first_key | _rest] = @block_order
    [block_row(first_key, Map.fetch!(model.blocks, first_key), model) | rows]
  end

  defp separator(%Block{kind: prev}, %Block{kind: kind}) do
    if machinery?(prev) and machinery?(kind), do: [], else: [text(" ")]
  end

  defp machinery?(:tool_call), do: true
  defp machinery?(:diff), do: true
  defp machinery?(_kind), do: false

  defp block_row(key, block, model) do
    row style: %{gap: 0} do
      [
        text(margin_cell(key, model), style: [:dim]),
        Block.render(block, %{
          width: @content_width,
          id: Atom.to_string(key)
        })
      ]
    end
  end

  defp margin_cell(key, %{focus: key}), do: "› "
  defp margin_cell(_key, _model), do: "  "

  defp status_line(model) do
    block = Map.fetch!(model.blocks, model.focus)
    "focus: #{model.focus} · #{block.fold}"
  end

  # -- model transitions ----------------------------------------------------

  defp toggle_block(model, key) when is_map_key(model.blocks, key) do
    %{
      model
      | blocks:
          Map.update!(
            model.blocks,
            key,
            &Block.toggle_fold(&1, fold_after_seal: :allow)
          )
    }
  end

  defp toggle_block(model, _key), do: model

  defp toggle_block_by_string(model, id) when is_binary(id) do
    case Enum.find(@block_order, &(Atom.to_string(&1) == id)) do
      nil -> model
      key -> toggle_block(model, key)
    end
  end

  defp toggle_block_by_string(model, _id), do: model

  defp move_focus(model, step) do
    index = Enum.find_index(@block_order, &(&1 == model.focus))
    next = Integer.mod(index + step, length(@block_order))
    %{model | focus: Enum.at(@block_order, next)}
  end

  # -- fixtures (all through the honest constructor) ------------------------

  defp initial_blocks do
    %{
      tool_ctx: tool_context_block(),
      err_full: full_fault_block(),
      err_where: where_only_fault_block(),
      err_bare: bare_fault_block(),
      opq: opaque_block()
    }
  end

  # The dim machinery neighbour the alarm's prominence reads against.
  defp tool_context_block do
    Block.from_events(:tool_call, [
      %{
        id: "c1",
        type: :item_started,
        payload: %{name: "probe", args: %{target: "upstream"}}
      },
      %{
        id: "c1r",
        type: :item_completed,
        payload: %{
          item_type: :tool_result,
          content: "probing api.internal:8443...",
          exit_code: 0
        }
      }
    ])
    |> Block.seal()
  end

  # A fault with a REAL multi-line message on `reason` (the `:error`
  # event's payload key): the alarm line is its first line; `[z]` peeks
  # the full fault body.
  defp full_fault_block do
    Block.from_events(:error, [
      %{
        id: "e1",
        type: :error,
        payload: %{
          reason:
            "Connection refused by upstream (attempt 3)\n" <>
              "upstream: api.internal:8443\n" <>
              "retry budget exhausted — giving up",
          where: "lane_executor"
        }
      }
    ])
    |> Block.seal()
  end

  # No message, but an origin: the honest specific fallback names it.
  defp where_only_fault_block do
    Block.from_events(:error, [
      %{id: "e2", type: :error, payload: %{where: "tool_executor"}}
    ])
    |> Block.seal()
  end

  # No message, no origin: the fallback still names the absence.
  defp bare_fault_block do
    Block.from_events(:error, [
      %{id: "e3", type: :error, payload: %{}}
    ])
    |> Block.seal()
  end

  # A kind this UI does not know: the forward-compat `:opaque` fallback
  # keeps the raw kind as the label and renders the payload safely.
  defp opaque_block do
    Block.from_events(:telemetry_probe, [
      %{
        id: "o1",
        type: :item_completed,
        payload: %{
          content:
            "cpu_pct: 12.4\nmem_mb: 512\n(unknown block kind — rendered opaquely)"
        }
      }
    ])
    |> Block.seal()
  end
end
