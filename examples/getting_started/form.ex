defmodule Raxol.Examples.FormDemo do
  @moduledoc """
  A sample form demonstrating parent-child event handling.
  """

  use Raxol.Core.Runtime.Application
  require Raxol.Core.Runtime.Log

  @impl true
  def init(_opts) do
    %{
      form_data: %{username: "", password: ""},
      submitted: false,
      active_field: :username
    }
  end

  @impl true
  def update(message, model) do
    case message do
      {:input, field, value} ->
        new_data = Map.put(model.form_data, field, value)
        {%{model | form_data: new_data}, []}

      :submit ->
        Raxol.Core.Runtime.Log.info(
          "Form submitted: #{inspect(model.form_data)}"
        )

        {%{model | submitted: true}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        next =
          if model.active_field == :username, do: :password, else: :username

        {%{model | active_field: next}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} ->
        Raxol.Core.Runtime.Log.info(
          "Form submitted: #{inspect(model.form_data)}"
        )

        {%{model | submitted: true}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}} ->
        field = model.active_field
        current = Map.get(model.form_data, field, "")
        new_val = String.slice(current, 0..-2//1)
        new_data = Map.put(model.form_data, field, new_val)
        {%{model | form_data: new_data, submitted: false}, []}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when is_binary(ch) ->
        if String.printable?(ch) do
          field = model.active_field
          current = Map.get(model.form_data, field, "")

          display =
            if field == :password, do: current <> ch, else: current <> ch

          new_data = Map.put(model.form_data, field, display)
          {%{model | form_data: new_data, submitted: false}, []}
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    box style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        [
          text("Form Demo", style: [:bold]),
          render_field("Username", :username, model),
          render_field("Password", :password, model),
          text(""),
          button("Submit", on_click: :submit),
          if model.submitted do
            text("Submitted!", style: [:bold])
          else
            text("[Tab] switch | [Enter] submit | [Ctrl+C] quit")
          end
        ]
      end
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp render_field(label, field, model) do
    active = model.active_field == field
    value = Map.get(model.form_data, field, "")

    display =
      if field == :password,
        do: String.duplicate("*", String.length(value)),
        else: value

    prefix = if active, do: "> ", else: "  "
    cursor = if active, do: "_", else: ""

    text("#{prefix}#{label}: #{display}#{cursor}")
  end
end
