defmodule Raxol.Core.Renderer.View.Components do
  @moduledoc """
  Component creation functions for the View module.
  Extracted from the main View module to improve maintainability.
  """

  @doc """
  Creates a button element.

  ## Options
    * `:id` - Unique identifier for the button
    * `:on_click` - Event handler for click events
    * `:aria_label` - Accessibility label
    * `:aria_description` - Accessibility description
    * `:style` - Style options for the button

  ## Examples

      Components.button("Click Me", on_click: {:button_clicked})
      Components.button("Submit", id: "submit_btn", aria_label: "Submit form")
  """
  def button(text, opts \\ []) do
    %{
      type: :button,
      text: text,
      id: Keyword.get(opts, :id),
      on_click: Keyword.get(opts, :on_click),
      aria_label: Keyword.get(opts, :aria_label),
      aria_description: Keyword.get(opts, :aria_description),
      style: Keyword.get(opts, :style, [])
    }
  end

  @doc """
  Creates a checkbox element.

  ## Options
    * `:checked` - Whether the checkbox is checked (default: false)
    * `:on_toggle` - Event handler for toggle events
    * `:aria_label` - Accessibility label
    * `:aria_description` - Accessibility description
    * `:style` - Style options for the checkbox

  ## Examples

      Components.checkbox("Enable Feature", checked: true)
      Components.checkbox("Accept Terms", on_toggle: {:terms_toggled})
  """
  def checkbox(label, opts \\ []) do
    %{
      type: :checkbox,
      label: label,
      checked: Keyword.get(opts, :checked, false),
      on_toggle: Keyword.get(opts, :on_toggle),
      aria_label: Keyword.get(opts, :aria_label),
      aria_description: Keyword.get(opts, :aria_description),
      style: Keyword.get(opts, :style, [])
    }
  end

  @doc """
  Creates a text input element.

  ## Options
    * `:value` - Current value of the input (default: "")
    * `:placeholder` - Placeholder text
    * `:on_change` - Event handler for change events
    * `:aria_label` - Accessibility label
    * `:aria_description` - Accessibility description
    * `:style` - Style options for the input

  ## Examples

      Components.text_input(placeholder: "Enter your name...")
      Components.text_input(value: "John", on_change: {:name_changed})
  """
  def text_input(opts \\ []) do
    %{
      type: :text_input,
      value: Keyword.get(opts, :value, ""),
      placeholder: Keyword.get(opts, :placeholder),
      on_change: Keyword.get(opts, :on_change),
      aria_label: Keyword.get(opts, :aria_label),
      aria_description: Keyword.get(opts, :aria_description),
      style: Keyword.get(opts, :style, [])
    }
  end

  @doc """
  Creates a simple box element with the given options.
  """
  def box_element(opts \\ []) do
    %{
      type: :box,
      style: Keyword.get(opts, :style, %{}),
      children: Keyword.get(opts, :children, [])
    }
  end

  @doc """
  Creates a shadow effect for a view.

  ## Options
    * `:offset` - Shadow offset as a string or tuple {x, y}
    * `:blur` - Shadow blur radius
    * `:color` - Shadow color
    * `:opacity` - Shadow opacity (0.0 to 1.0)

  ## Examples

      Components.shadow(offset: "2px 2px", blur: 4, color: :black)
      Components.shadow(offset: {1, 1}, color: :gray, opacity: 0.5)
  """
  def shadow(opts \\ []) do
    offset = parse_offset(Keyword.get(opts, :offset, {1, 1}))
    blur = Keyword.get(opts, :blur, 2)
    color = Keyword.get(opts, :color, :black)
    opacity = Keyword.get(opts, :opacity, 0.3)

    %{
      type: :shadow,
      offset: offset,
      blur: blur,
      color: color,
      opacity: opacity
    }
  end

  # Private helper functions

  @spec parse_offset(String.t()) :: {:ok, any()} | {:error, any()}
  defp parse_offset({x, y}) when is_integer(x) and is_integer(y), do: {x, y}

  @spec parse_offset(String.t()) :: {:ok, any()} | {:error, any()}
  defp parse_offset({x, y}) when is_number(x) and is_number(y),
    do: {trunc(x), trunc(y)}

  @spec parse_offset(any()) :: {integer(), integer()}
  defp parse_offset(str) when is_binary(str), do: parse_offset_string(str)
  defp parse_offset(_), do: {1, 1}

  @spec parse_offset_string(binary()) :: {integer(), integer()}
  defp parse_offset_string(str) do
    case String.split(str, ~r/\s+/) do
      [x_str, y_str] -> {parse_offset_value(x_str), parse_offset_value(y_str)}
      _ -> {1, 1}
    end
  end

  @spec parse_offset_value(binary()) :: integer()
  defp parse_offset_value(str) do
    str
    |> String.replace("px", "")
    |> String.trim()
    |> parse_integer_or_default()
  end

  @spec parse_integer_or_default(binary()) :: integer()
  defp parse_integer_or_default(""), do: 1

  defp parse_integer_or_default(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> 1
    end
  end

  @doc """
  Creates a table view.

  ## Options
    * `:data` - Table data (list of lists)
    * `:headers` - Column headers
    * `:style` - Table style options
    * `:border` - Border style for the table
  """
  def table(opts \\ []) do
    %{
      type: :table,
      # `rows:` and `data:` are both accepted (the sibling builder in
      # Raxol.View.Components uses `rows:`; callers mix the two)
      data: Keyword.get(opts, :data) || Keyword.get(opts, :rows, []),
      headers: Keyword.get(opts, :headers, []),
      style: Keyword.get(opts, :style, %{}),
      border: Keyword.get(opts, :border, :single)
    }
  end

  @doc """
  Creates a process-isolated component node.

  The component module runs in its own GenServer process under
  `Raxol.DynamicSupervisor`. If it crashes, the supervisor restarts it
  with fresh state from `init/1` -- the rest of the app continues.

  ## Parameters
    * `module` - Component module implementing `init/1`, `render/2`, and optionally `update/2`
    * `props` - Initial properties passed to `init/1`
  """
  def process_component(module, props \\ %{}) do
    %{
      type: :process_component,
      module: module,
      props: props,
      id: "pc-#{inspect(module)}"
    }
  end
end
