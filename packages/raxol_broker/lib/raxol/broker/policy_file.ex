defmodule Raxol.Broker.PolicyFile do
  @moduledoc """
  Loads and validates the fail-closed broker policy file.

  Policy files are limited to 16 KiB and are parsed as data without executing
  their contents.
  """

  @filename "broker.policy.exs"
  @max_file_size 16 * 1024
  @schema [
    max_notional_per_order: {:positive_decimal, :required},
    daily_notional_cap: {:positive_decimal, :required},
    max_position_weight: {:weight_or_unset, {:default, :unset}},
    order_types: {{:unique_nonempty_list, [:market, :limit]}, {:default, [:limit]}},
    options: {:boolean, {:default, false}},
    after_hours_market: {:boolean, {:default, false}},
    llm_ask_above: {:positive_decimal_or_unset, {:default, :unset}},
    ask_timeout: {{:integer_range, 1, 4_294_967_295}, {:default, 30_000}}
  ]
  @keys Keyword.keys(@schema)
  @zero Decimal.new(0)
  @one Decimal.new(1)

  @type reason ::
          {:missing_file, Path.t()}
          | {:read_failed, Path.t(), File.posix()}
          | {:untrusted_file, Path.t(), Raxol.Agent.OperatorFile.refusal() | :enoent}
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
        with :ok <- ensure_file_size(size, path),
             :ok <- ensure_trusted(path) do
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

  @doc """
  Builds a complete fail-closed policy from the two required notional caps.
  """
  @spec new(term(), term()) :: {:ok, keyword()} | {:error, reason()}
  def new(max_notional_per_order, daily_notional_cap) do
    required_values = [
      max_notional_per_order: max_notional_per_order,
      daily_notional_cap: daily_notional_cap
    ]

    policy =
      Enum.map(@schema, fn
        {key, {_validator, :required}} ->
          {key, Keyword.fetch!(required_values, key)}

        {key, {_validator, {:default, default}}} ->
          {key, default}
      end)

    validate(policy)
  end

  @spec validate(term()) :: {:ok, keyword()} | {:error, reason()}
  def validate(policy) when is_list(policy) do
    with :ok <- validate_keyword(policy),
         :ok <- validate_keys(policy),
         :ok <- validate_schema(policy) do
      {:ok, policy}
    end
  end

  def validate(_policy), do: {:error, {:invalid_policy, :not_a_keyword_list}}

  defp ensure_file_size(size, path) when size > @max_file_size,
    do: {:error, {:file_too_large, path, size, @max_file_size}}

  defp ensure_file_size(_size, _path), do: :ok

  defp ensure_trusted(path) do
    case Raxol.Agent.OperatorFile.trusted?(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:untrusted_file, path, reason}}
    end
  end

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
    case String.valid?(contents) do
      true -> parse_quoted(contents, path)
      false -> {:error, {:parse_error, path, :invalid_utf8}}
    end
  end

  defp parse_quoted(contents, path) do
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

  defp validate_schema(policy) do
    Enum.reduce_while(@schema, :ok, fn {key, {validator, marker}}, :ok ->
      value = Keyword.fetch!(policy, key)

      case validate_schema_value(key, value, validator, marker) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_schema_value(key, :unset, _validator, :required),
    do: {:error, {:unset, key}}

  defp validate_schema_value(key, value, validator, _marker) do
    if valid_value?(validator, value),
      do: :ok,
      else: {:error, {:invalid_value, key, value}}
  end

  defp valid_value?(:positive_decimal, %Decimal{coef: coefficient} = value)
       when is_integer(coefficient),
       do: Decimal.compare(value, @zero) == :gt

  defp valid_value?(:positive_decimal_or_unset, :unset), do: true

  defp valid_value?(:positive_decimal_or_unset, value),
    do: valid_value?(:positive_decimal, value)

  defp valid_value?(:weight_or_unset, :unset), do: true

  defp valid_value?(:weight_or_unset, %Decimal{coef: coefficient} = value)
       when is_integer(coefficient),
       do:
         Decimal.compare(value, @zero) == :gt and
           Decimal.compare(value, @one) in [:lt, :eq]

  defp valid_value?({:unique_nonempty_list, allowed}, value) when is_list(value),
    do:
      value != [] and
        Enum.all?(value, &(&1 in allowed)) and
        length(value) == length(Enum.uniq(value))

  defp valid_value?(:boolean, value), do: is_boolean(value)

  defp valid_value?({:integer_range, minimum, maximum}, value),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp valid_value?(_validator, _value), do: false
end
