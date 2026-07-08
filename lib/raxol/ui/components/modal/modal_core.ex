defmodule Raxol.UI.Components.Modal.Core do
  @moduledoc """
  Core state management and initialization for the Modal component.
  """


  @doc "Initializes the Modal component state from props."
  @spec init(map()) :: {:ok, Raxol.UI.Components.Modal.t()}
  def init(props) do
    state = %Raxol.UI.Components.Modal{
      id: Map.get(props, :id, nil),
      visible: Map.get(props, :visible, false),
      title: Map.get(props, :title, "Modal"),
      content: Map.get(props, :content),
      buttons: Map.get(props, :buttons, []),
      type: Map.get(props, :type, :alert),
      width: Map.get(props, :width, 50),
      style: Map.get(props, :style, %{}) || %{}
    }

    Raxol.Core.Runtime.Log.debug(
      "Modal init with props type: #{inspect(Map.get(props, :type, :alert))}, state type: #{inspect(state.type)}"
    )

    {:ok, initialize_form_state(state, props)}
  end

  # Helper to initialize form state based on props
  defp initialize_form_state(%{type: :prompt} = state, props) do
    # Get initial value for prompt
    initial_value = Map.get(props, :input_value, "")
    # Treat prompt as a single-field form
    field = %{
      id: :prompt_input,
      type: :text_input,
      label: state.content || "Value:",
      value: initial_value,
      props: %{},
      validate: Map.get(props, :validate)
    }

    %{
      state
      | form_state: %{fields: [normalize_field(field)], focus_index: 0},
        content: nil
    }
  end

  defp initialize_form_state(%{type: :form} = state, props) do
    fields = Map.get(props, :fields, []) |> Enum.map(&normalize_field/1)
    %{state | form_state: %{fields: fields, focus_index: 0}}
  end

  defp initialize_form_state(state, _props) do
    state
  end

  # Ensure basic field structure including :error
  defp normalize_field(field) when is_map(field) do
    Map.merge(
      %{
        id: nil,
        type: nil,
        label: "",
        value: nil,
        props: %{},
        validate: nil,
        error: nil
      },
      field
    )
  end

  # Ignore invalid field defs
  defp normalize_field(_), do: nil

  @doc "Handles show/hide state changes."
  @spec handle_show(Raxol.UI.Components.Modal.t()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_show(%Raxol.UI.Components.Modal{} = state) do
    cmd = Raxol.UI.Components.Modal.State.set_focus_command(state)
    new_state = %{state | visible: true}

    _ =
      send(
        self(),
        {:modal_state_changed, Map.get(state, :id, nil), :visible, true}
      )

    {new_state, [cmd]}
  end

  @doc "Handles hiding the modal."
  @spec handle_hide(Raxol.UI.Components.Modal.t()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_hide(%Raxol.UI.Components.Modal{} = state) do
    new_state = %{state | visible: false}

    _ =
      send(
        self(),
        {:modal_state_changed, Map.get(state, :id, nil), :visible, false}
      )

    {new_state, []}
  end

  @doc "Handles cancel operations."
  @spec handle_cancel(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_cancel(%Raxol.UI.Components.Modal{} = state, original_msg) do
    new_state = %{state | visible: false}

    _ =
      send(
        self(),
        {:modal_state_changed, Map.get(state, :id, nil), :visible, false}
      )

    {new_state, [original_msg]}
  end

  @doc "Handles button click operations."
  @spec handle_button_click(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_button_click(%Raxol.UI.Components.Modal{} = state, btn_msg) do
    new_state = %{state | visible: false}

    _ =
      send(
        self(),
        {:modal_state_changed, Map.get(state, :id, nil), :visible, false}
      )

    {new_state, [btn_msg]}
  end

  @doc "Handles unknown messages."
  @spec handle_unknown_message(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_unknown_message(state, msg) do
    Raxol.Core.Runtime.Log.warning(
      "Modal #{Map.get(state, :id, nil)} received unknown message: #{inspect(msg)}"
    )

    {state, []}
  end
end
