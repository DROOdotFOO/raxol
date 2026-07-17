defmodule Raxol.Playground.Demos.HarnessFooterStackDemo do
  @moduledoc """
  Playground demo: the harness footer's honest-notice / fit-priority law as
  a live `FooterStack` (harness TEA migration §5 law 3, unit U2). Oversized
  footer groups plus a shrinking-budget stepper make the drop order visible
  row by row.

  This demo IS the §7 autotest fixture. It pins, headlessly against the
  buffer:

    * **drop order** -- as the budget shrinks, `composer_sep` (the
      above-composer blank) yields FIRST, then the preview, divider,
      composer tail, overlay, and status, each trimmed from its tail;
    * **protected channels never shed** -- the honest report channels
      `lane` / `submitting` / `notice` are absent from the drop order and
      survive every budget (the "live" fixture);
    * **budget-1 notice-wins** -- in the "refusal" fixture (no lane /
      submitting competing for the top rows) the one row a 1-row footer
      keeps is the honest notice, never the status or composer.

  Two fixtures, toggled with `m`:

    * `:refusal` (default) -- `status / divider / preview / composer_sep /
      composer / notice`. No lane/submitting, so the head-take last resort
      keeps the NOTICE at budget 1 (mirrors the diff-expansion honest-notice
      pin).
    * `:live` -- the full inline footer `status / lane / submitting /
      overlay / divider / preview / composer_sep / composer / notice`, to
      show the three protected channels riding through a tiny budget while
      every discretionary group is shed.

  `[` shrinks the budget, `]` grows it (clamped to `[0, total]`); `m`
  toggles the fixture. All state lives in the model (§2 controlled
  doctrine); `FooterStack` is re-`init`+`render`ed from props each frame.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.FooterStack

  # The canonical inline-footer drop order (verbatim from
  # `Surface.footer_frame/1`): most-droppable first. Protected channels
  # (lane / submitting / notice) are its complement -- never listed, never
  # shed.
  @drop_order [:composer_sep, :preview, :divider, :composer, :overlay, :status]

  @content_width 40

  @impl true
  def init(_context) do
    groups = groups(:refusal)
    %{mode: :refusal, budget: FooterStack.total_height(groups)}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("[") ->
        {%{model | budget: max(model.budget - 1, 0)}, []}

      key_match("]") ->
        {%{model | budget: min(model.budget + 1, total(model.mode))}, []}

      key_match("m") ->
        mode = toggle_mode(model.mode)
        {%{model | mode: mode, budget: total(mode)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    {:ok, fs} =
      FooterStack.init(
        id: "footer_stack",
        groups: groups(model.mode),
        drop_order: @drop_order,
        budget: model.budget
      )

    column style: %{gap: 0} do
      [
        text(header(model), id: "fs_header", style: [:bold]),
        divider(),
        FooterStack.render(fs, %{available_width: @content_width}),
        divider(),
        text(hint(), id: "fs_hint", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- header / hint -------------------------------------------------------

  defp header(model) do
    "FooterStack — mode: #{model.mode} · budget: #{model.budget}/#{total(model.mode)}"
  end

  defp hint do
    "[ shrink · ] grow · m toggle refusal/live"
  end

  # -- fixtures ------------------------------------------------------------

  defp total(mode), do: FooterStack.total_height(groups(mode))

  defp toggle_mode(:refusal), do: :live
  defp toggle_mode(:live), do: :refusal

  # The "refusal" fixture: no lane/submitting, so a 1-row budget's head-take
  # keeps the NOTICE (the honest-notice pin). Oversized preview + composer
  # groups make the per-group tail-trim visible.
  defp groups(:refusal) do
    [
      status: [line("status: thinking 3s")],
      divider: [line("divider: 5 unread")],
      preview: [line("preview: line A"), line("preview: line B")],
      composer_sep: [line("")],
      composer: [line("> composer prompt"), line("  composer cont")],
      notice: [line("notice: no block focused")]
    ]
  end

  # The "live" fixture: the full inline footer. lane / submitting / notice
  # are protected (absent from @drop_order) and ride every budget; overlay /
  # divider / preview / composer_sep / composer are shed in drop order.
  defp groups(:live) do
    [
      status: [line("status: running mix")],
      lane: [line("lane: reconnecting to session")],
      submitting: [line("submitting: sending hello")],
      overlay: [line("overlay: pick 1"), line("overlay: pick 2")],
      divider: [line("divider: 5 unread")],
      preview: [line("preview: line A"), line("preview: line B")],
      composer_sep: [line("")],
      composer: [line("> composer prompt"), line("  composer cont")],
      notice: [line("notice: session degraded")]
    ]
  end

  # One footer row. The demo DSL `text/1` builds a single-line `%{type:
  # :text}` node -- the line-element shape `FooterStack` measures (height =
  # one row) and fits.
  defp line(content), do: text(content)
end
