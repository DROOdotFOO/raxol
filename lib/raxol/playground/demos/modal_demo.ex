defmodule Raxol.Playground.Demos.ModalDemo do
  @moduledoc "Playground demo: modal dialog with confirm and cancel actions."
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.AbsoluteLayer
  alias Raxol.UI.Components.Modal.Rendering, as: ModalRendering

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @stats_box_width 30
  @modal_width 40
  @modal_height 17

  @impl true
  def init(_context) do
    %{show: false, confirmed: 0, cancelled: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :open -> {%{model | show: true}, []}
      :confirm -> {do_confirm(model), []}
      :cancel -> {do_cancel(model), []}
      key_match("o") -> {%{model | show: true}, []}
      _ -> handle_modal_keys(message, model)
    end
  end

  defp handle_modal_keys(message, %{show: true} = model) do
    case message do
      key_match(:enter) -> {do_confirm(model), []}
      key_match("y") -> {do_confirm(model), []}
      key_match(:escape) -> {do_cancel(model), []}
      key_match("n") -> {do_cancel(model), []}
      _ -> {model, []}
    end
  end

  defp handle_modal_keys(_message, model), do: {model, []}

  defp do_confirm(model),
    do: %{model | show: false, confirmed: model.confirmed + 1}

  defp do_cancel(model),
    do: %{model | show: false, cancelled: model.cancelled + 1}

  # Flow child is laid out the same open or closed; dialog is overlay-only.
  @impl true
  def view(model) do
    # snippet:start
    overlays =
      if model.show do
        width = effective_width(model, @modal_width)

        [
          AbsoluteLayer.dialog_overlay(
            width,
            @modal_height,
            modal_box(model, width)
          )
        ]
      else
        []
      end

    AbsoluteLayer.absolute_layer(background_view(model), overlays)
    # snippet:end
  end

  defp background_view(model) do
    column style: %{gap: 1} do
      [
        text("Modal Demo", style: [:bold]),
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
              text("Confirmed: #{model.confirmed}"),
              text("Cancelled: #{model.cancelled}"),
              text("State: #{if model.show, do: "OPEN", else: "closed"}")
            ]
          end
        end,
        footer(model)
      ]
    end
  end

  # Fixed copy so reflow tests can pin cell coords.
  defp static_panel do
    column style: %{gap: 0} do
      [
        text("Background content (does not move):"),
        text("- item one"),
        text("- item two"),
        text("[o] Open Modal", style: [:dim])
      ]
    end
  end

  defp modal_box(_model, width) do
    content =
      column style: %{gap: 1} do
        [
          text("Confirm Action", style: [:bold]),
          text("Are you sure you want to proceed?"),
          text("This action cannot be undone."),
          divider(),
          row style: %{gap: 2} do
            [
              button("[y] Confirm", on_click: :confirm),
              button("[n] Cancel", on_click: :cancel)
            ]
          end
        ]
      end

    ModalRendering.dialog_surface(
      width,
      @modal_height,
      %{border: :double, bg: {30, 30, 45}},
      [content]
    )
  end

  @impl true
  def subscribe(_model), do: []

  defp footer(%{show: true}) do
    text("[y] confirm  [n] cancel  [Enter/Esc] also work", style: [:dim])
  end

  defp footer(_) do
    text("[o] open modal", style: [:dim])
  end
end
