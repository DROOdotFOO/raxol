defprotocol Raxol.Protocols.Serializable do
  @moduledoc """
  Protocol for serializing and deserializing data structures.

  This protocol provides a unified interface for converting data structures
  to and from various formats like JSON, TOML, and binary formats.

  ## Examples

      defimpl Raxol.Protocols.Serializable, for: MyStruct do
        def serialize(data, :json) do
          data
          |> Map.from_struct()
          |> Jason.encode!()
        end

        def deserialize(data, :json, MyStruct) do
          data
          |> Jason.decode!()
          |> then(&struct(MyStruct, &1))
        end

        def serializable?(data, format) do
          format in [:json, :toml]
        end
      end
  """

  @type format :: :json | :toml | :binary | :erlang_term | atom()

  @doc """
  Serializes data to the specified format.

  ## Formats

    * `:json` - JSON string using Jason
    * `:toml` - TOML string
    * `:binary` - Binary format using :erlang.term_to_binary
    * `:erlang_term` - Erlang external term format

  ## Returns

  A string or binary containing the serialized data, or `{:error, reason}`.
  """
  @spec serialize(t, format()) :: binary() | {:error, term()}
  def serialize(data, format)

  @doc """
  Checks if the data can be serialized to the given format.

  ## Returns

  `true` if the data can be serialized to the format, `false` otherwise.
  """
  @spec serializable?(t, format()) :: boolean()
  def serializable?(data, format)
end

# Implementation for maps (most common case)
defimpl Raxol.Protocols.Serializable, for: Map do
  def serialize(map, :json) do
    serializable_map = filter_serializable_for_json(map)

    case Jason.encode(serializable_map) do
      {:ok, json} -> json
      {:error, reason} -> {:error, reason}
    end
  end

  def serialize(_map, :toml) do
    # The toml library only supports decoding, not encoding
    # For encoding, we would need a different library like tomlex
    {:error, :toml_encoding_not_supported}
  end

  def serialize(map, :binary) do
    :erlang.term_to_binary(map)
  end

  def serialize(map, :erlang_term) do
    :erlang.term_to_binary(map, [:compressed])
  end

  def serialize(_map, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_map, format) do
    format in [:json, :toml, :binary, :erlang_term]
  end

  @spec filter_serializable_for_json(map()) :: map()
  defp filter_serializable_for_json(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_function(value) ->
        {key, "#Function<#{inspect(value)}>"}

      {key, value} when is_map(value) ->
        {key, filter_serializable_for_json(value)}

      {key, value} ->
        {key, value}
    end)
  end

  @spec filter_serializable_for_json(any()) :: any()
  defp filter_serializable_for_json(value), do: value
end

# Implementation for lists
defimpl Raxol.Protocols.Serializable, for: List do
  def serialize(list, :json) do
    case Jason.encode(list) do
      {:ok, json} -> json
      {:error, reason} -> {:error, reason}
    end
  end

  def serialize(list, :binary) do
    :erlang.term_to_binary(list)
  end

  def serialize(list, :erlang_term) do
    :erlang.term_to_binary(list, [:compressed])
  end

  def serialize(_list, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_list, format) do
    format in [:json, :binary, :erlang_term]
  end
end

# Implementation for strings
defimpl Raxol.Protocols.Serializable, for: BitString do
  def serialize(string, :json) do
    case Jason.encode(string) do
      {:ok, json} -> json
      {:error, reason} -> {:error, reason}
    end
  end

  def serialize(string, :binary) do
    string
  end

  def serialize(string, :erlang_term) do
    :erlang.term_to_binary(string, [:compressed])
  end

  def serialize(_string, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_string, format) do
    format in [:json, :binary, :erlang_term]
  end
end

# Implementation for atoms
defimpl Raxol.Protocols.Serializable, for: Atom do
  def serialize(nil, :json), do: "null"
  def serialize(true, :json), do: "true"
  def serialize(false, :json), do: "false"

  def serialize(atom, :json) do
    case Jason.encode(to_string(atom)) do
      {:ok, json} -> json
      {:error, reason} -> {:error, reason}
    end
  end

  def serialize(atom, :binary) do
    :erlang.term_to_binary(atom)
  end

  def serialize(atom, :erlang_term) do
    :erlang.term_to_binary(atom, [:compressed])
  end

  def serialize(_atom, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_atom, format) do
    format in [:json, :binary, :erlang_term]
  end
end

# Implementation for numbers
defimpl Raxol.Protocols.Serializable, for: Integer do
  def serialize(integer, :json) do
    to_string(integer)
  end

  def serialize(integer, :binary) do
    :erlang.term_to_binary(integer)
  end

  def serialize(integer, :erlang_term) do
    :erlang.term_to_binary(integer, [:compressed])
  end

  def serialize(_integer, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_integer, format) do
    format in [:json, :binary, :erlang_term]
  end
end

defimpl Raxol.Protocols.Serializable, for: Float do
  def serialize(float, :json) do
    to_string(float)
  end

  def serialize(float, :binary) do
    :erlang.term_to_binary(float)
  end

  def serialize(float, :erlang_term) do
    :erlang.term_to_binary(float, [:compressed])
  end

  def serialize(_float, format) do
    {:error, {:unsupported_format, format}}
  end

  def serializable?(_float, format) do
    format in [:json, :binary, :erlang_term]
  end
end
