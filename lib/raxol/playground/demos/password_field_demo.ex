defmodule Raxol.Playground.Demos.PasswordFieldDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.PasswordField` — the real
  component (a TextField pinned to `secret: true`), with a strength meter
  driven off its value and a visibility toggle flipping the masking.
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  alias Raxol.UI.Components.Input.PasswordField

  @min_medium_length 4
  @min_strong_length 8
  @strength_bar_width 10

  @impl true
  def init(_context) do
    # snippet:start
    {:ok, field} =
      PasswordField.init(%{
        id: :pw_demo,
        placeholder: "(enter password)",
        width: 36
      })

    # Masked by default (secret: true); render with the component:
    #   PasswordField.render(field, %{})
    # snippet:end
    %{field: field, strength: :none}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("v") ->
        field =
          PasswordField.update(
            {:update_props, %{secret: not model.field.secret}},
            model.field
          )

        {%{model | field: field}, []}

      key_match("r") ->
        {%{model | field: put_value(model.field, ""), strength: :none}, []}

      key_match(:backspace) ->
        new_value = String.slice(model.field.value, 0..-2//1)

        {%{
           model
           | field: put_value(model.field, new_value),
             strength: strength(new_value)
         }, []}

      key_match(:char, char: ch)
      when byte_size(ch) == 1 and ch not in ["v", "r"] ->
        new_value = model.field.value <> ch

        {%{
           model
           | field: put_value(model.field, new_value),
             strength: strength(new_value)
         }, []}

      _ ->
        {model, []}
    end
  end

  # Through the component's own prop path, so cursor and scroll follow the
  # value instead of being poked directly.
  defp put_value(field, value) do
    PasswordField.update(
      {:update_props, %{value: value, cursor_pos: String.length(value)}},
      field
    )
  end

  defp strength(""), do: :none
  defp strength(v) when byte_size(v) < @min_medium_length, do: :weak
  defp strength(v) when byte_size(v) < @min_strong_length, do: :medium
  defp strength(_v), do: :strong

  @impl true
  def view(model) do
    len = String.length(model.field.value)
    {strength_label, strength_bar} = strength_display(model.strength)

    column style: %{gap: 1} do
      [
        text("PasswordField Demo", style: [:bold]),
        divider(),
        text("Password:"),
        box style: %{
              border: :single,
              padding: 1,
              width: effective_width(model, 40)
            } do
          PasswordField.render(model.field, %{})
        end,
        text("Strength: #{strength_label}"),
        text("[#{strength_bar}]"),
        text("Characters: #{len}", style: [:bold]),
        divider(),
        text(
          "Visibility: #{if model.field.secret, do: "hidden", else: "shown"}"
        ),
        text(
          "[type] enter chars  [backspace] delete  [v] toggle visibility  [r] reset",
          style: [:dim]
        )
      ]
    end
  end

  defp strength_display(:none), do: {"none", strength_bar(0)}
  defp strength_display(:weak), do: {"weak", strength_bar(2)}
  defp strength_display(:medium), do: {"medium", strength_bar(6)}

  defp strength_display(:strong),
    do: {"strong", strength_bar(@strength_bar_width)}

  defp strength_bar(filled) do
    String.duplicate("#", filled) <>
      String.duplicate(" ", @strength_bar_width - filled)
  end

  @impl true
  def subscribe(_model), do: []
end
