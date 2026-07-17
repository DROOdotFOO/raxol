defmodule Raxol.Playground.Demos.HarnessComposerDemo do
  @moduledoc """
  Playground demo: the prompt Composer re-hosted on the TEA path, proving
  the cursor-park law (harness TEA migration §5 law 6, unit U2).

  The Composer already owns the hard parts -- logical-truth editing, the
  content-preserving `WrapMap` visual projection, readline chords, history
  recall, backslash continuation. This demo hosts its REAL state (§2
  controlled doctrine: the model owns the composer, forwards every key to
  `Composer.handle_event/3`, stores the result) and closes the two TEA-path
  seams the Composer needs:

    * **render** -- `Composer.render/2`'s `:composer_input_row` tree targets
      the shelved `ViewText` substrate (not a LayoutEngine element), so the
      draft is drawn from `Composer.visual_lines/2` (the same `WrapMap`
      projection, as `%{type: :text}` rows the LayoutEngine paints);
    * **cursor** (§5 law 6) -- the composer declares its edit point via
      `Composer.edit_point/2`; the demo lowers that to the F0-cursor root
      `:cursor` key `{row, col, visible?}` (absolute, 0-based buffer
      coordinates) on `view/1`'s root, so the terminal caret parks exactly
      where the next typed grapheme lands. This is the cursor-through-
      pipeline proof: the autotest reads the buffer's `cursor_position` /
      `cursor_visible` (the F0-cursor assert surface).

  It IS the §7 autotest fixture, pinning: cursor park at the draft end
  (buffer cursor), the park ADVANCING as you type (a wide CJK grapheme
  advances it by two cells -- the display-width honesty), `WrapMap`
  edit/submit chords, the placeholder (a second empty, unfocused composer),
  and the submit / refuse notices.

  The focused composer sits at the top so its first draft row is buffer row
  0 (`@base_row`); the cursor is `@base_row + edit_row`, `edit_col - 1`
  (1-based display col -> 0-based buffer col).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Composer

  @width 40
  # The focused composer is view/1's first child, so its first draft row is
  # buffer row 0.
  @base_row 0
  @seed "hi there"

  @impl true
  def init(_context) do
    {:ok, composer} =
      Composer.init(id: "composer", width: @width, focused: true)

    # set_value parks the logical cursor at the draft end (the natural
    # resume point), so the initial caret sits after the seeded text.
    %{composer: Composer.set_value(composer, @seed), notice: nil}
  end

  @impl true
  def update(message, model) do
    case message do
      %Event{type: :key, data: %{key: :enter}} = event ->
        handle_enter(event, model)

      %Event{type: :key} = event ->
        {composer, _cmds} = Composer.handle_event(event, model.composer, %{})
        {%{model | composer: composer, notice: nil}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    base =
      column style: %{gap: 0} do
        [
          composer_node("composer", model.composer),
          text(placeholder_label(), id: "cd_label", style: [:dim]),
          composer_node("composer_ph", placeholder_composer()),
          text(status_line(model), id: "cd_status", style: [:dim])
        ]
      end

    # Law 6: lower the composer's declared edit point onto the root :cursor
    # key so the pipeline parks the terminal caret there (F0-cursor seam).
    Map.put(base, :cursor, cursor_decl(model))
  end

  @impl true
  def subscribe(_model), do: []

  # -- nodes ---------------------------------------------------------------

  # The composer as an identified column of plain-text draft rows -- the
  # TEA-path render surface (`Composer.visual_lines/2`), stamped with the
  # same id/attrs `Composer.render/2` carries so the semantic tree and
  # time-travel can find it.
  defp composer_node(id, composer) do
    rows =
      composer
      |> Composer.visual_lines(@width)
      |> Enum.map(fn line -> text(line) end)

    %{
      type: :column,
      id: id,
      attrs: %{kind: :composer, component_module: Composer},
      gap: 0,
      children: rows
    }
  end

  # A second composer, empty and unfocused, so `visual_lines/2` renders its
  # placeholder -- the §7 placeholder pin.
  defp placeholder_composer do
    {:ok, ph} =
      Composer.init(
        id: "composer_ph",
        width: @width,
        focused: false,
        placeholder: "type a prompt"
      )

    ph
  end

  # -- cursor (law 6): edit_point -> absolute root :cursor -----------------

  defp cursor_decl(model) do
    {row, col} = Composer.edit_point(model.composer, @width)
    # edit_point col is 1-based display; the buffer cursor is 0-based.
    {@base_row + row, max(col - 1, 0), true}
  end

  # -- enter: submit / refuse notices --------------------------------------

  defp handle_enter(event, model) do
    blank_before? = String.trim(Composer.value(model.composer)) == ""
    {composer, cmds} = Composer.handle_event(event, model.composer, %{})

    notice =
      case submit_text(cmds) do
        {:ok, text} -> "submitted: #{text}"
        :none -> if blank_before?, do: "refused: empty prompt", else: nil
      end

    {%{model | composer: composer, notice: notice}, []}
  end

  defp submit_text(cmds) do
    Enum.find_value(cmds, :none, fn
      {:component_event, _id, {:submit, text}} -> {:ok, text}
      _ -> nil
    end)
  end

  # -- labels --------------------------------------------------------------

  defp placeholder_label, do: "-- placeholder (empty + unfocused) --"

  defp status_line(%{notice: nil}),
    do: "type to edit | Enter submits | wrap/readline chords active"

  defp status_line(%{notice: notice}), do: notice
end
