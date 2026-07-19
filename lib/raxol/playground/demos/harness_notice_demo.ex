defmodule Raxol.Playground.Demos.HarnessNoticeDemo do
  @moduledoc """
  Playground demo: the harness footer's honest report channel —

    * `Raxol.UI.Components.Harness.Notice` — refusal / degradation /
      charged-minimum absence reports

  A controlled Component (props in, pure line-list out, no MCP actions).
  Its line vocabulary via `Notice.lines/2`:

    * `nil`        → no rows (honest silence)
    * binary       → one row per `\\n`-split physical line, width-truncated
    * list of bins → flat concat, so a long first notice never truncates
                     away a later one

  FooterStack never sheds the notice channel; this demo only shows the
  rows it produces. Scenes cycle with `n` / `p`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.Notice

  @width 42

  # Each scene: {label, notice_payload}
  @scenes [
    {"nil / silence", nil},
    {"single string", "no block focused"},
    {"multi-line string (\\n split)",
     "line one of a refusal\nline two kept separate"},
    {"list of strings (flat concat)",
     [
       "degraded resume: partial transcript",
       "composer disabled until reconnect"
     ]},
    {"width truncation (#{@width} cells)",
     "this notice is deliberately longer than the display width so TextMeasure ellipsis kicks in"}
  ]

  @impl true
  def init(_context), do: %{scene_index: 0}

  @impl true
  def update(message, model) do
    case message do
      key_match("n") ->
        {%{model | scene_index: Integer.mod(model.scene_index + 1, count())},
         []}

      key_match("p") ->
        {%{model | scene_index: Integer.mod(model.scene_index - 1, count())},
         []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    {label, notice_payload} = Enum.at(@scenes, model.scene_index)

    {:ok, notice} =
      Notice.init(
        id: "harness-notice",
        notice: notice_payload,
        width: @width
      )

    notice_view = Notice.render(notice, %{available_width: @width})

    column style: %{gap: 0} do
      [
        text("Harness Notice", style: [:bold]),
        text(" honest footer report channel (controlled Component)",
          style: [:dim]
        ),
        text(
          " scene #{model.scene_index + 1}/#{count()}: #{label}",
          style: [:dim]
        ),
        divider(),
        text(" Notice (refusal / degradation):", style: [:bold]),
        empty_or(notice_view, notice_payload),
        divider(),
        text(" lines/2 vocabulary: nil → [] · string → rows · list → flat",
          style: [:dim]
        ),
        text(" [n] next scene  [p] previous", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp count, do: length(@scenes)

  # When the payload is nil the Component renders an empty column — show an
  # explicit silence marker so the demo still has content lines and the
  # "honest absence" is visible rather than looking like a blank bug.
  defp empty_or(_view, nil), do: text("   (silence — no rows)", style: [:dim])
  defp empty_or(view, _payload), do: view
end
