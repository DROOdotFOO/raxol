defmodule Raxol.UI.Components.Input.Button do
  @moduledoc """
  Button component for user input.
  """

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider
  @default_max_width Raxol.Core.Defaults.terminal_width()

  defstruct [
    :label,
    :id,
    :on_click,
    :disabled,
    :focused,
    :pressed,
    :role,
    :shortcut,
    :tooltip,
    :theme,
    :style,
    :height,
    :width,
    :errors
  ]

  @type t :: %{
          id: String.t(),
          label: String.t(),
          on_click: function() | nil,
          disabled: boolean(),
          focused: boolean(),
          pressed: boolean(),
          theme: map(),
          style: map(),
          width: integer() | nil,
          height: integer() | nil,
          shortcut: String.t() | nil,
          tooltip: String.t() | nil,
          role: :primary | :secondary | :danger | :success | nil
        }

  @doc """
  Creates a new Button state map, applying defaults.
  Expects opts to be a Map.
  """
  def new(attrs) do
    state = %__MODULE__{
      label: Map.get(attrs, :label, "Button"),
      id: Map.get(attrs, :id, nil) || Raxol.Core.ID.generate(),
      on_click: Map.get(attrs, :on_click, nil),
      disabled: Map.get(attrs, :disabled, false),
      focused: Map.get(attrs, :focused, false),
      pressed: Map.get(attrs, :pressed, false),
      role: Map.get(attrs, :role, :default),
      shortcut: Map.get(attrs, :shortcut, nil),
      tooltip: Map.get(attrs, :tooltip, nil),
      theme: Map.get(attrs, :theme, %{}),
      style: Map.get(attrs, :style, %{}),
      height: Map.get(attrs, :height, nil),
      width: Map.get(attrs, :width, nil)
    }

    %{state | errors: errors(state)}
  end

  @doc """
  Initializes the Button component state from the given props.
  """
  @impl true
  def init(state) do
    # Use Button.new to ensure defaults are applied from props
    initialized_state = new(state)

    # Validate the state and store any errors
    validation_errors = errors(initialized_state)
    state_with_errors = Map.put(initialized_state, :errors, validation_errors)

    {:ok, state_with_errors}
  end

  @doc """
  Mounts the Button component. Performs any setup needed after initialization.
  """
  @impl true
  def mount(state), do: state

  @doc """
  Unmounts the Button component, performing any necessary cleanup.
  """
  @impl true
  def unmount(state), do: state

  @doc """
  Updates the Button component state in response to messages or prop changes.
  """
  @impl true
  def update(_message, state) do
    state
  end

  @doc """
  Renders the button component based on its current state.

  ## Parameters

  * `button` - The button component to render
  * `context` - The rendering context

  ## Returns

  A rendered view representation of the button.
  """
  @impl true
  def render(button, context) do
    focused =
      Raxol.UI.FocusHelper.focused?(button.id, context) or button.focused

    button = %{button | focused: focused}

    merged_style = build_merged_style(button, context)
    {fg, bg} = resolve_colors(button, merged_style)

    button_width = calculate_width(button, context)
    button_height = button.height || 3
    # Use the truncated label if present
    display_label =
      Map.get(button, :_truncated_label) || build_display_label(button)

    %{
      type: :button,
      id: button.id,
      attrs: %{
        label: display_label,
        width: button_width,
        height: button_height,
        fg: fg,
        bg: bg,
        disabled: button.disabled,
        shortcut: button.shortcut,
        tooltip: button.tooltip,
        role: button.role,
        focused: button.focused
      },
      events: [
        Raxol.Core.Events.Event.new(:click, fn ->
          case {button.on_click, button.disabled} do
            {nil, _} -> nil
            {_, true} -> nil
            {callback, false} -> callback.()
          end
        end)
      ]
    }
  end

  @doc """
  Handles input events for the button component.

  ## Parameters

  * `event` - The input event to handle
  * `button` - The button component state
  * `context` - The event context

  ## Returns

  `{:update, updated_button}` if the button state changed,
  `{:handled, button}` if the event was handled but state didn't change,
  `:passthrough` if the event wasn't handled by the button.
  """
  @impl true
  def handle_event(%Raxol.Core.Events.Event{type: :click}, button, _context) do
    handle_click_event(button)
  end

  def handle_event(
        %Raxol.Core.Events.Event{type: :focus, data: data},
        button,
        _context
      )
      when is_map(data) do
    updated_button = %{button | focused: Map.get(data, :focused, true)}
    updated_button = %{updated_button | errors: errors(updated_button)}
    {:update, updated_button, []}
  end

  def handle_event(%Raxol.Core.Events.Event{type: :focus}, button, _context) do
    updated_button = %{button | focused: true}
    updated_button = %{updated_button | errors: errors(updated_button)}
    {:update, updated_button, []}
  end

  def handle_event(
        %Raxol.Core.Events.Event{type: :keypress, data: %{key: key}},
        button,
        _context
      ) do
    case {button.disabled, key} do
      {true, _} ->
        :passthrough

      {false, key} when key in [:space, :enter] ->
        case button.on_click do
          nil -> nil
          callback -> callback.()
        end

        {:handled, button}

      {false, _} ->
        :passthrough
    end
  end

  def handle_event(
        %Raxol.Core.Events.Event{
          type: :mouse,
          data: %{button: :left, state: :pressed}
        },
        button,
        _context
      ) do
    case button.disabled do
      true ->
        {:handled, button}

      false ->
        case button.on_click do
          nil -> nil
          callback -> callback.()
        end

        updated_button = %{button | pressed: true}

        {:update, updated_button,
         [
           {:dispatch_to_parent,
            %Raxol.Core.Events.Event{type: :button_pressed}}
         ]}
    end
  end

  def handle_event(%Raxol.Core.Events.Event{} = _event, _button, _context) do
    :passthrough
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{attrs: %{disabled: true}}), do: []

  def mcp_tools(state) do
    label = get_in(state, [:attrs, :label]) || "Button"

    [
      %{
        name: "click",
        description: "Click the '#{label}' button",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("click", _args, context) do
    widget = context.widget_state
    label = get_in(widget, [:attrs, :label]) || "Button"

    case get_in(widget, [:attrs, :disabled]) do
      true ->
        {:error, "Button '#{label}' is disabled"}

      _ ->
        {:ok, "Clicked '#{label}'",
         [
           %Raxol.Core.Events.Event{
             type: :click,
             data: %{widget_id: context.widget_id}
           }
         ]}
    end
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    attrs = Map.get(node, :attrs, %{})

    %{
      role: :button,
      label: attrs[:label],
      state: %{
        disabled?: attrs[:disabled] == true,
        focused?: attrs[:focused] == true,
        variant: attrs[:role]
      }
    }
  end

  # Add validation for invalid roles
  def errors(button) do
    errors = %{}

    errors =
      case button.role in [:default, :primary, :secondary] do
        true -> errors
        false -> Map.put(errors, :role, "Invalid role")
      end

    errors
  end

  # Private helper for handling click events
  defp handle_click_event(button) do
    case button.disabled do
      true ->
        {:handled, button}

      false ->
        case button.on_click do
          nil -> nil
          callback -> callback.()
        end

        updated_button = %{button | pressed: true}
        updated_button = %{updated_button | errors: errors(updated_button)}

        {:update, updated_button,
         [
           {:dispatch_to_parent,
            %Raxol.Core.Events.Event{type: :button_pressed}}
         ]}
    end
  end

  # Private helpers

  defp build_merged_style(button, context) do
    component_styles = context[:component_styles] || %{}
    button_theme_from_context = component_styles[:button] || %{}
    theme = Map.merge(button_theme_from_context, button.theme || %{})
    style = button.style || %{}
    # Style should override theme, so merge style into theme
    Map.merge(theme, style)
  end

  defp calculate_width(button, context) do
    # Use base label for width calculation, not decorated label
    base_label = button.label

    # Padding accounts for borders, spacing, and maximum focus decorations ("> " and " <" = 4 chars)
    # 8 for borders/spacing + 4 for focus decorations
    padding = 12
    max_width = context[:max_width] || @default_max_width
    # Calculate available space for the base label
    available_label_width = max(max_width - padding, 1)

    truncated_label =
      case Raxol.UI.TextMeasure.display_width(base_label) >
             available_label_width do
        true ->
          {truncated, _} =
            Raxol.UI.TextMeasure.split_at_display_width(
              base_label,
              available_label_width
            )

          truncated

        false ->
          base_label
      end

    # Store the truncated base label for rendering
    button = Map.put(button, :_truncated_label, truncated_label)

    button.width ||
      (Raxol.UI.TextMeasure.display_width(truncated_label) + padding)
      |> min(max_width)
  end

  # Update build_display_label to use the truncated label if present
  defp build_display_label(%{
         _truncated_label: truncated_label,
         focused: focused
       })
       when is_binary(truncated_label) do
    # Apply focus decorations to the truncated base label
    case focused do
      true -> "> #{truncated_label} <"
      false -> truncated_label
    end
  end

  defp build_display_label(button) do
    case button.focused do
      true -> "> #{button.label} <"
      false -> button.label
    end
  end

  defp resolve_colors(button, style) do
    default_fg = Map.get(style, :fg, :default)
    default_bg = Map.get(style, :bg, :default)

    case button do
      %{disabled: true} ->
        get_state_colors(style, :disabled, default_fg, default_bg)

      %{focused: true} ->
        get_state_colors(style, :focused, default_fg, default_bg)

      %{role: :primary} ->
        get_state_colors(style, :primary, default_fg, default_bg)

      %{role: :secondary} ->
        get_state_colors(style, :secondary, default_fg, default_bg)

      _ ->
        {default_fg, default_bg}
    end
  end

  defp get_state_colors(style, prefix, default_fg, default_bg) do
    fg =
      case Map.has_key?(style, :fg) do
        true -> Map.get(style, :fg)
        false -> Map.get(style, :"#{prefix}_fg", default_fg)
      end

    bg =
      case Map.has_key?(style, :bg) do
        true -> Map.get(style, :bg)
        false -> Map.get(style, :"#{prefix}_bg", default_bg)
      end

    {fg, bg}
  end
end
