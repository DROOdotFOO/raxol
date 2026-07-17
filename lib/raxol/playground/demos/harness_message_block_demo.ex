defmodule Raxol.Playground.Demos.HarnessMessageBlockDemo do
  @moduledoc """
  Playground demo: the transcript MESSAGE block re-hosted as a controlled
  Component (harness TEA migration, unit U1-a).

  Hosts `Raxol.UI.Components.Harness.MessageBlock` the §2-doctrine way:
  the model owns ALL state (fold flags, focus), the component renders
  from props and emits events out as messages. Two entry doors, one
  mutation point:

    * keyboard -- every key event is forwarded to the FOCUSED turn's
      `MessageBlock.handle_event/3`; the component decides which keys
      fold (`z`, today's transcript fold key, plus Enter/Space) and emits
      the wired `{:toggle_fold, id}` message back, which `update/2` folds
      into the model;
    * MCP -- each block's rendered root is stamped `id`/`attrs`/
      `on_click`, so the derived `<id>.toggle` tool dispatches a
      widget-targeted click through the Dispatcher/Bubbler and lands on
      the SAME `{:toggle_fold, id}` message.

  ## Speaker grammar (the V-ratified mirrored-sigil ruling)

  Mirrored outer-contour sigils: `❯` fronts user turns, `❮` fronts
  assistant turns, both bold, zero color, sitting alone in column 0; ALL
  block content sits at the uniform 2-cell indent. The sigil margin is
  composed HERE, by the hosting view (in the endgame it is TranscriptView/
  HarnessApp's seat) -- `MessageBlock` itself stays role-invariant, which
  its render-equality-across-roles test pins. A folded turn keeps its
  sigil and collapses the body to a dim `▸ summary` line (the sealed
  transcript's role-aware folded headers remain `Block.render/2`'s seat,
  re-hosted with the TranscriptBlock unit, not here).

  Blank-row rhythm: exactly one blank row between turns (the outer
  column's `gap: 1`), none inside a turn.

  The fixture carries the §7 variants: a short prompt, a Markdown
  assistant reply, a long wrapped prompt, and a damaged-then-recovered
  assistant message (raw ESC bytes + invalid UTF-8 that `MarkdownBody`
  sanitizes -- the recovered variant renders its text with no escape
  bytes in the element tree).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.MessageBlock
  alias Raxol.UI.TextLayout

  # The mirrored outer-contour speaker sigils (V-ratified pair; the
  # capability-tier degradation to ">"/"<" is the Surface/HarnessApp
  # seam's job -- a playground demo runs on the unicode tier).
  @user_sigil "❯"
  @reply_sigil "❮"

  @content_width 56
  @folded_budget @content_width - 2

  @impl true
  def init(_context) do
    %{turns: fixture_turns(), focused: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      {:toggle_fold, id} ->
        {toggle_fold(model, id), []}

      key_match("j") ->
        {move_focus(model, 1), []}

      key_match("k") ->
        {move_focus(model, -1), []}

      %Event{type: :key} = event ->
        {forward_to_focused(model, event), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Message Block Demo", style: [:bold]),
        divider()
      ] ++
        Enum.map(model.turns, &turn_view/1) ++
        [hint_view(model)]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- turns ---------------------------------------------------------------

  defp turn_view(%{folded: false} = turn) do
    {:ok, state} = MessageBlock.init(block_props(turn))

    row style: %{gap: 1} do
      [
        text(sigil(turn.role), style: [:bold]),
        MessageBlock.render(state, %{})
      ]
    end
  end

  # A folded turn keeps its speaker sigil; the body collapses to one dim
  # summary line. The root stays a COLUMN with the same id/attrs/on_click
  # identity as the unfolded block (a text node cannot carry a custom
  # attrs bag -- the layout engine reads `%{type: :text, attrs: _}` as its
  # old attrs-shaped format), so block identity and the MCP toggle tool
  # survive the fold: clicking a folded header expands it.
  defp turn_view(%{folded: true} = turn) do
    folded_block = %{
      type: :column,
      id: turn.id,
      attrs: %{kind: :message, folded: true, component_module: MessageBlock},
      on_click: {:toggle_fold, turn.id},
      style: %{},
      gap: 0,
      children: [
        # Map-form style (the harness component convention): list-form
        # DSL sugar ([:dim]) is dropped by nested flex processing, map
        # form survives to the buffer cell.
        Raxol.View.Components.text(
          content: "▸ " <> folded_summary(turn.content),
          style: %{dim: true}
        )
      ]
    }

    row style: %{gap: 1} do
      [text(sigil(turn.role), style: [:bold]), folded_block]
    end
  end

  defp hint_view(model) do
    focused = Enum.at(model.turns, model.focused)

    text(
      "focused: #{focused.id}   [z] fold/expand · [j]/[k] move focus",
      id: "focus_hint",
      style: [:dim]
    )
  end

  defp block_props(turn) do
    [
      id: turn.id,
      role: turn.role,
      content: turn.content,
      width: @content_width,
      on_toggle: {:toggle_fold, turn.id}
    ]
  end

  defp sigil(:user), do: @user_sigil
  defp sigil(:assistant), do: @reply_sigil

  defp folded_summary(content) do
    content
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
    |> TextLayout.truncate(@folded_budget, :ellipsis)
  end

  # -- model mutations -----------------------------------------------------

  defp toggle_fold(model, id) do
    turns =
      Enum.map(model.turns, fn
        %{id: ^id} = turn -> %{turn | folded: not turn.folded}
        turn -> turn
      end)

    %{model | turns: turns}
  end

  defp move_focus(model, delta) do
    count = length(model.turns)
    %{model | focused: Integer.mod(model.focused + delta, count)}
  end

  # The component is the single authority on which keys fold: the demo
  # forwards the raw event and applies whatever messages come back.
  defp forward_to_focused(model, event) do
    turn = Enum.at(model.turns, model.focused)
    {:ok, state} = MessageBlock.init(block_props(turn))
    {_state, messages} = MessageBlock.handle_event(event, state, %{})

    Enum.reduce(messages, model, fn
      {:toggle_fold, id}, acc -> toggle_fold(acc, id)
      _other, acc -> acc
    end)
  end

  # -- fixture -------------------------------------------------------------

  defp fixture_turns do
    [
      %{
        id: "msg-1",
        role: :user,
        content: "Run the tests and summarize what broke.",
        folded: false
      },
      %{
        id: "msg-2",
        role: :assistant,
        # Markdown variant: list + code spans + a bold span in the closing
        # paragraph. Bold deliberately sits OUTSIDE the list items: the
        # in-list emphasis path currently mangles bold spans (markers kept,
        # span chars eaten -- a pre-existing MarkdownBody defect, that
        # unit's seat, not pinned here).
        content:
          "Two suites are red:\n\n" <>
            "- `renderer_test.exs` — the scroll anchor drops the final row\n" <>
            "- `diff_test.exs` — golden drift after the palette change\n\n" <>
            "Starting with the **anchor**; the diff drift looks downstream.",
        folded: false
      },
      %{
        id: "msg-3",
        role: :user,
        content:
          "Focus on the anchor first and leave the goldens alone until the " <>
            "renderer is green again, then re-bless only the rows that still " <>
            "differ after the fix lands.",
        folded: false
      },
      %{
        id: "msg-4",
        role: :assistant,
        # The recovered/damaged variant: raw ESC bytes and an invalid
        # UTF-8 byte in the wire content. MarkdownBody's sanitization
        # strips the escapes and recovers the encoding -- the rendered
        # tree carries no raw \e, ever.
        content:
          "Recovered after a dropped stream: \e[31malarm text\e[0m and a " <>
            "torn byte " <> <<0xFF>> <> " survived the reconnect.",
        folded: false
      }
    ]
  end
end
