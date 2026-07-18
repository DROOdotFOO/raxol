defmodule Raxol.UI.Components.Harness.Toast do
  @moduledoc """
  Transient notification: a small floating notice with a level-appropriate
  glyph and color. The glyph carries the meaning too (not color alone), so
  the toast stays legible for colorblind users and on no-color terminals.

  This component renders the notice itself; corner placement and auto-dismiss
  timing are the caller's job -- compose with
  `Raxol.UI.Components.AbsoluteLayer.overlay/3` (e.g. `overlay(:right,
  :bottom, toast_view)`) the same way `Raxol.UI.Components.Modal.Rendering`'s
  dialog surface is positioned by its caller rather than positioning itself.
  """

  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type level :: :info | :warn | :error

  @type t :: %{
          id: String.t() | atom(),
          message: String.t(),
          level: level(),
          ttl_ms: non_neg_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(props, :id, "toast-#{:erlang.unique_integer([:positive])}"),
      message: Keyword.get(props, :message, ""),
      level: Keyword.get(props, :level, :info),
      ttl_ms: Keyword.get(props, :ttl_ms, 4_000),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style = StyleHelper.merge_component_styles(state, context, :toast)
    {glyph, color} = level_style(state.level)

    %{
      type: :box,
      style: Map.merge(%{border: :rounded, padding: 1}, base_style),
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-message",
          content: "#{glyph} #{state.message}",
          fg: color
        )
      ]
    }
  end

  defp level_style(:error), do: {"✗", :red}
  defp level_style(:warn), do: {"⚠", :yellow}
  defp level_style(:info), do: {"ℹ", :cyan}
  defp level_style(_level), do: {"•", :white}
end
