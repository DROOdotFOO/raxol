defmodule Raxol.Terminal.Commands.ParameterValidation do
  @moduledoc false

  @spec get_valid_param(
          list(integer() | nil),
          non_neg_integer(),
          integer(),
          integer(),
          integer()
        ) :: integer()
  def get_valid_param(params, index, default, min, max) do
    case Enum.at(params, index, default) do
      value when is_integer(value) and value >= min and value <= max ->
        value

      _ ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Invalid parameter value at index #{index}, using default #{default}",
          %{params: params, index: index, default: default, min: min, max: max}
        )

        default
    end
  end

  @spec get_valid_non_neg_param(
          list(integer() | nil),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  def get_valid_non_neg_param(params, index, default) do
    get_valid_param(params, index, default, 0, 9999)
  end

  @spec get_valid_pos_param(
          list(integer() | nil),
          non_neg_integer(),
          pos_integer()
        ) :: pos_integer()
  def get_valid_pos_param(params, index, default) do
    get_valid_param(params, index, default, 1, 9999)
  end

  @spec get_valid_bool_param(list(integer() | nil), non_neg_integer(), 0..1) ::
          0..1
  def get_valid_bool_param(params, index, default) do
    get_valid_param(params, index, default, 0, 1)
  end

  def validate_coordinates(emulator, params) do
    {max_x, max_y} = get_dimensions(emulator)
    x = validate_coordinate(Enum.at(params, 0), max_x)
    y = validate_coordinate(Enum.at(params, 1), max_y)
    {x, y}
  end

  defp get_dimensions(emulator) do
    width = get_dimension(emulator, :width, 0)
    height = get_dimension(emulator, :height, 1)
    {width - 1, height - 1}
  end

  defp get_dimension(emulator, key, _tuple_index) when is_map(emulator) do
    Map.get(emulator, key, 10)
  end

  defp get_dimension(emulator, _key, tuple_index) when is_tuple(emulator) do
    elem(emulator, tuple_index)
  end

  defp get_dimension(_emulator, _key, _tuple_index) do
    10
  end

  defp validate_coordinate(value, _max) when is_integer(value) and value < 0,
    do: 0

  defp validate_coordinate(value, max) when is_integer(value) and value > max,
    do: max

  defp validate_coordinate(value, _max) when is_integer(value), do: value
  defp validate_coordinate(_value, _max), do: 0

  def validate_count(_emulator, params) do
    case Enum.at(params, 0) do
      v when is_integer(v) and v >= 1 and v <= 10 -> v
      v when is_integer(v) and v < 1 -> 1
      v when is_integer(v) and v > 10 -> 10
      _ -> 1
    end
  end

  def validate_mode(params) do
    case Enum.at(params, 0) do
      v when v in [0, 1, 2] -> v
      _ -> 0
    end
  end

  def validate_color(params) do
    case Enum.at(params, 0) do
      v when is_integer(v) and v >= 0 and v <= 255 -> v
      v when is_integer(v) and v < 0 -> 0
      v when is_integer(v) and v > 255 -> 255
      _ -> 0
    end
  end

  @spec validate_boolean(list(integer() | nil)) :: boolean()
  def validate_boolean(params) do
    case Enum.at(params, 0) do
      0 -> false
      1 -> true
      _ -> true
    end
  end

  @spec normalize_parameters(list(integer() | nil), non_neg_integer()) ::
          list(integer() | nil)
  def normalize_parameters(params, expected_length) do
    params
    |> Enum.take(expected_length)
    |> then(fn taken ->
      taken ++ List.duplicate(nil, expected_length - length(taken))
    end)
  end

  @spec validate_range(list(integer() | nil), integer(), integer()) :: integer()
  def validate_range(params, min, max) do
    value = Enum.at(params, 0)

    case is_integer(value) do
      true -> max(min, min(value, max))
      false -> min
    end
  end
end
