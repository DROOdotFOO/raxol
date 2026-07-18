defmodule Raxol.UI.Components.Harness.AdvisoryFeed do
  @moduledoc """
  Advisory side-channel feed: renders `gate_decision` / `verdict` /
  `research` meta events from probes running alongside the primary
  transcript.

  Styled deliberately dim and boxed so it reads as a sidebar and never gets
  mixed into the primary transcript -- advisory entries are context, not the
  conversation.
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type entry :: %{
          source: String.t(),
          kind: atom() | String.t(),
          text: String.t(),
          score: number() | nil
        }

  @type t :: %{
          id: String.t() | atom(),
          entries: [entry()],
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "advisory-feed"),
      entries: Keyword.get(props, :entries, []),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :advisory_feed)

    %{
      type: :box,
      style: Map.merge(%{border: :single}, base_style),
      children: [
        %{
          type: :column,
          style: %{gap: 0},
          children: [header(state.id) | entry_rows(state)]
        }
      ]
    }
  end

  defp header(id) do
    Raxol.View.Components.text(
      id: "#{id}-header",
      content: "ADVISORY",
      style: %{bold: true, dim: true}
    )
  end

  defp entry_rows(%{entries: []}) do
    [
      Raxol.View.Components.text(
        content: "no advisories",
        style: %{dim: true}
      )
    ]
  end

  defp entry_rows(%{entries: entries, id: id}) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      Raxol.View.Components.text(
        id: "#{id}-entry-#{index}",
        content: entry_line(entry),
        style: %{dim: true}
      )
    end)
  end

  defp entry_line(%{source: source, kind: kind, text: text, score: score}) do
    "[#{to_string(kind)}] #{source}: #{text}#{score_suffix(score)}"
  end

  defp score_suffix(nil), do: ""

  defp score_suffix(score) when is_float(score),
    do: " (#{Float.round(score, 2)})"

  defp score_suffix(score), do: " (#{score})"
end
