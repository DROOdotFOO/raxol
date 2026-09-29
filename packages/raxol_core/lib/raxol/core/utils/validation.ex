defmodule Raxol.Core.Utils.Validation do
  @moduledoc """
  Common validation utilities to reduce code duplication across the codebase.
  Provides standardized validation functions for dimensions, configs, and common patterns.
  """

  alias Raxol.Core.Defaults

  @doc """
  Validates that a dimension is a positive integer, returning default if invalid.

  It sets no upper bound; a terminal width or height goes through
  `clamp_terminal_size/2` or `validate_terminal_size/2` as well.
  """
  @spec validate_dimension(integer(), non_neg_integer()) :: non_neg_integer()
  def validate_dimension(dimension, _default)
      when is_integer(dimension) and dimension > 0 do
    dimension
  end

  def validate_dimension(_, default), do: default

  @typedoc "A terminal size ceiling: largest width, height and width * height."
  @type terminal_size_ceiling :: %{
          width: pos_integer(),
          height: pos_integer(),
          cells: pos_integer()
        }

  @doc """
  Clamps a terminal size to a ceiling, by default the local one,
  `Raxol.Core.Defaults.terminal_size_ceiling/0`. Network surfaces pass
  `Raxol.Core.Defaults.remote_terminal_size_ceiling/0` (or their own).

  The width is capped at the ceiling's `:width`, then the height at its
  `:height` and at as many rows as its `:cells` allows at that width, so
  `width * height` never exceeds the cell ceiling. Only the upper bound is
  applied: a size already within the ceiling, and a non-positive or
  non-integer value, comes back unchanged.

      iex> Raxol.Core.Utils.Validation.clamp_terminal_size(120, 40)
      {120, 40}

      iex> Raxol.Core.Utils.Validation.clamp_terminal_size(100_000, 100_000)
      {4096, 256}

      iex> Raxol.Core.Utils.Validation.clamp_terminal_size(
      ...>   100_000,
      ...>   100_000,
      ...>   Raxol.Core.Defaults.remote_terminal_size_ceiling()
      ...> )
      {512, 256}
  """
  @spec clamp_terminal_size(term(), term(), terminal_size_ceiling()) ::
          {term(), term()}
  def clamp_terminal_size(
        width,
        height,
        %{width: max_w, height: max_h, cells: max_cells} \\ Defaults.terminal_size_ceiling()
      ) do
    width = clamp_upper(width, max_w)
    rows_allowed = min(max_h, div(max_cells, positive_or_one(width)))
    {width, clamp_upper(height, rows_allowed)}
  end

  @doc """
  Checks a terminal size against the ceiling `clamp_terminal_size/3` applies,
  by default the local one.

  Returns `{:error, :invalid_dimensions}` unless both are positive integers,
  and `{:error, :dimensions_too_large}` when either axis, or
  `width * height`, is past the ceiling.
  """
  @spec validate_terminal_size(term(), term(), terminal_size_ceiling()) ::
          :ok | {:error, :invalid_dimensions | :dimensions_too_large}
  def validate_terminal_size(width, height, ceiling \\ Defaults.terminal_size_ceiling())

  def validate_terminal_size(width, height, ceiling)
      when is_integer(width) and width > 0 and is_integer(height) and
             height > 0 do
    if clamp_terminal_size(width, height, ceiling) == {width, height},
      do: :ok,
      else: {:error, :dimensions_too_large}
  end

  def validate_terminal_size(_width, _height, _ceiling),
    do: {:error, :invalid_dimensions}

  @doc """
  Validates that coordinates are valid non-negative integers.
  """
  @spec validate_coordinates(integer(), integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}}
          | {:error, :invalid_coordinates}
  def validate_coordinates(x, y)
      when is_integer(x) and x >= 0 and is_integer(y) and y >= 0 do
    {:ok, {x, y}}
  end

  def validate_coordinates(_, _), do: {:error, :invalid_coordinates}

  @doc """
  Validates a configuration map against required keys.
  """
  @spec validate_config(map(), list(atom())) ::
          {:ok, map()} | {:error, {:missing_keys, list(atom())}}
  def validate_config(config, required_keys) when is_map(config) do
    missing_keys = Enum.reject(required_keys, &Map.has_key?(config, &1))

    case missing_keys do
      [] -> {:ok, config}
      keys -> {:error, {:missing_keys, keys}}
    end
  end

  def validate_config(_, _), do: {:error, :invalid_config}

  @doc """
  Validates that a value is within specified bounds.
  """
  @spec validate_bounds(number(), number(), number()) ::
          {:ok, number()} | {:error, :out_of_bounds}
  def validate_bounds(value, min, max)
      when is_number(value) and value >= min and value <= max do
    {:ok, value}
  end

  def validate_bounds(_, _, _), do: {:error, :out_of_bounds}

  @doc """
  Validates that a list contains only specific types.
  """
  @spec validate_list_types(list(), atom()) ::
          {:ok, list()} | {:error, :invalid_types}
  def validate_list_types(list, type) when is_list(list) do
    valid =
      Enum.all?(list, fn item ->
        case type do
          :atom -> is_atom(item)
          :string -> is_binary(item)
          :integer -> is_integer(item)
          :number -> is_number(item)
          :map -> is_map(item)
          _ -> false
        end
      end)

    case valid do
      true -> {:ok, list}
      false -> {:error, :invalid_types}
    end
  end

  def validate_list_types(_, _), do: {:error, :invalid_types}

  @doc """
  Validates that a string is not empty and optionally matches a pattern.
  """
  @spec validate_string(binary(), Regex.t() | nil) ::
          {:ok, binary()} | {:error, :invalid_string}
  def validate_string(str, pattern \\ nil)

  def validate_string(str, nil) when is_binary(str) and byte_size(str) > 0 do
    {:ok, str}
  end

  def validate_string(str, pattern)
      when is_binary(str) and byte_size(str) > 0 do
    case Regex.match?(pattern, str) do
      true -> {:ok, str}
      false -> {:error, :invalid_string}
    end
  end

  def validate_string(_, _), do: {:error, :invalid_string}

  @doc """
  Validates that a value is one of the allowed options.
  """
  @spec validate_enum(any(), list()) :: {:ok, any()} | {:error, :invalid_option}
  def validate_enum(value, allowed) when is_list(allowed) do
    case value in allowed do
      true -> {:ok, value}
      false -> {:error, :invalid_option}
    end
  end

  def validate_enum(_, _), do: {:error, :invalid_option}

  defp clamp_upper(value, ceiling) when is_integer(value),
    do: min(value, ceiling)

  defp clamp_upper(value, _ceiling), do: value

  defp positive_or_one(value) when is_integer(value) and value > 0, do: value
  defp positive_or_one(_value), do: 1
end
