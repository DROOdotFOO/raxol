defmodule Raxol.Playground.Demos.TabsDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.Tabs` — the REAL component,
  mounted controlled (state lives in this demo's model, every key routes
  through `Tabs.handle_event/3`).

  Tabs only renders the tab bar. Content switching is the parent's job
  via `active_index` (and optional `on_change`). Keys: left/right (wrap),
  Home/End, and digits 1-9 for direct selection.

  Stories shown: interactive tab bar + content panel for the active tab.

  Contract wart: `Tabs.init/1` takes a keyword list. Content panels are
  not part of the component — this demo owns `@tab_content` keyed by
  index. Number keys only work for tabs 1..min(9, count).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.Tabs

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_content_box_width 40

  @tab_defs [
    %{id: :overview, label: "Overview"},
    %{id: :details, label: "Details"},
    %{id: :settings, label: "Settings"},
    %{id: :help, label: "Help"}
  ]

  @tab_content %{
    0 => "Welcome to the overview panel.\nThis shows a summary.",
    1 => "Detailed information goes here.\nRow 1: value\nRow 2: value",
    2 => "Settings panel.\nTheme: dark\nFont: mono",
    3 => "Press ←/→ (or h/l) to switch tabs.\nPress 1-4 for direct access."
  }

  @impl true
  def init(_context) do
    {:ok, tabs} =
      Tabs.init(
        id: "tabs-main",
        tabs: @tab_defs,
        active_index: 0,
        focused: true
      )

    %{
      tabs: tabs,
      event_log: []
    }
  end

  @impl true
  def update(message, model) do
    case tabs_event(message) do
      nil ->
        {model, []}

      {event, summary} ->
        apply_tabs(model, event, summary)
    end
  end

  defp tabs_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :left} ->
        {%Event{type: :key, data: %{key: :left}}, "key :left"}

      %{key: :right} ->
        {%Event{type: :key, data: %{key: :right}}, "key :right"}

      %{key: :home} ->
        {%Event{type: :key, data: %{key: :home}}, "key :home"}

      %{key: :end} ->
        {%Event{type: :key, data: %{key: :end}}, "key :end"}

      # vim aliases
      %{key: :char, char: "h"} ->
        {%Event{type: :key, data: %{key: :left}}, "key h→:left"}

      %{key: :char, char: "l"} ->
        {%Event{type: :key, data: %{key: :right}}, "key l→:right"}

      # digits 1-9 — Tabs reads :char events natively
      %{key: :char, char: ch} when ch in ~w(1 2 3 4 5 6 7 8 9) ->
        {%Event{type: :key, data: %{key: :char, char: ch}}, "key #{ch}"}

      _ ->
        nil
    end
  end

  defp tabs_event(_other), do: nil

  defp apply_tabs(model, event, summary) do
    before = model.tabs
    result = Tabs.handle_event(event, before, %{})
    tabs = unwrap(result, before)

    label =
      case Enum.at(tabs.tabs, tabs.active_index) do
        %{label: l} -> l
        _ -> "?"
      end

    outcome =
      if tabs.active_index != before.active_index do
        "#{summary} -> active=#{tabs.active_index} (#{label})"
      else
        "#{summary} -> active=#{tabs.active_index} (no change)"
      end

    model =
      model
      |> Map.put(:tabs, tabs)
      |> DemoHelpers.log_event(outcome)

    {model, []}
  end

  defp unwrap({:noreply, state}, _fallback), do: state
  defp unwrap({:ok, state}, _fallback), do: state
  defp unwrap({:handled, state}, _fallback), do: state
  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state

  @impl true
  def view(model) do
    idx = model.tabs.active_index

    content_lines =
      @tab_content
      |> Map.get(idx, "")
      |> String.split("\n")
      |> Enum.map(&text/1)

    column style: %{gap: 0} do
      [
        text("Tabs — Raxol.UI.Components.Input.Tabs", style: [:bold]),
        text(
          " (tab bar only; content panel is parent-owned via active_index)",
          style: [:dim]
        ),
        text(""),
        text(" interactive tab bar:", style: [:dim]),
        Tabs.render(model.tabs, %{}),
        text(""),
        box style: %{
              border: :single,
              padding: 1,
              width: effective_width(model, @default_content_box_width)
            } do
          column style: %{gap: 0} do
            content_lines
          end
        end,
        text(
          " tab #{idx + 1}/#{length(model.tabs.tabs)}  active_index=#{idx}",
          style: [:bold]
        ),
        text(""),
        text(
          " [←→/hl] prev/next  [home end] ends  [1-4] direct",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
