defmodule Raxol.Broker.PolicyFile do
  @moduledoc """
  Loads and validates the fail-closed broker policy file.

  Policy files are limited to 16 KiB and are parsed as data without executing
  their contents.
  """

  @filename "broker.policy.exs"
  @max_file_size 16 * 1024
  @keys [
    :max_notional_per_order,
    :daily_notional_cap,
    :max_position_weight,
    :order_types,
    :options,
    :after_hours_market,
    :llm_ask_above,
    :ask_timeout
  ]
  @required_caps [:max_notional_per_order, :daily_notional_cap]
  @allowed_order_types [:market, :limit]

  @type reason ::
          {:missing_file, Path.t()}
          | {:read_failed, Path.t(), File.posix()}
          | {:file_too_large, Path.t(), non_neg_integer(), pos_integer()}
          | {:parse_error, Path.t(), term()}
          | {:unsupported_expression, Macro.t()}
          | {:invalid_policy,
             :not_a_keyword_list | {:duplicate_key, atom()} | {:unknown_key, term()}}
          | {:missing_key, atom()}
          | {:unset, atom()}
          | {:invalid_value, atom(), term()}

  @spec filename() :: String.t()
  def filename, do: @filename

  @spec load(Path.t()) :: {:ok, keyword()} | {:error, reason()}
  def load(path \\ @filename) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        with :ok <- ensure_file_size(size, path) do
          read_and_load(path)
        end

      {:ok, %File.Stat{type: :directory}} ->
        {:error, {:read_failed, path, :eisdir}}

      {:ok, _stat} ->
        {:error, {:read_failed, path, :einval}}

      {:error, :enoent} ->
        {:error, {:missing_file, path}}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  @spec validate(term()) :: {:ok, keyword()} | {:error, reason()}
  def validate(policy) when is_list(policy) do
    with :ok <- validate_keyword(policy),
         :ok <- validate_keys(policy),
         :ok <- validate_required_caps(policy),
         :ok <- validate_decimal(policy, :max_position_weight, &valid_weight?/1),
         :ok <- validate_order_types(policy),
         :ok <- validate_boolean(policy, :options),
         :ok <- validate_boolean(policy, :after_hours_market),
         :ok <- validate_decimal(policy, :llm_ask_above, &positive?/1),
         :ok <- validate_timeout(policy) do
      {:ok, policy}
    end
  end

  def validate(_policy), do: {:error, {:invalid_policy, :not_a_keyword_list}}

  defp ensure_file_size(size, path) when size > @max_file_size,
    do: {:error, {:file_too_large, path, size, @max_file_size}}

  defp ensure_file_size(_size, _path), do: :ok

  defp read_and_load(path) do
    case File.open(path, [:read, :binary], fn device ->
           IO.binread(device, @max_file_size + 1)
         end) do
      {:ok, contents} when is_binary(contents) ->
        with :ok <- ensure_file_size(byte_size(contents), path) do
          parse_and_validate(contents, path)
        end

      {:ok, :eof} ->
        parse_and_validate("", path)

      {:ok, {:error, reason}} ->
        {:error, {:read_failed, path, reason}}

      {:error, :enoent} ->
        {:error, {:missing_file, path}}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  defp parse_and_validate(contents, path) do
    case Code.string_to_quoted(contents, file: path, existing_atoms_only: true) do
      {:ok, quoted} ->
        with {:ok, policy} <- decode_expression(quoted) do
          validate(policy)
        end

      {:error, reason} ->
        {:error, {:parse_error, path, reason}}
    end
  end

  defp decode_expression(
         {{:., _dot_metadata, [{:__aliases__, _alias_metadata, [:Decimal]}, :new]},
          _call_metadata, [value]} = expression
       )
       when is_binary(value) do
    try do
      {:ok, Decimal.new(value)}
    rescue
      _error in Decimal.Error -> {:error, {:unsupported_expression, expression}}
    end
  end

  defp decode_expression(value) when is_atom(value) or is_integer(value) or is_binary(value),
    do: {:ok, value}

  defp decode_expression(values) when is_list(values), do: decode_list(values, [])

  defp decode_expression({key, value}) when is_atom(key) do
    with {:ok, decoded} <- decode_expression(value) do
      {:ok, {key, decoded}}
    end
  end

  defp decode_expression(expression), do: {:error, {:unsupported_expression, expression}}

  defp decode_list([], decoded), do: {:ok, Enum.reverse(decoded)}

  defp decode_list([value | rest], decoded) do
    with {:ok, value} <- decode_expression(value) do
      decode_list(rest, [value | decoded])
    end
  end

  defp validate_keyword(policy) do
    if Keyword.keyword?(policy),
      do: :ok,
      else: {:error, {:invalid_policy, :not_a_keyword_list}}
  end

  defp validate_keys(policy) do
    keys = Keyword.keys(policy)

    case keys -- Enum.uniq(keys) do
      [duplicate | _] ->
        {:error, {:invalid_policy, {:duplicate_key, duplicate}}}

      [] ->
        case Enum.find(keys, &(&1 not in @keys)) do
          nil -> validate_present_keys(keys)
          unknown -> {:error, {:invalid_policy, {:unknown_key, unknown}}}
        end
    end
  end

  defp validate_present_keys(keys) do
    case Enum.find(@keys, &(&1 not in keys)) do
      nil -> :ok
      missing -> {:error, {:missing_key, missing}}
    end
  end

  defp validate_required_caps(policy) do
    Enum.reduce_while(@required_caps, :ok, fn key, :ok ->
      case Keyword.fetch!(policy, key) do
        :unset -> {:halt, {:error, {:unset, key}}}
        value -> continue_if_valid_decimal(value, key, &positive?/1)
      end
    end)
  end

  defp validate_decimal(policy, key, predicate) do
    case Keyword.fetch!(policy, key) do
      :unset -> :ok
      value -> unwrap_continue(continue_if_valid_decimal(value, key, predicate))
    end
  end

  defp continue_if_valid_decimal(%Decimal{coef: coefficient} = value, key, predicate)
       when is_integer(coefficient) do
    if predicate.(value),
      do: {:cont, :ok},
      else: {:halt, {:error, {:invalid_value, key, value}}}
  end

  defp continue_if_valid_decimal(value, key, _predicate),
    do: {:halt, {:error, {:invalid_value, key, value}}}

  defp unwrap_continue({:cont, :ok}), do: :ok
  defp unwrap_continue({:halt, error}), do: error

  defp positive?(value), do: Decimal.compare(value, Decimal.new(0)) == :gt

  defp valid_weight?(value) do
    positive?(value) and Decimal.compare(value, Decimal.new(1)) in [:lt, :eq]
  end

  defp validate_order_types(policy) do
    value = Keyword.fetch!(policy, :order_types)

    if is_list(value) and value != [] and
         Enum.all?(value, &(&1 in @allowed_order_types)) and
         length(value) == length(Enum.uniq(value)) do
      :ok
    else
      {:error, {:invalid_value, :order_types, value}}
    end
  end

  defp validate_boolean(policy, key) do
    value = Keyword.fetch!(policy, key)

    if is_boolean(value),
      do: :ok,
      else: {:error, {:invalid_value, key, value}}
  end

  defp validate_timeout(policy) do
    value = Keyword.fetch!(policy, :ask_timeout)

    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, {:invalid_value, :ask_timeout, value}}
  end
end
