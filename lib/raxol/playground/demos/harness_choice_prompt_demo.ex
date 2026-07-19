defmodule Raxol.Playground.Demos.HarnessChoicePromptDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Harness.ChoicePrompt` as an
  autonomous entity — the chevron confirm/cancel pair plus the free-text
  third way.

  Try the key contract:

    * idle: Enter confirms, Escape cancels (the `[enter]`/`[escape]`
      hints say so), the placeholder sits quiet behind the caret;
    * type: the hints disappear — Enter submits your text, Escape
      clears it (hints return); Shift+Enter authors a second line;
    * arrows: Up/Down walk confirm ⇅ cancel ⇅ input, and inside a
      multi-line draft they navigate the text first — Up hops out only
      from the first line;
    * typing from an option row drops you straight back into the input.

  §2 controlled doctrine: the model owns the component state, forwards
  every key to `ChoicePrompt.handle_event/3`, and folds the emitted
  `{:component_event, id, action}` commands into the status line —
  remounting a fresh prompt on every answered action (the host owns the
  lifecycle). Law 6: `ChoicePrompt.edit_point/2` is lowered onto the
  root `:cursor` key, so the terminal caret parks at the draft's edit
  point and withdraws while an option row holds focus.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ChoicePrompt

  @width 44
  # title row + blank row above the prompt
  @base_row 2

  @impl true
  def init(_context) do
    %{prompt: new_prompt(), last: nil}
  end

  defp new_prompt do
    {:ok, prompt} = ChoicePrompt.init(id: "choice", width: @width)
    prompt
  end

  @impl true
  def update(message, model) do
    case message do
      %Event{type: :key} = event ->
        {prompt, cmds} = ChoicePrompt.handle_event(event, model.prompt, %{})
        {fold_actions(%{model | prompt: prompt}, cmds), []}

      _ ->
        {model, []}
    end
  end

  # Any answered action retires this prompt: report it, mount a fresh one.
  defp fold_actions(model, cmds) do
    Enum.reduce(cmds, model, fn
      {:component_event, "choice", :confirm}, acc ->
        %{acc | prompt: new_prompt(), last: "confirmed"}

      {:component_event, "choice", :cancel}, acc ->
        %{acc | prompt: new_prompt(), last: "canceled"}

      {:component_event, "choice", {:submit, text}}, acc ->
        %{acc | prompt: new_prompt(), last: "steered: #{text}"}

      _other, acc ->
        acc
    end)
  end

  @impl true
  def view(model) do
    base =
      column style: %{gap: 0} do
        [
          text("-- choice prompt (a tool confirm, extended) --",
            id: "cpd_title",
            style: [:dim]
          ),
          text(""),
          ChoicePrompt.render(model.prompt, %{available_width: @width}),
          text(""),
          text(status_line(model), id: "cpd_status", style: [:dim])
        ]
      end

    put_cursor(base, cursor_decl(model))
  end

  @impl true
  def subscribe(_model), do: []

  # Law 6: the component declares its caret; the host lowers it to the
  # absolute root :cursor — and leaves the key ABSENT while an option row
  # holds focus (the caret must never point at state the keys don't
  # reach).
  defp cursor_decl(model) do
    case ChoicePrompt.edit_point(model.prompt, @width) do
      nil -> nil
      {row, col} -> {@base_row + row, max(col - 1, 0), true}
    end
  end

  defp put_cursor(view, nil), do: view
  defp put_cursor(view, cursor), do: Map.put(view, :cursor, cursor)

  defp status_line(%{last: nil}),
    do: "Enter confirm | Esc cancel | type the third way | arrows navigate"

  defp status_line(%{last: last}), do: "answered: #{last}"
end
