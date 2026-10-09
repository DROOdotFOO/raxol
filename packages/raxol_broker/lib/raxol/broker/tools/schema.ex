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
      [] ->
        :ok

      errors ->
        {:error, Enum.map(errors, fn {rpath, reason} -> {Enum.reverse(rpath), reason} end)}
    end
  end

  # Paths are built innermost-first (`rpath`) and reversed once in `validate/2`.
  defp errors(schema, value, rpath) do
    with [] <- type_errors(schema, value, rpath) do
      Enum.flat_map(
        [&enum_errors/3, &range_errors/3, &length_errors/3, &object_errors/3, &array_errors/3],
        & &1.(schema, value, rpath)
      )
    end
  end

  defp type_errors(%{"type" => type}, value, rpath) do
    if Enum.any?(List.wrap(type), &type?(&1, value)),
      do: [],
      else: [{rpath, {:type, type}}]
  end

  defp type_errors(_schema, _value, _rpath), do: []

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("number", value), do: is_number(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)
  defp type?(_unknown, _value), do: false

  defp enum_errors(%{"enum" => allowed}, value, rpath) when is_list(allowed),
    do: if(value in allowed, do: [], else: [{rpath, {:enum, allowed}}])

  defp enum_errors(_schema, _value, _rpath), do: []

  defp range_errors(schema, value, rpath) when is_number(value),
    do: bound_errors(schema, value, rpath, &is_number/1, minimum: :min, maximum: :max)

  defp range_errors(_schema, _value, _rpath), do: []

  defp length_errors(schema, value, rpath) when is_binary(value),
    do:
      bound_errors(schema, String.length(value), rpath, &is_integer/1,
        minLength: :min,
        maxLength: :max
      )

  defp length_errors(_schema, _value, _rpath), do: []

  # One error per bound in `bounds` (`schema key => :min | :max`) that the
  # schema sets with a valid value and `measure` falls outside.
  defp bound_errors(schema, measure, rpath, valid_bound?, bounds) do
    for {key, side} <- bounds,
        bound = Map.get(schema, Atom.to_string(key)),
        valid_bound?.(bound),
        outside?(side, measure, bound),
        do: {rpath, {key, bound}}
  end

  defp outside?(:min, measure, bound), do: measure < bound
  defp outside?(:max, measure, bound), do: measure > bound

  defp object_errors(schema, value, rpath) when is_map(value) do
    key_errors(value, rpath) ++
      missing_errors(schema, value, rpath) ++
      extra_errors(schema, value, rpath) ++ property_errors(schema, value, rpath)
  end

  defp object_errors(_schema, _value, _rpath), do: []

  defp key_errors(value, rpath),
    do: for(key <- Map.keys(value), not is_binary(key), do: {rpath, {:key_not_string, key}})

  defp missing_errors(schema, value, rpath) do
    for key <- Map.get(schema, "required", []),
        not Map.has_key?(value, key),
        do: {[key | rpath], :required}
  end

  defp extra_errors(%{"additionalProperties" => false} = schema, value, rpath) do
    properties = Map.get(schema, "properties", %{})

    for key <- Map.keys(value),
        is_binary(key),
        not Map.has_key?(properties, key),
        do: {[key | rpath], :unknown_property}
  end

  defp extra_errors(_schema, _value, _rpath), do: []

  defp property_errors(schema, value, rpath) do
    for {key, sub} <- Map.get(schema, "properties", %{}),
        Map.has_key?(value, key),
        error <- errors(sub, value[key], [key | rpath]),
        do: error
  end

  defp array_errors(%{"items" => items}, value, rpath) when is_map(items) and is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> errors(items, item, [index | rpath]) end)
  end

  defp array_errors(_schema, _value, _rpath), do: []
end
