defmodule Raxol.Playground.Demos.HarnessApprovalDemo do
  @moduledoc """
  Playground demo: the agent-harness approval gate.

  Triggers an `approval_requested` for a risky action (a file delete plus a
  shell command, marked irreversible) and exercises
  `Raxol.UI.Components.Harness.ApprovalPrompt` end to end: blast-radius
  preview with the `IRREVERSIBLE` marker, arrow/number-key navigation
  across the four scope options, and the emitted `approval_decision`
  command once the user confirms with Enter.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.AbsoluteLayer
  alias Raxol.UI.Components.Harness.ApprovalPrompt

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @stats_box_width 46

  @risky_action %{
    description: "Clear stale build cache and session db",
    tool: "shell.exec"
  }

  @risky_blast_radius %{
    deletes: ["/var/cache/app/session_12.db", "/tmp/build/artifact.tar"],
    commands: ["rm -rf /tmp/build"],
    writes: ["/var/log/app/cleanup.log"],
    network: [],
    reversible: false
  }

  @impl true
  def init(_context) do
    %{show: false, approval: nil, last_decision: nil}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("o") -> {open_prompt(model), []}
      _ -> route_to_prompt(message, model)
    end
  end

  defp open_prompt(model) do
    {:ok, approval} =
      ApprovalPrompt.init(
        id: "harness-approval-demo",
        action: @risky_action,
        blast_radius: @risky_blast_radius
      )

    %{model | show: true, approval: approval, last_decision: nil}
  end

  # While the prompt is open, every message (arrow keys, digit keys, Enter,
  # ...) is forwarded straight to the component's own handle_event/3 -- the
  # same thing a real dispatcher does for a focused widget. Anything the
  # component doesn't recognize is a safe no-op (see its catch-all clause),
  # so no filtering is needed here.
  defp route_to_prompt(message, %{show: true, approval: approval} = model) do
    {new_approval, commands} =
      ApprovalPrompt.handle_event(message, approval, %{})

    apply_commands(commands, %{model | approval: new_approval})
  end

  defp route_to_prompt(_message, model), do: {model, []}

  defp apply_commands([], model), do: {model, []}

  defp apply_commands([{:approval_decision, decision} | _rest], model) do
    {%{model | show: false, approval: nil, last_decision: decision}, []}
  end

  defp apply_commands([_unknown | rest], model), do: apply_commands(rest, model)

  @impl true
  def view(model) do
    overlays =
      if model.show do
        width = effective_width(model, model.approval.width)
        height = ApprovalPrompt.estimate_height(model.approval)

        [
          AbsoluteLayer.dialog_overlay(
            width,
            height,
            ApprovalPrompt.render(model.approval, %{})
          )
        ]
      else
        []
      end

    AbsoluteLayer.absolute_layer(background_view(model), overlays)
  end

  # Flow child is laid out the same open or closed; the prompt is overlay-only.
  defp background_view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Approval Demo", style: [:bold]),
        divider(),
        static_panel(),
        divider(),
        box style: %{
              border: :rounded,
              padding: 1,
              width: effective_width(model, @stats_box_width)
            } do
          column style: %{gap: 0} do
            [
              text("Prompt: #{if model.show, do: "OPEN", else: "closed"}"),
              text("Decision: #{format_decision(model.last_decision)}")
            ]
          end
        end,
        footer(model)
      ]
    end
  end

  defp static_panel do
    column style: %{gap: 0} do
      [
        text("Background content (does not move):"),
        text("- item one"),
        text("- item two"),
        text("[o] Trigger a risky approval request", style: [:dim])
      ]
    end
  end

  defp format_decision(nil), do: "none yet"

  defp format_decision(%{decision: decision, scope: scope}),
    do: "#{decision} / #{scope}"

  defp footer(%{show: true}) do
    text("[up/down or 1-4] choose  [Enter] confirm", style: [:dim])
  end

  defp footer(_model) do
    text("[o] trigger approval prompt", style: [:dim])
  end

  @impl true
  def subscribe(_model), do: []
end
