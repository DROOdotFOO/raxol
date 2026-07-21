defmodule Raxol.ACP.Console.Cron do
  @moduledoc """
  Minimal validator for 5-field cron expressions (`minute hour day-of-month
  month day-of-week`), the cadence format the delivered `tasks.json` must carry.

  Buyers may submit natural-language cadences ("every 12h"); the generator
  canonicalizes those to cron, and `Raxol.ACP.Console.Validator` requires the
  *final* package to validate here. Supported per field: `*`, integers, ranges
  `a-b`, steps `*/n` and `a-b/n`, and comma lists thereof. Month/day-of-week
  names are not accepted — the generator is instructed to emit numerics.
  """

  @bounds [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}]

  @doc "True when `expr` is a valid 5-field cron expression."
  @spec valid?(String.t()) :: boolean()
  def valid?(expr) when is_binary(expr) do
    case String.split(expr, ~r/\s+/, trim: true) do
      fields when length(fields) == 5 ->
        fields |> Enum.zip(@bounds) |> Enum.all?(fn {f, b} -> field_valid?(f, b) end)

      _ ->
        false
    end
  end

  def valid?(_), do: false

  defp field_valid?(field, bounds) do
    field |> String.split(",") |> Enum.all?(&part_valid?(&1, bounds))
  end

  defp part_valid?("*", _bounds), do: true

  defp part_valid?(part, bounds) do
    case String.split(part, "/") do
      [range] -> range_valid?(range, bounds)
      [range, step] -> range_valid?(range, bounds) and int_in?(step, {1, 59})
      _ -> false
    end
  end

  defp range_valid?("*", _bounds), do: true

  defp range_valid?(range, bounds) do
    case String.split(range, "-") do
      [n] ->
        int_in?(n, bounds)

      [a, b] ->
        with {:ok, a} <- parse_in(a, bounds), {:ok, b} <- parse_in(b, bounds) do
          a <= b
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp int_in?(s, bounds), do: match?({:ok, _}, parse_in(s, bounds))

  defp parse_in(s, {lo, hi}) do
    case Integer.parse(s) do
      {n, ""} when n >= lo and n <= hi -> {:ok, n}
      _ -> :error
    end
  end
end
