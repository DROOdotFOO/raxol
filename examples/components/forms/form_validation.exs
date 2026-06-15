# Form Validation
#
# Demonstrates a form with field validation using TEA pattern.
#
# Usage:
#   mix run examples/components/forms/form_validation.exs

defmodule FormValidationExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @fields [:name, :email]

  @impl true
  def init(_context) do
    %{
      name: "",
      email: "",
      errors: %{},
      active_field: :name,
      submitted: false
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Tab between fields
      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        next = next_field(model.active_field)
        {%{model | active_field: next}, []}

      # Submit with Enter
      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} ->
        errors = validate(model)

        if errors == %{} do
          {%{model | submitted: true, errors: %{}}, []}
        else
          {%{model | errors: errors, submitted: false}, []}
        end

      # Backspace
      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}} ->
        field = model.active_field
        current = Map.get(model, field, "")
        new_val = String.slice(current, 0..-2//1)
        new_errors = Map.delete(model.errors, field)
        {%{model | field => new_val, errors: new_errors, submitted: false}, []}

      # Type characters into active field
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "q", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when is_binary(ch) ->
        if String.printable?(ch) do
          field = model.active_field
          current = Map.get(model, field, "")
          new_errors = Map.delete(model.errors, field)

          {%{
             model
             | field => current <> ch,
               errors: new_errors,
               submitted: false
           }, []}
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Form Validation Demo", style: [:bold]),
        box title: "Registration", style: %{border: :single, padding: 1} do
          column style: %{gap: 1} do
            [
              render_field("Name", :name, model),
              render_field("Email", :email, model),
              text(""),
              text("[Tab] switch field | [Enter] submit | [Ctrl+C] quit"),
              if model.submitted do
                text("Form submitted successfully!", style: [:bold])
              else
                text("")
              end
            ]
          end
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp render_field(label, field, model) do
    active = model.active_field == field
    value = Map.get(model, field, "")
    error = Map.get(model.errors, field)
    prefix = if active, do: "> ", else: "  "
    cursor = if active, do: "_", else: ""
    error_text = if error, do: "  (#{error})", else: ""

    text("#{prefix}#{label}: #{value}#{cursor}#{error_text}")
  end

  defp next_field(:name), do: :email
  defp next_field(:email), do: :name

  defp validate(model) do
    errors = %{}

    errors =
      if String.trim(model.name) == "",
        do: Map.put(errors, :name, "required"),
        else: errors

    errors =
      cond do
        String.trim(model.email) == "" ->
          Map.put(errors, :email, "required")

        not String.contains?(model.email, "@") ->
          Map.put(errors, :email, "must contain @")

        true ->
          errors
      end

    errors
  end
end

Raxol.Core.Runtime.Log.info("FormValidationExample: Starting...")
{:ok, pid} = Raxol.start_link(FormValidationExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
