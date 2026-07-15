defmodule Raxol.Playground.Demos.HarnessPanelsDemo do
  @moduledoc """
  Playground demo: harness projection panels (worktracks / rules / memory /
  residual) laid out as one dashboard.

  Exercises the real `Raxol.UI.Components.Harness.*` panel modules -- each
  `init/1` + `render/2` directly, the same way `DemoHelpers.rich_text/2`
  mounts `Display.Text` -- with sample data shaped like the materialized
  views these panels fold from `extract{class, op, item}` / `residual` meta
  events (see `docs/proposals/in-flight/harness-spec-frontend.md` §3).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.{
    MemoryPanel,
    ResidualIndicator,
    RulesPanel,
    WorktracksPanel
  }

  @lanes [
    %{
      name: "todo",
      items: [
        %{title: "Wire MemoryPanel to state_change stream", status: "todo"},
        %{title: "Add reattach replay indicator", status: "todo"}
      ]
    },
    %{
      name: "doing",
      items: [
        %{title: "Fold extract{class: :worktracks} into board", status: "doing"}
      ]
    },
    %{
      name: "done",
      items: [
        %{title: "Spec projection panel props", status: "done"},
        %{title: "Draft protocol payload table", status: "done"}
      ]
    }
  ]

  @rules [
    %{
      when: "approval_requested is pending",
      then: "block further tool_use items until approval_decision arrives",
      hard: true
    },
    %{
      when: "steer command received mid-turn",
      then: "inject at the next safe tool boundary, never mid-call",
      hard: true
    },
    %{
      when: "turn_completed carries usage",
      then: "refresh the status line's cost readout",
      hard: false
    }
  ]

  @memory [
    %{key: "session_id", value: "sess_8f21c"},
    %{key: "active_gate", value: "probe_c1_gate"},
    %{key: "turns_completed", value: 12},
    %{key: "trust", value: "trusted"}
  ]

  @residual_text "which retry class covers a stalled probe_c2 extraction"

  @impl true
  def init(_context) do
    %{show_residual: true}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("r") ->
        {%{model | show_residual: not model.show_residual}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 1} do
      [
        text("Harness Panels Demo", style: [:bold]),
        divider(),
        panel(WorktracksPanel, id: "demo-worktracks", lanes: @lanes),
        row style: %{gap: 2} do
          [
            panel(RulesPanel, id: "demo-rules", rules: @rules),
            panel(MemoryPanel, id: "demo-memory", items: @memory)
          ]
        end,
        panel(ResidualIndicator,
          id: "demo-residual",
          residual: residual(model)
        ),
        text("[r] toggle residual", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp residual(%{show_residual: true}), do: @residual_text
  defp residual(_model), do: nil

  # Mounts a real Harness panel component the same way
  # `Raxol.Playground.DemoHelpers.rich_text/2` mounts `Display.Text`: a fresh
  # `init/1` + `render/2` each frame, since these panels carry no state of
  # their own beyond the props handed in.
  defp panel(module, props) do
    {:ok, state} = module.init(props)
    module.render(state, %{})
  end
end
