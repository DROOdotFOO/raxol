defmodule Raxol.Agent.Action.Schema do
  @moduledoc """
  Lightweight schema validation for Action input/output.

  No external dependencies -- pure pattern matching on keyword list specs.

  ## Field Specs

      schema = [
        path: [type: :string, required: true, description: "File path"],
        timeout: [type: :integer, default: 5000],
        format: [type: :string, enum: ["json", "text"], default: "text"]
      ]

  Supported types: `:string`, `:integer`, `:float`, `:boolean`, `:atom`,
  `:map`, `:list`, `{:list, type}`.
  """

  @type field_spec :: keyword()
  @type schema :: [{atom(), field_spec()}]

  @doc """
  Validate params against a schema.

  Returns `{:ok, validated_params}` with defaults applied,
  or `{:error, [{field, reason}]}` on failure.
  """
  @spec validate(map(), schema()) ::
          {:ok, map()} | {:error, [{atom(), String.t()}]}
  def validate(params, schema) when is_map(params) and is_list(schema) do
    {result, errors} =
      Enum.reduce(schema, {params, []}, fn {field, spec}, {acc, errs} ->
        validate_field(field, spec, acc, errs)
      end)

    case errors do
      [] -> {:ok, result}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Convert a schema to a JSON Schema-compatible tool definition.

  Produces the OpenAI/Anthropic function calling format:

      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => description,
          "parameters" => %{
            "type" => "object",
            "properties" => %{...},
            "required" => [...]
          }
        }
      }
  """
  @spec to_json_schema(schema(), String.t(), String.t()) :: map()
  def to_json_schema(schema, name, description \\ "") do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, fn {field, spec}, {props, req} ->
        prop = field_to_json_schema(spec)
        props = Map.put(props, to_string(field), prop)

        req =
          if Keyword.get(spec, :required, false),
            do: [to_string(field) | req],
            else: req

        {props, req}
      end)

    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => Enum.reverse(required)
        }
      }
    }
  end

  # -- Field validation --------------------------------------------------------

  defp validate_field(field, spec, params, errors) do
    required = Keyword.get(spec, :required, false)
    default = Keyword.get(spec, :default)
    type = Keyword.get(spec, :type)
    enum_values = Keyword.get(spec, :enum)

    case fetch_present(params, field) do
      {:ok, value} ->
        with :ok <- check_type(field, type, value),
             :ok <- check_enum(field, enum_values, value) do
          {params, errors}
        else
          {:error, err} -> {params, [err | errors]}
        end

      :error when required ->
        {params, [{field, "is required"} | errors]}

      :error when not is_nil(default) ->
        {Map.put(params, field, default), errors}

      :error ->
        {params, errors}
    end
  end

  # A present-but-nil value is treated as absent. Optional fields therefore
  # accept nil (there is no value to type-check), which lets an Action declare
  # a conditional output field -- e.g. a stealth address that exists only for a
  # stealth settlement and is nil for a public one -- without the value tripping
  # its own output schema. A nil for a required field still reports "is required".
  defp fetch_present(params, field) do
    case Map.fetch(params, field) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp check_type(_field, nil, _value), do: :ok
  defp check_type(_field, :string, value) when is_binary(value), do: :ok
  defp check_type(_field, :integer, value) when is_integer(value), do: :ok
  defp check_type(_field, :float, value) when is_float(value), do: :ok
  defp check_type(_field, :float, value) when is_integer(value), do: :ok
  defp check_type(_field, :boolean, value) when is_boolean(value), do: :ok
  defp check_type(_field, :atom, value) when is_atom(value), do: :ok
  defp check_type(_field, :map, value) when is_map(value), do: :ok
  defp check_type(_field, :list, value) when is_list(value), do: :ok

  defp check_type(field, {:list, inner_type}, value) when is_list(value) do
    if Enum.all?(value, &type_matches?(inner_type, &1)),
      do: :ok,
      else: {:error, {field, "must be a list of #{inner_type}"}}
  end

  defp check_type(field, type, _value) do
    {:error, {field, "must be of type #{inspect(type)}"}}
  end

  defp check_enum(_field, nil, _value), do: :ok

  defp check_enum(field, enum_values, value) do
    if value in enum_values,
      do: :ok,
      else: {:error, {field, "must be one of #{inspect(enum_values)}"}}
  end

  defp type_matches?(:string, v), do: is_binary(v)
  defp type_matches?(:integer, v), do: is_integer(v)
  defp type_matches?(:float, v), do: is_float(v) or is_integer(v)
  defp type_matches?(:boolean, v), do: is_boolean(v)
  defp type_matches?(:atom, v), do: is_atom(v)
  defp type_matches?(:map, v), do: is_map(v)
  defp type_matches?(:list, v), do: is_list(v)
  defp type_matches?(_, _), do: false

  # -- JSON Schema conversion --------------------------------------------------

  defp field_to_json_schema(spec) do
    type = Keyword.get(spec, :type)
    desc = Keyword.get(spec, :description)
    enum_values = Keyword.get(spec, :enum)

    prop = %{"type" => type_to_json(type)}
    prop = if desc, do: Map.put(prop, "description", desc), else: prop
    prop = if enum_values, do: Map.put(prop, "enum", enum_values), else: prop
    prop
  end

  defp type_to_json(:string), do: "string"
  defp type_to_json(:integer), do: "integer"
  defp type_to_json(:float), do: "number"
  defp type_to_json(:boolean), do: "boolean"
  defp type_to_json(:atom), do: "string"
  defp type_to_json(:map), do: "object"
  defp type_to_json(:list), do: "array"
  defp type_to_json({:list, _}), do: "array"
  defp type_to_json(nil), do: "string"
end
