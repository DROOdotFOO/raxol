defmodule Raxol.Playground.Demos.HarnessReasoningBlockDemo do
  @moduledoc """
  Playground demo: the transcript REASONING block re-hosted as a
  controlled Component (harness TEA migration, unit U1-a).

  Reasoning is the quiet register: collapsed by default, dim throughout,
  peekable. This demo shows the kind through BOTH of its real renderers,
  driven by ONE model flag so a peek flips them together:

    * the controlled `Raxol.UI.Components.Harness.ReasoningBlock` -- the
      peekable body component (`▸ N lines — first-line peek` collapsed,
      `▾ N lines` + dim body expanded). Hosted the §2-doctrine way: the
      model owns `expanded`; every key event is forwarded to
      `handle_event/3` (which answers to `z`/Enter/Space) and the wired
      `:toggle_reasoning` message it emits is what mutates the model --
      the state the component returns is deliberately discarded, exactly
      as the Bubbler discards it on the view path;
    * the sealed transcript register -- `Block.render/2` on a real
      `%Block{kind: :reasoning}`, whose compact `∴ reasoning · N lines`
      line IS the transcript's collapsed form and stays as the header of
      the expanded dim body (`BlockBody` routes reasoning to this
      renderer in both fold states; the ∴ grammar lives there, never
      duplicated here).

  MCP: the component's rendered root is stamped `id`/`attrs`/`on_click`,
  so the session derives a `reasoning.toggle` tool whose widget-targeted
  click lands on the same `:toggle_reasoning` message as the keys.

  Content sits at the transcript's uniform 2-cell indent (sigils are the
  only column-0 dwellers; a reasoning line owns none). Blank-row rhythm:
  one blank row between sections, none inside a register.

  The fixture is a multi-phase thought (scope -> hypothesis -> check ->
  verdict), so the collapsed line-count and the expanded body differ
  meaningfully.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Components.Harness.ReasoningBlock

  @content_width 56

  @fixture "Phase 1 — scope: the failing suite touches only the renderer.\n" <>
             "Phase 2 — hypothesis: the diff path drops the final row.\n" <>
             "Phase 3 — check: replay the fixture with that row pinned.\n" <>
             "Phase 4 — verdict: off-by-one in the scroll anchor; fix it."

  @impl true
  def init(_context) do
    %{expanded: false}
  end

  @impl true
  def update(message, model) do
    case message do
      :toggle_reasoning ->
        {%{model | expanded: not model.expanded}, []}

      %Event{type: :key} = event ->
        {forward_to_component(model, event), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Reasoning Block Demo", style: [:bold]),
        divider(),
        text("Component register (controlled peek):", style: [:dim]),
        indented(ReasoningBlock.render(component_state(model), %{})),
        text("Sealed transcript register (Block.render):", style: [:dim]),
        indented(
          Block.render(transcript_block(model), %{width: @content_width})
        ),
        text(
          "expanded: #{model.expanded}   [z]/[enter]/[space] peek — both registers follow the model",
          id: "state_hint",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- hosting -------------------------------------------------------------

  defp component_state(model) do
    {:ok, state} =
      ReasoningBlock.init(
        id: "reasoning",
        content: @fixture,
        expanded: model.expanded,
        width: @content_width,
        on_toggle: :toggle_reasoning
      )

    state
  end

  # The real sealed-transcript register: a literal reasoning block through
  # Block.render/2 -- `∴ reasoning · N lines` collapsed, the same compact
  # header over the full dim body expanded.
  defp transcript_block(model) do
    %Block{
      kind: :reasoning,
      raw_kind: "reasoning",
      event_refs: [],
      fold: if(model.expanded, do: :expanded, else: :folded),
      seal: :sealed,
      outcome: %{},
      content: %{text: @fixture}
    }
  end

  # The transcript's uniform 2-cell content indent: a one-column spacer in
  # the sigil margin plus the row gap. Reasoning owns no sigil -- column 0
  # stays blank (sigils are the only col-0 dwellers).
  defp indented(view) do
    row style: %{gap: 1} do
      [text(" "), view]
    end
  end

  # The component is the single authority on which keys peek: forward the
  # raw event, apply the emitted messages, DISCARD the returned state
  # (controlled doctrine -- the model, not the component, owns `expanded`).
  defp forward_to_component(model, event) do
    {_state, messages} =
      ReasoningBlock.handle_event(event, component_state(model), %{})

    Enum.reduce(messages, model, fn
      :toggle_reasoning, acc -> %{acc | expanded: not acc.expanded}
      _other, acc -> acc
    end)
  end
end
