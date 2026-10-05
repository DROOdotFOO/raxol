defmodule Raxol.Broker.Tools.Schema do
  @moduledoc """
  Validates tool arguments against a captured `inputSchema` before anything
  is sent.

  The subset of JSON Schema Robinhood's tool list uses: `type` (one name or a
  list), `properties`, `required`, `additionalProperties: false`, `items`,
  `enum`, `minimum`, `maximum`, `minLength`, `maxLength`. Other keywords are
  not checked here; the server stays the final authority. Object keys must
  be strings, as they are on the wire.
  """

  @type error :: {path :: [String.t() | non_neg_integer()], reason :: term()}

  @doc "`:ok`, or every violation with its path."
  @spec validate(map(), term()) :: :ok | {:error, [error()]}
  def validate(schema, value) when is_map(schema) do
    case errors(schema, value, []) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp errors(schema, value, path) do
    with [] <- type_errors(schema, value, path) do
      Enum.flat_map(
        [&enum_errors/3, &range_errors/3, &length_errors/3, &object_errors/3, &array_errors/3],
        & &1.(schema, value, path)
      )
    end
  end

  defp type_errors(%{"type" => type}, value, path) do
    if Enum.any?(List.wrap(type), &type?(&1, value)),
      do: [],
      else: [{path, {:type, type}}]
  end

  defp type_errors(_schema, _value, _path), do: []

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("number", value), do: is_number(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)
  defp type?(_unknown, _value), do: false

  defp enum_errors(%{"enum" => allowed}, value, path) when is_list(allowed),
    do: if(value in allowed, do: [], else: [{path, {:enum, allowed}}])

  defp enum_errors(_schema, _value, _path), do: []

  defp range_errors(schema, value, path) when is_number(value) do
    Enum.flat_map([{"minimum", &>=/2}, {"maximum", &<=/2}], fn {key, ok?} ->
      case Map.fetch(schema, key) do
        {:ok, bound} when is_number(bound) ->
          if ok?.(value, bound), do: [], else: [{path, {String.to_atom(key), bound}}]

        _ ->
          []
      end
    end)
  end

  defp range_errors(_schema, _value, _path), do: []

  defp length_errors(schema, value, path) when is_binary(value) do
    length = String.length(value)

    Enum.flat_map([{"minLength", &>=/2}, {"maxLength", &<=/2}], fn {key, ok?} ->
      case Map.fetch(schema, key) do
        {:ok, bound} when is_integer(bound) ->
          if ok?.(length, bound), do: [], else: [{path, {String.to_atom(key), bound}}]

        _ ->
          []
      end
    end)
  end

  defp length_errors(_schema, _value, _path), do: []

  defp object_errors(schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    key_errors =
      for key <- Map.keys(value), not is_binary(key), do: {path, {:key_not_string, key}}

    missing =
      for key <- Map.get(schema, "required", []),
          not Map.has_key?(value, key),
          do: {path ++ [key], :required}

    extra =
      if Map.get(schema, "additionalProperties") == false,
        do:
          for(
            key <- Map.keys(value),
            is_binary(key),
            not Map.has_key?(properties, key),
            do: {path ++ [key], :unknown_property}
          ),
        else: []

    nested =
      for {key, sub} <- properties,
          Map.has_key?(value, key),
          error <- errors(sub, value[key], path ++ [key]),
          do: error

    key_errors ++ missing ++ extra ++ nested
  end

  defp object_errors(_schema, _value, _path), do: []

  defp array_errors(%{"items" => items}, value, path) when is_map(items) and is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> errors(items, item, path ++ [index]) end)
  end

  defp array_errors(_schema, _value, _path), do: []
end
