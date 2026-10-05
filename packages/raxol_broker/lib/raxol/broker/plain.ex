defmodule Raxol.Broker.Plain do
  @moduledoc """
  The data boundary for anything a caller hands the broker.

  Plain data is: binaries, atoms (booleans and `nil` included), integers,
  proper lists and tuples of plain data, maps that are not structs whose keys
  and values are plain, `%Decimal{}` with an integer sign of 1 or -1, a
  non-negative integer coefficient of at most 40 digits and an integer
  exponent in -40..40, and `%DateTime{}`
  in the ISO calendar with well-typed fields. Floats, pids, references, ports,
  functions, improper lists, any other struct, and nesting deeper than 32
  levels are refused.

  Validation uses pattern matching and BIFs only. No protocol (`Enumerable`,
  `Inspect`, `String.Chars`, `Jason.Encoder`) is ever dispatched on the input,
  so a caller-supplied struct cannot run its code in the process that checks
  it. `normalize/1` returns a freshly built copy: decimals and datetimes are
  rebuilt field by field, so extra or forged fields never survive.
  """

  @max_depth 32

  # Decimal bounds: a coefficient of at most 40 digits and an exponent in
  # -40..40. `Decimal.to_string/1` raises on very large values, so an unbounded
  # decimal could crash the journal while it encodes a record.
  @max_coef 10_000_000_000_000_000_000_000_000_000_000_000_000_000 - 1
  @max_exp 40

  @type path :: [term()]
  @type error :: {:error, {:not_plain, path()}}

  @doc "Maximum nesting depth accepted."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "`:ok` when `term` is plain data, otherwise the path to the first offending value."
  @spec check(term()) :: :ok | error()
  def check(term) do
    case normalize(term) do
      {:ok, _term} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "A rebuilt copy of `term` when it is plain data."
  @spec normalize(term()) :: {:ok, term()} | error()
  def normalize(term), do: walk(term, [], 0)

  defp walk(_term, path, depth) when depth > @max_depth, do: refuse(path)

  defp walk(term, _path, _depth)
       when is_binary(term) or is_atom(term) or is_integer(term),
       do: {:ok, term}

  defp walk(%{__struct__: Decimal, sign: sign, coef: coef, exp: exp}, _path, _depth)
       when sign in [1, -1] and is_integer(coef) and coef >= 0 and coef <= @max_coef and
              is_integer(exp) and exp >= -@max_exp and exp <= @max_exp,
       do: {:ok, %Decimal{sign: sign, coef: coef, exp: exp}}

  defp walk(%{__struct__: DateTime} = term, path, _depth), do: datetime(term, path)

  defp walk(term, path, depth) when is_map(term) and not is_map_key(term, :__struct__),
    do: map(:maps.to_list(term), path, depth + 1, [])

  defp walk(term, path, depth) when is_list(term), do: list(term, path, depth + 1, 0, [])

  defp walk(term, path, depth) when is_tuple(term) do
    case list(:erlang.tuple_to_list(term), path, depth + 1, 0, []) do
      {:ok, items} -> {:ok, :erlang.list_to_tuple(items)}
      error -> error
    end
  end

  defp walk(_term, path, _depth), do: refuse(path)

  defp map([], _path, _depth, acc), do: {:ok, :maps.from_list(acc)}

  defp map([{key, value} | rest], path, depth, acc) do
    with {:ok, key} <- walk(key, [:key | path], depth),
         {:ok, value} <- walk(value, [key | path], depth) do
      map(rest, path, depth, [{key, value} | acc])
    end
  end

  defp list([], _path, _depth, _index, acc), do: {:ok, :lists.reverse(acc)}

  defp list([head | tail], path, depth, index, acc) do
    case walk(head, [index | path], depth) do
      {:ok, head} -> list(tail, path, depth, index + 1, [head | acc])
      error -> error
    end
  end

  defp list(_improper_tail, path, _depth, index, _acc), do: refuse([index | path])

  @datetime_integers [:year, :month, :day, :hour, :minute, :second, :utc_offset, :std_offset]

  defp datetime(
         %{
           calendar: Calendar.ISO,
           microsecond: {micro, precision},
           time_zone: time_zone,
           zone_abbr: zone_abbr
         } = term,
         path
       )
       when is_integer(micro) and is_integer(precision) and is_binary(time_zone) and
              is_binary(zone_abbr) do
    integers = for key <- @datetime_integers, do: {key, :maps.get(key, term, nil)}

    if :lists.all(fn {_key, value} -> is_integer(value) end, integers) do
      fields = [
        calendar: Calendar.ISO,
        microsecond: {micro, precision},
        time_zone: time_zone,
        zone_abbr: zone_abbr
      ]

      {:ok, struct!(DateTime, fields ++ integers)}
    else
      refuse(path)
    end
  end

  defp datetime(_term, path), do: refuse(path)

  defp refuse(path), do: {:error, {:not_plain, :lists.reverse(path)}}
end
