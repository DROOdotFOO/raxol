defmodule Raxol.UI.Components.Modal.State do
  @moduledoc """
  State management and form validation for the Modal component.
  """


  @doc "Handles form submission with validation."
  @spec handle_form_submission(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_form_submission(%Raxol.UI.Components.Modal{} = state, original_msg) do
    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] handle_form_submission called with state.visible=#{inspect(state.visible)} and fields=#{inspect(state.form_state.fields)}"
    )

    validated_fields = Enum.map(state.form_state.fields, &validate_field/1)
    has_errors = Enum.any?(validated_fields, &(&1.error != nil))
    apply_form_submission(has_errors, validated_fields, state, original_msg)
  end

  defp apply_form_submission(true, validated_fields, state, _original_msg) do
    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] handle_form_submission found errors: #{inspect(validated_fields)}"
    )

    new_form_state = %{state.form_state | fields: validated_fields}

    result =
      {%{state | form_state: new_form_state, visible: true}, []}

    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] handle_form_submission returning (errors): #{inspect(result)}"
    )

    result
  end

  defp apply_form_submission(false, validated_fields, state, original_msg) do
    form_values = extract_form_values(validated_fields)
    cleared_fields = Enum.map(validated_fields, &Map.put(&1, :error, nil))
    new_form_state = %{state.form_state | fields: cleared_fields}

    new_state = %{
      state
      | visible: false,
        form_state: new_form_state
    }

    _ =
      send(
        self(),
        {:modal_state_changed, Map.get(state, :id, nil), :visible, false}
      )

    result = {new_state, [{original_msg, form_values}]}

    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] handle_form_submission returning (success): #{inspect(result)}"
    )

    result
  end

  @doc "Handles prompt submission."
  @spec handle_prompt_submission(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_prompt_submission(
        %Raxol.UI.Components.Modal{} = state,
        original_msg
      ) do
    # If there are fields, validate as form
    case length(state.form_state.fields) do
      count when count > 0 ->
        handle_form_submission(state, original_msg)

      0 ->
        # No fields: just hide and send command
        new_state = %{state | visible: false}

        _ =
          send(
            self(),
            {:modal_state_changed, Map.get(state, :id, nil), :visible, false}
          )

        {new_state, [{original_msg, %{}}]}
    end
  end

  @doc "Handles prompt input changes."
  @spec handle_prompt_input(Raxol.UI.Components.Modal.t(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def handle_prompt_input(state, value) do
    update_field_value(
      state,
      state.form_state.fields |> hd() |> Map.get(:id),
      value
    )
  end

  @doc "Updates field value and clears errors."
  @spec update_field_value(Raxol.UI.Components.Modal.t(), any(), any()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def update_field_value(
        %Raxol.UI.Components.Modal{} = state,
        field_id,
        new_value
      ) do
    updated_fields =
      Enum.map(state.form_state.fields, fn field ->
        case field.id == field_id do
          true ->
            # Clear error on update
            %{field | value: new_value, error: nil}

          false ->
            field
        end
      end)

    new_form_state = %{state.form_state | fields: updated_fields}
    {%{state | form_state: new_form_state}, []}
  end

  @doc "Changes focus between form fields."
  @spec change_focus(Raxol.UI.Components.Modal.t(), integer()) ::
          {Raxol.UI.Components.Modal.t(), list()}
  def change_focus(%Raxol.UI.Components.Modal{} = state, direction) do
    field_count = length(state.form_state.fields)

    Raxol.Core.Runtime.Log.debug(
      "[DEBUG] change_focus called with direction=#{inspect(direction)}, field_count=#{inspect(field_count)}, current_index=#{inspect(state.form_state.focus_index)}"
    )

    case field_count do
      count when count > 0 ->
        new_index =
          rem(
            state.form_state.focus_index + direction + field_count,
            field_count
          )

        new_form_state = %{state.form_state | focus_index: new_index}

        new_state = %{
          state
          | form_state: new_form_state
        }

        Raxol.Core.Runtime.Log.debug(
          "[DEBUG] change_focus returning new_index=#{inspect(new_index)}, new_state.form_state.focus_index=#{inspect(new_state.form_state.focus_index)}"
        )

        {new_state, [set_focus_command(new_state)]}

      0 ->
        {state, []}
    end
  end

  @doc "Generates set_focus command for current field."
  @spec set_focus_command(Raxol.UI.Components.Modal.t()) :: {atom(), any()}
  def set_focus_command(state) do
    field_count = length(state.form_state.fields)

    case field_count do
      count when count > 0 ->
        current_field =
          Enum.at(state.form_state.fields, state.form_state.focus_index)

        field_id = get_field_full_id(current_field, state)
        {:set_focus, field_id}

      0 ->
        {:set_focus, state.id}
    end
  end

  @doc "Gets field full ID with modal prefix if modal has ID."
  @spec get_field_full_id(map(), Raxol.UI.Components.Modal.t()) ::
          String.t() | any()
  def get_field_full_id(field, state) do
    case Map.get(state, :id, nil) do
      nil -> field.id
      id -> "#{id}.#{field.id}"
    end
  end

  # Validate a single field based on its :validate rule
  defp validate_field(field) do
    validator = field.validate
    value = field.value

    valid? =
      case validator do
        # No validation rule
        nil ->
          true

        regex when is_struct(regex) ->
          Regex.match?(regex, to_string(value))

        fun when is_function(fun, 1) ->
          fun.(value)

        _ ->
          Raxol.Core.Runtime.Log.warning(
            "Invalid validator for field #{field.id}: #{inspect(validator)}"
          )

          # Treat invalid validator as passing
          true
      end

    case valid? do
      true ->
        # Clear any previous error
        %{field | error: nil}

      false ->
        # Basic error message, could be configurable
        %{field | error: "Invalid input"}
    end
  end

  # Helper to extract values from form fields
  defp extract_form_values(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      Map.put(acc, field.id, field.value)
    end)
  end
end
