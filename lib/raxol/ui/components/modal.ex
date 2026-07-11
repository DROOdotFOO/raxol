defmodule Raxol.UI.Components.Modal do
  @moduledoc """
  A modal component for displaying overlay dialogs like alerts, prompts, confirmations, and forms.
  """

  @typedoc """
  State for the Modal component.

  - :id - unique identifier
  - :visible - whether the modal is visible
  - :title - modal title
  - :content - modal content (text or view elements)
  - :buttons - list of {label, message} tuples
  - :type - modal type (:alert, :confirm, :prompt, :form)
  - :width - modal width
  - :style - style map
  - :form_state - state for prompt/form fields
  """
  @type t :: %__MODULE__{
          id: any(),
          visible: boolean(),
          title: String.t(),
          content: any(),
          buttons: list(),
          type: atom(),
          width: non_neg_integer(),
          style: map(),
          form_state: map()
        }

  # Use standard component behaviour
  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  # Require view macros and components
  # require Raxol.View.Elements  # Removed
  # We will use elements directly: text_input, checkbox, dropdown
  # alias Raxol.UI.Components.Input.TextInput # Example, avoid direct component usage in render

  # Alias the new modules
  alias Raxol.UI.Components.Modal.{Core, Events, Rendering, State}
  alias Raxol.UI.Components.AbsoluteLayer

  # Define state struct
  defstruct id: nil,
            visible: false,
            title: "",
            # Can be text or other view elements
            content: nil,
            # List of {label, message} tuples
            buttons: [],
            # :alert, :confirm, :prompt, :form
            type: :alert,
            # Example default
            width: 50,
            style: %{},
            # State for prompt/form
            # input_value: nil, # Removed: Merged into form_state for prompt
            form_state: %{fields: [], focus_index: 0}

  # Example field: %{id: :my_input, type: :text_input, label: "Name:",
  #   value: "", props: %{}, validate: ~r/.+/, error: nil}

  # --- Component Behaviour Callbacks ---

  @doc "Initializes the Modal component state from props."
  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    Core.init(props)
  end

  @doc "Updates the Modal component state in response to messages. Handles show/hide, button clicks, and form updates."
  @impl Raxol.UI.Components.Base.Component
  def update(msg, state) do
    Raxol.Core.Runtime.Log.debug(
      "Modal #{Map.get(state, :id, nil)} received message: #{inspect(msg)}"
    )

    case state.visible do
      true ->
        Raxol.Core.Runtime.Log.debug(
          "Modal is visible, calling handle_visible_update with msg: #{inspect(msg)}"
        )

        handle_visible_update(msg, state)

      false ->
        handle_hidden_update(msg, state)
    end
  end

  defp handle_visible_update(msg, state) do
    case msg do
      :show ->
        Core.handle_show(state)

      :hide ->
        Core.handle_hide(state)

      {:button_click, button_msg} ->
        handle_button_click_msg(button_msg, state)

      {:field_update, field_id, new_value} ->
        State.update_field_value(state, field_id, new_value)

      :focus_next_field ->
        State.change_focus(state, 1)

      :focus_prev_field ->
        State.change_focus(state, -1)

      {:input_changed, value} when state.type == :prompt ->
        State.handle_prompt_input(state, value)

      _ ->
        Core.handle_unknown_message(state, msg)
    end
  end

  defp handle_button_click_msg({:submit, original_msg}, state) do
    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] handle_button_click_msg called with submit message: #{inspect(original_msg)} and state.visible=#{inspect(state.visible)}"
    )

    case state.type do
      :prompt -> State.handle_prompt_submission(state, original_msg)
      _ -> State.handle_form_submission(state, original_msg)
    end
  end

  defp handle_button_click_msg({:cancel, original_msg}, state),
    do: Core.handle_cancel(state, original_msg)

  defp handle_button_click_msg(btn_msg, state),
    do: Core.handle_button_click(state, btn_msg)

  defp handle_hidden_update(msg, state) do
    case msg do
      :show ->
        Core.handle_show(state)

      _ ->
        {state, []}
    end
  end

  @impl Raxol.UI.Components.Base.Component
  def handle_event(event, state, %{} = _context) do
    Raxol.Core.Runtime.Log.debug(
      "Modal #{Map.get(state, :id, nil)} received event: #{inspect(event)} with state.type: #{inspect(state.type)}"
    )

    case state.visible do
      true ->
        case Events.handle_visible_event(event, state) do
          {:button_click, msg} ->
            update({:button_click, msg}, state)

          :focus_next_field ->
            update(:focus_next_field, state)

          :focus_prev_field ->
            update(:focus_prev_field, state)

          {:input_changed, value} ->
            update({:input_changed, value}, state)

          nil ->
            {state, []}
        end

      false ->
        {state, []}
    end
  end

  # --- Render Logic ---

  @impl Raxol.UI.Components.Base.Component
  def render(state, %{} = _props) do
    case state.visible do
      true -> Rendering.render_modal_content(state)
      false -> nil
    end
  end

  @doc """
  Wraps `flow_content` as an `:absolute_layer` with this modal as a
  centered, dimmed-backdrop dialog overlay (no-op passthrough when
  hidden). Prefer this over replacing the flow tree with
  `Modal.render(state, %{})`, which reflows background content.
  """
  @spec as_dialog_overlay(t(), map()) :: map()
  def as_dialog_overlay(%__MODULE__{visible: false}, flow_content),
    do: flow_content

  def as_dialog_overlay(%__MODULE__{visible: true} = state, flow_content) do
    width = state.width
    height = Rendering.estimate_height(state)
    box_style = Rendering.get_modal_style(state)
    # render_modal_content/1 already wraps its column with padding: 1;
    # dialog_surface/4 adds its own padding ring, so strip this one to
    # avoid double-padding the overlay (see dialog_surface/4 contract).
    content_column = unpad(Rendering.render_modal_content(state).children)

    surface =
      Rendering.dialog_surface(width, height, box_style, [content_column])

    AbsoluteLayer.absolute_layer(flow_content, [
      AbsoluteLayer.dialog_overlay(width, height, surface)
    ])
  end

  defp unpad(%{style: style} = node) when is_map(style),
    do: %{node | style: Map.put(style, :padding, 0)}

  defp unpad(node), do: node

  # --- Public Helper Functions (Constructors) ---

  # Simplified
  @doc "Creates props for an alert modal."
  def alert(id, title, content, opts \\ []) do
    props =
      Keyword.merge(
        [
          id: id,
          title: title,
          content: content,
          type: :alert,
          buttons: [{"OK", :ok}],
          visible: true
        ],
        opts
      )

    # Returns props map, caller uses Component.new(Modal, props)
    props
  end

  # Simplified
  @doc "Creates props for a confirmation modal."
  def confirm(
        id,
        title,
        content,
        on_confirm \\ :confirm,
        on_cancel \\ :cancel,
        opts \\ []
      ) do
    buttons = [{"Yes", on_confirm}, {"No", on_cancel}]

    props =
      Keyword.merge(opts,
        id: id,
        title: title,
        content: content,
        type: :confirm,
        buttons: buttons,
        visible: true
      )

    props
  end

  # Simplified
  @doc "Creates props for a prompt modal."
  def prompt(
        id,
        title,
        content,
        on_submit \\ :submit,
        on_cancel \\ :cancel,
        opts \\ []
      ) do
    # Prompt is now treated as a single-field form internally
    # The 'submit' message will carry the input value in the payload
    buttons = [{"Submit", {:submit, on_submit}}, {"Cancel", on_cancel}]

    props =
      Keyword.merge(opts,
        id: id,
        title: title,
        # Used for label if no field def provided
        content: content,
        type: :prompt,
        buttons: buttons,
        visible: true,
        # Initial value
        input_value: Keyword.get(opts, :default_value, ""),
        # Pass validation rule
        validate: Keyword.get(opts, :validate)
      )

    props
  end

  @doc """
  Creates props for a form modal.

  `fields` should be a list of maps, each defining a form field:
  `%{id: :atom, type: :text_input | :checkbox | :dropdown, label: "string", value: initial_value, props: keyword_list, options: list, validate: regex | function}`
  (options only for dropdown)
  """
  def form(
        id,
        title,
        fields,
        on_submit \\ :submit,
        on_cancel \\ :cancel,
        opts \\ []
      ) do
    buttons = [{"Submit", {:submit, on_submit}}, {"Cancel", on_cancel}]

    props =
      Keyword.merge(opts,
        id: id,
        title: title,
        fields: fields,
        type: :form,
        buttons: buttons,
        visible: true
      )

    props
  end

  @doc """
  Mount hook - called when component is mounted.
  No special setup needed for Modal.
  """
  @impl true
  def mount(state), do: {state, []}

  @doc """
  Unmount hook - called when component is unmounted.
  No cleanup needed for Modal.
  """
  @impl true
  def unmount(state), do: state

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{visible: false}), do: []

  def mcp_tools(state) do
    title = state[:title] || "Modal"

    [
      %{
        name: "dismiss",
        description: "Dismiss the '#{title}' modal",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "confirm",
        description: "Confirm/accept the '#{title}' modal",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("dismiss", _args, context) do
    {:ok, "Dismissed modal", [{:modal_dismiss, context.widget_id}]}
  end

  def handle_tool_call("confirm", _args, context) do
    {:ok, "Confirmed modal", [{:modal_confirm, context.widget_id}]}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    # Children omitted: the projection recurses the modal's own content Elements.
    %{role: :dialog, label: node[:title] || node[:aria_label], state: %{}}
  end
end
