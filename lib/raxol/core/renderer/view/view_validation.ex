defmodule Raxol.Core.Renderer.View.Validation do
  @moduledoc """
  Validation functions for the View module.
  Extracted from the main View module to improve maintainability.
  """

  @doc """
  Validates view type and raises an error if invalid.
  """
  def validate_view_type(type) do
    valid_types = [
      :text,
      :box,
      :flex,
      :grid,
      :border,
      :scroll,
      :label,
      :button,
      :checkbox,
      :panel
    ]

    validate_type_membership(type in valid_types, type)
  end

  @spec validate_type_membership(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_type_membership(true, _type), do: :ok

  @spec validate_type_membership(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_type_membership(false, type) do
    raise ArgumentError, "Invalid view type: #{inspect(type)}"
  end

  @doc """
  Validates view options and raises an error if invalid.
  """
  def validate_view_options(opts) do
    validate_size_option(opts)
    validate_position_option(opts)
    validate_container_dimensions(opts)
  end

  @doc """
  Validates layout dimensions and raises an error if invalid.
  """
  def validate_layout_dimensions(dimensions) do

    validate_keyword_list(Keyword.keyword?(dimensions), dimensions)

    width = Keyword.get(dimensions, :width)
    height = Keyword.get(dimensions, :height)

    validate_width_dimension(width)
    validate_height_dimension(height)
  end

  @spec validate_keyword_list(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_keyword_list(true, _dimensions), do: :ok

  @spec validate_keyword_list(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_keyword_list(false, dimensions) do
    raise ArgumentError,
          "View.layout macro expects a keyword list as the second argument, got: #{inspect(dimensions)}"
  end

  @spec validate_width_dimension(String.t() | integer()) ::
          {:ok, any()} | {:error, any()}
  defp validate_width_dimension(width) when is_integer(width) and width <= 0 do
    raise ArgumentError, "Container width must be a positive integer"
  end

  @spec validate_width_dimension(String.t() | integer()) ::
          {:ok, any()} | {:error, any()}
  defp validate_width_dimension(_width), do: :ok

  @spec validate_height_dimension(pos_integer()) ::
          {:ok, any()} | {:error, any()}
  defp validate_height_dimension(height)
       when is_integer(height) and height <= 0 do
    raise ArgumentError, "Container height must be a positive integer"
  end

  @spec validate_height_dimension(any()) :: {:ok, any()} | {:error, any()}
  defp validate_height_dimension(_height), do: :ok

  # Private validation functions

  @spec validate_size_option(keyword()) :: :ok
  defp validate_size_option(opts) do
    handle_size_validation(Keyword.has_key?(opts, :size), opts)
  end

  @spec handle_size_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_size_validation(false, _opts), do: :ok

  @spec handle_size_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_size_validation(true, opts) do
    size = Keyword.get(opts, :size)
    validate_size_value(valid_size?(size), size)
  end

  @spec validate_size_value(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_size_value(true, _size), do: :ok

  @spec validate_size_value(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_size_value(false, _size) do
    raise ArgumentError, "Size must be a tuple of two positive integers"
  end

  @spec validate_position_option(keyword()) :: :ok
  defp validate_position_option(opts) do
    handle_position_validation(Keyword.has_key?(opts, :position), opts)
  end

  @spec handle_position_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_position_validation(false, _opts), do: :ok

  @spec handle_position_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_position_validation(true, opts) do
    position = Keyword.get(opts, :position)
    validate_position_value(valid_position?(position), position)
  end

  @spec validate_position_value(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_position_value(true, _position), do: :ok

  @spec validate_position_value(any(), any()) :: {:ok, any()} | {:error, any()}
  defp validate_position_value(false, _position) do
    raise ArgumentError, "Position must be a tuple of two integers"
  end

  @spec validate_container_dimensions(keyword()) :: :ok
  defp validate_container_dimensions(opts) do
    has_dimensions =
      Keyword.has_key?(opts, :width) or Keyword.has_key?(opts, :height)

    handle_container_dimension_validation(has_dimensions, opts)
  end

  @spec handle_container_dimension_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_container_dimension_validation(false, _opts), do: :ok

  @spec handle_container_dimension_validation(any(), keyword()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_container_dimension_validation(true, opts) do
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)

    invalid_dimensions =
      (is_integer(width) and width <= 0) or (is_integer(height) and height <= 0)

    validate_container_dimension_values(invalid_dimensions)
  end

  @spec validate_container_dimension_values(any()) ::
          {:ok, any()} | {:error, any()}
  defp validate_container_dimension_values(false), do: :ok

  @spec validate_container_dimension_values(any()) ::
          {:ok, any()} | {:error, any()}
  defp validate_container_dimension_values(true) do
    raise ArgumentError, "Container dimensions must be positive integers"
  end

  @spec valid_size?(any()) :: boolean()
  defp valid_size?({width, height})
       when is_integer(width) and is_integer(height) do
    width > 0 and height > 0
  end

  @spec valid_size?(any()) :: boolean()
  defp valid_size?(_), do: false

  @spec valid_position?(any()) :: boolean()
  defp valid_position?({x, y}) when is_integer(x) and is_integer(y), do: true
  @spec valid_position?(any()) :: boolean()
  defp valid_position?(_), do: false

  # --- keyword opts and spacing helpers (used by View and macros) ---

  @doc """
  Validates that opts is a keyword list; raises ArgumentError otherwise.
  Public so it can be called from `View` macros via full module name.
  """
  def validate_keyword_opts(opts, _function_name) when is_list(opts) do
    case opts do
      [] -> :ok
      [tuple | _] when is_tuple(tuple) -> :ok
      _ -> raise ArgumentError, "Expected keyword list"
    end
  end

  def validate_keyword_opts(opts, function_name) do
    raise ArgumentError,
          "#{function_name} expects a keyword list as the first argument, got: #{inspect(opts)}"
  end

  @doc "Ensures opts is a keyword list; returns [] for non-lists."
  def ensure_keyword_list(opts) when is_list(opts), do: opts
  def ensure_keyword_list(_), do: []

  @doc "Normalises padding/margin on a view map."
  def normalize_spacing(view) do
    alias Raxol.Core.Renderer.View.Utils.ViewUtils
    padding = Map.get(view, :padding, {0, 0, 0, 0})
    margin = Map.get(view, :margin, {0, 0, 0, 0})

    view
    |> Map.put(:padding, ViewUtils.normalize_spacing(padding))
    |> Map.put(:margin, ViewUtils.normalize_margin(margin))
  end
end
