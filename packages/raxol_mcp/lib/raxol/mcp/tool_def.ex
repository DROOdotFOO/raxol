defmodule Raxol.MCP.ToolDef do
  @moduledoc """
  Validated builder for MCP tool definitions.

  `Raxol.MCP.Registry.register_tools/2` accepts a list of maps with
  `:name`, `:description`, `:inputSchema`, and `:callback` keys. The shape
  is documented as a `tool_def` type but isn't validated until call
  time -- typos like `:input_schema` instead of `:inputSchema` silently
  miss the registration; tools without callbacks blow up only when an
  agent tries to invoke them.

  This module catches those mistakes at the seam:

      tool =
        Raxol.MCP.ToolDef.new!("symphony_list_runs",
          description: "Returns a snapshot of active Symphony runs.",
          input_schema: %{type: "object", properties: %{}},
          callback: fn _args -> %{ok: true} end
        )

      Raxol.MCP.Registry.register_tools(registry, [tool])

  `new/2` returns `{:ok, def}` or `{:error, reasons}`. `new!/2` raises
  on validation failure.

  Both spellings of the schema key are accepted (`:inputSchema` and
  `:input_schema`); the canonical key on the returned map is
  `:inputSchema` to match the MCP spec.
  """

  @type t :: Raxol.MCP.Registry.tool_def()

  @type validation_error ::
          :missing_name
          | :missing_description
          | :missing_callback
          | :invalid_callback_arity
          | :missing_input_schema
          | :invalid_input_schema

  @doc """
  Builds a validated tool definition.

  Required:

  - `name` -- string, non-empty.
  - `:description` -- string, non-empty.
  - `:callback` -- 1-arity function (receives the arguments map).
  - `:input_schema` (or `:inputSchema`) -- map with at minimum `:type` /
    `"type"` set to `"object"`.

  Returns `{:ok, def}` (a map matching `Raxol.MCP.Registry.tool_def()`)
  or `{:error, [validation_error()]}`.
  """
  @spec new(String.t(), keyword()) ::
          {:ok, t()} | {:error, [validation_error()]}
  def new(name, opts) when is_binary(name) and is_list(opts) do
    description = Keyword.get(opts, :description)
    callback = Keyword.get(opts, :callback)
    schema = Keyword.get(opts, :input_schema) || Keyword.get(opts, :inputSchema)

    errors =
      []
      |> validate_name(name)
      |> validate_description(description)
      |> validate_callback(callback)
      |> validate_schema(schema)
      |> Enum.reverse()

    case errors do
      [] ->
        {:ok,
         %{
           name: name,
           description: description,
           inputSchema: schema,
           callback: callback
         }}

      errors ->
        {:error, errors}
    end
  end

  def new(_name, _opts), do: {:error, [:missing_name]}

  @doc """
  Like `new/2` but raises `ArgumentError` on validation failure.
  """
  @spec new!(String.t(), keyword()) :: t()
  def new!(name, opts) do
    case new(name, opts) do
      {:ok, def} ->
        def

      {:error, errors} ->
        raise ArgumentError,
              "invalid tool definition for #{inspect(name)}: #{inspect(errors)}"
    end
  end

  @doc """
  Validates an existing tool map (e.g., one built directly without `new/2`).

  Useful when adopting `ToolDef` incrementally -- run validation on a list
  of hand-built tools at registration time and fail fast.
  """
  @spec validate(map()) :: :ok | {:error, [validation_error()]}
  def validate(%{} = map) do
    name = Map.get(map, :name) || Map.get(map, "name")
    description = Map.get(map, :description) || Map.get(map, "description")
    callback = Map.get(map, :callback)

    schema =
      Map.get(map, :inputSchema) || Map.get(map, "inputSchema") ||
        Map.get(map, :input_schema)

    errors =
      []
      |> validate_name(name)
      |> validate_description(description)
      |> validate_callback(callback)
      |> validate_schema(schema)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, [:missing_name]}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp validate_name(errors, name) when is_binary(name) and byte_size(name) > 0,
    do: errors

  defp validate_name(errors, _), do: [:missing_name | errors]

  defp validate_description(errors, d) when is_binary(d) and byte_size(d) > 0,
    do: errors

  defp validate_description(errors, _), do: [:missing_description | errors]

  defp validate_callback(errors, fun) when is_function(fun, 1), do: errors

  defp validate_callback(errors, fun) when is_function(fun),
    do: [:invalid_callback_arity | errors]

  defp validate_callback(errors, _), do: [:missing_callback | errors]

  defp validate_schema(errors, %{} = schema) do
    type = Map.get(schema, :type) || Map.get(schema, "type")

    if type == "object" do
      errors
    else
      [:invalid_input_schema | errors]
    end
  end

  defp validate_schema(errors, _), do: [:missing_input_schema | errors]
end
