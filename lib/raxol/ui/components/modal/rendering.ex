defmodule Raxol.UI.Components.Modal.Rendering do
  @moduledoc """
  Rendering logic and form field rendering for the Modal component.
  """

  require Raxol.View.Elements
  require Raxol.Core.Renderer.View
  alias Raxol.UI.Components.Selection.Dropdown

  @doc "Renders the modal content when visible."
  def render_modal_content(state) do
    # Get modal style as a Map
    box_style_map = get_modal_style(state)

    # Convert style Map to Keyword list for Box.new
    box_style_keyword = Enum.map(box_style_map, fn {k, v} -> {k, v} end)

    Raxol.Core.Renderer.View.Components.Box.new(
      id: get_modal_box_id(state),
      style: box_style_keyword,
      children:
        Raxol.View.Elements.column style: %{width: :fill, padding: 1} do
          build_modal_elements(
            render_title(state.title),
            render_content(state),
            render_buttons(state.buttons)
          )
        end
    )
  end

  @doc "Renders the modal title."
  def render_title(title) do
    Raxol.View.Elements.label(content: title, style: %{bold: true})
  end

  @doc "Renders the modal content based on type."
  def render_content(%{content: content} = _state) when is_binary(content) do
    Raxol.View.Elements.label(content: content)
  end

  def render_content(%{type: type} = state) when type in [:prompt, :form] do
    render_form_content(state)
  end

  def render_content(%{content: content}) when not is_nil(content) do
    content
  end

  def render_content(_state) do
    nil
  end

  @doc "Renders modal buttons."
  def render_buttons(buttons) do
    Enum.map(buttons, fn {label, msg} ->
      Raxol.View.Elements.button(
        label: label,
        on_click: {:button_click, msg}
      )
    end)
  end

  @doc "Gets modal box ID."
  def get_modal_box_id(state) do
    build_modal_box_id(Map.get(state, :id, nil))
  end

  defp build_modal_box_id(nil), do: nil
  defp build_modal_box_id(id), do: "#{id}-box"

  @doc "Gets modal style."
  def get_modal_style(state) do
    Map.merge(
      %{border: :double, width: state.width, align: :center},
      state.style
    )
  end

  @doc """
  Builds the dialog surface: one bordered, filled box.

  A dialog is opaque by design -- the dimmed content behind it must not read
  through. It declares a background, and a box's background fills its whole
  footprint, border included, so a single box is the whole surface.

  `width`/`height` are set as top-level keys as well as in `:style`, since
  overlay layout has no auto-sizing fallback the way flow layout does.
  """
  @spec dialog_surface(pos_integer(), pos_integer(), map(), [map()]) :: map()
  def dialog_surface(width, height, box_style, children) do
    fill_bg =
      Map.get(box_style, :bg) || Map.get(box_style, :background) ||
        surface_color()

    %{
      type: :box,
      width: width,
      height: height,
      border: Map.get(box_style, :border, :double),
      padding: 1,
      style: Map.merge(box_style, %{width: width, height: height, bg: fill_bg}),
      children: children
    }
  end

  # A dialog is a surface raised above the canvas, not the canvas itself, so it
  # is painted on purpose -- but with the theme's surface colour, not a literal.
  # `:black` is a black slab on a light terminal, and the terminal owns the
  # canvas (ADR-0029).
  @default_surface "#1E1E1E"

  defp surface_color do
    Raxol.UI.Theming.Theme.current()
    |> Raxol.UI.Theming.Theme.get_color(:surface, @default_surface)
  rescue
    # No theme available (e.g. rendering outside a started application).
    _ -> @default_surface
  catch
    :exit, _ -> @default_surface
  end

  @doc """
  Structural line-count estimate of the modal's total footprint height
  (no Preparer measurement pass for overlays); generous by design (e.g.
  form fields budget headroom for a validation-error row) so content
  isn't clipped.
  """
  @spec estimate_height(Raxol.UI.Components.Modal.t()) :: pos_integer()
  def estimate_height(state) do
    frame = 4
    title_rows = if blank?(state.title), do: 0, else: 1
    content_rows = estimate_content_rows(state)
    button_rows = if state.buttons == [], do: 0, else: 3

    spacer_rows =
      count_true([
        title_rows > 0 and content_rows > 0,
        content_rows > 0 and button_rows > 0
      ])

    frame + title_rows + content_rows + spacer_rows + button_rows
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp count_true(conditions), do: Enum.count(conditions, & &1)

  defp estimate_content_rows(%{content: content}) when is_binary(content) do
    content |> String.split("\n") |> length()
  end

  defp estimate_content_rows(%{type: type, form_state: %{fields: fields}})
       when type in [:prompt, :form] do
    case length(fields) do
      0 -> 0
      # row per field + inter-field gaps + headroom for error rows
      n -> 2 * n - 1 + n
    end
  end

  defp estimate_content_rows(%{content: content}) when not is_nil(content),
    do: 3

  defp estimate_content_rows(_state), do: 0

  @doc "Builds modal elements with proper spacing."
  def build_modal_elements(title_element, content_element, button_elements) do
    [
      title_element,
      render_spacer(title_element && content_element),
      content_element,
      render_spacer(content_element && button_elements != []),
      render_button_row(button_elements)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Renders spacer element."
  def render_spacer(condition) do
    render_spacer_element(condition)
  end

  defp render_spacer_element(false), do: nil

  defp render_spacer_element(_condition),
    do: Raxol.View.Elements.label(content: "")

  @doc "Renders button row."
  def render_button_row(button_elements) do
    Raxol.View.Elements.row style: %{justify: :center, width: :fill, gap: 2} do
      button_elements
    end
  end

  @doc "Renders form content with fields."
  def render_form_content(state) do
    field_elements =
      Enum.with_index(state.form_state.fields)
      |> Enum.map(&render_field(&1, state))
      |> Enum.reject(&is_nil/1)

    Raxol.View.Elements.column style: %{width: :fill, gap: 1} do
      field_elements
    end
  end

  @doc "Renders a single form field."
  def render_field({field, index}, state) do
    field_full_id =
      Raxol.UI.Components.Modal.State.get_field_full_id(field, state)

    focused? = index == state.form_state.focus_index
    common_props = get_common_props(field, field_full_id, focused?)

    input_element = render_input_element(field, common_props)
    render_field_container(field, input_element)
  end

  @doc "Gets common props for form fields."
  def get_common_props(field, field_full_id, focused?) do
    Map.merge(field.props || %{}, %{
      id: field_full_id,
      focused: focused?
    })
  end

  @doc "Renders input element based on field type."
  def render_input_element(field, common_props) do
    case field.type do
      :text_input -> render_text_input(field, common_props)
      :checkbox -> render_checkbox(field, common_props)
      :dropdown -> render_dropdown(field, common_props)
      _ -> render_unsupported_field(field)
    end
  end

  @doc "Renders text input field."
  def render_text_input(field, common_props) do
    common_props
    |> Map.merge(%{
      value: field.value || "",
      on_change: {:field_update, field.id}
    })
    |> to_safe_keyword()
    |> Raxol.View.Elements.text_input()
  end

  @doc "Renders checkbox field."
  def render_checkbox(field, common_props) do
    common_props
    |> Map.merge(%{
      checked: field.value == true,
      label: "",
      on_toggle: {:field_update, field.id}
    })
    |> to_safe_keyword()
    |> Raxol.View.Elements.checkbox()
  end

  # Normalizes a map of mixed atom/string keys to a keyword list. String keys
  # are resolved via String.to_existing_atom; unknown keys are dropped rather
  # than minted as new atoms (avoids the String.to_atom memory-leak class).
  defp to_safe_keyword(map) do
    Enum.flat_map(map, fn
      {k, v} when is_atom(k) ->
        [{k, v}]

      {k, v} when is_binary(k) ->
        try do
          [{String.to_existing_atom(k), v}]
        rescue
          ArgumentError -> []
        end
    end)
  end

  @doc "Renders dropdown field."
  def render_dropdown(field, common_props) do
    dropdown_props =
      Map.merge(common_props, %{
        "options" => field.options || [],
        "initial_value" => field.value,
        "width" => :fill,
        "on_change" => {:field_update, field.id}
      })

    %{type: Dropdown, attrs: dropdown_props}
  end

  @doc "Renders unsupported field type."
  def render_unsupported_field(field) do
    Raxol.Core.Runtime.Log.warning(
      "Unsupported form field type in Modal: #{inspect(field.type)}"
    )

    Raxol.View.Elements.label(content: "[Unsupported Field: #{field.id}]")
  end

  @doc "Renders field container with label and error."
  def render_field_container(field, input_element) do
    Raxol.View.Elements.column style: %{width: :fill, gap: 0} do
      [
        render_field_row(field, input_element),
        render_field_error(field)
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  @doc "Renders field row with label and input."
  def render_field_row(field, input_element) do
    Raxol.View.Elements.row style: %{width: :fill, gap: 1} do
      [
        render_field_label(field.label),
        input_element
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  @doc "Renders field error message."
  def render_field_error(field) do
    render_error_element(field.error)
  end

  defp render_error_element(nil), do: nil

  defp render_error_element(error) do
    Raxol.View.Elements.row style: %{width: :fill} do
      Raxol.View.Elements.label(
        content: error,
        style: %{color: :red, padding_left: 16}
      )
    end
  end

  @doc "Renders field label if present."
  def render_field_label(nil), do: nil

  def render_field_label(label) do
    Raxol.View.Elements.label(content: label, style: %{width: 15})
  end
end
