defmodule Raxol.Agent.Schedule do
  @moduledoc """
  Parses a schedule string into a next-fire function, once, at creation time.

  Four formats, one parser (`parse/1`):

    * **relative** -- `"30m"`, `"2h"`, `"45s"`, `"1d"`. Fires once, `now + duration`
      after creation. One-shot (`recurring?: false`).
    * **interval** -- `"every 2h"`, `"every 30m"`. Fires every duration, forever.
      Recurring.
    * **cron** -- a 5-field crontab (`"0 9 * * 1-5"`): `minute hour
      day-of-month month day-of-week`. Recurring. Fields accept `*`, single
      values, ranges (`a-b`), steps (`*/n`, `a-b/n`), and lists (`a,b,c`).
      Day-of-week is `0` or `7` for Sunday through `6` for Saturday, and follows
      Vixie cron's rule: when both day-of-month and day-of-week are restricted, a
      day matches when *either* does.
    * **timestamp** -- an ISO 8601 instant (`"2026-08-01T09:00:00Z"`). Fires once,
      at that instant. One-shot.

  The parser is deterministic and never touches a clock or an LLM: a
  natural-language schedule is expected to be lowered to one of these formats by
  the agent at job-creation time, not here. `next_fire/2` takes the reference
  time explicitly, so scheduling is a pure function of `(schedule, from)`.

  A 5-field cron over a set of impossible constraints (e.g. `"0 0 30 2 *"`,
  February 30th) has no next fire; `next_fire/2` returns `:never` after an
  8-year search horizon rather than looping forever.
  """

  @enforce_keys [:kind, :source, :recurring?, :parsed]
  defstruct [:kind, :source, :recurring?, :parsed]

  @type kind :: :relative | :interval | :cron | :timestamp

  @type t :: %__MODULE__{
          kind: kind(),
          source: String.t(),
          recurring?: boolean(),
          parsed: term()
        }

  # Field bounds for the 5 cron positions, in order.
  @cron_fields [
    {:minute, 0, 59},
    {:hour, 0, 23},
    {:day, 1, 31},
    {:month, 1, 12},
    # Day-of-week accepts 0-7; both 0 and 7 mean Sunday and are normalized to 0.
    {:dow, 0, 7}
  ]

  # Cap the cron next-fire search so an impossible schedule terminates. Twelve
  # years clears the widest real gap: a century year that is not a leap year
  # (e.g. 2100) stretches the span between two Feb-29 fires to 8 years, so a
  # 12-year horizon keeps comfortable margin above it.
  @cron_horizon_days 12 * 366

  @duration_units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  @doc """
  Parse a schedule string into a `%Schedule{}`, or `{:error, reason}`.

  The format is inferred from the string shape: an `"every "` prefix is an
  interval, a bare `<n><unit>` is relative, five whitespace-separated fields is
  cron, and a single token that is neither is tried as an ISO 8601 timestamp.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" -> {:error, :empty_schedule}
      String.starts_with?(trimmed, "every ") -> parse_interval(trimmed)
      true -> parse_single_or_cron(trimmed)
    end
  end

  def parse(_source), do: {:error, :invalid_schedule}

  @doc """
  The next fire time strictly after `from`, or `:never` when the schedule can
  never fire again (a one-shot already in the past, or an impossible cron).
  """
  @spec next_fire(t(), DateTime.t()) :: {:ok, DateTime.t()} | :never
  def next_fire(%__MODULE__{kind: kind, parsed: parsed}, %DateTime{} = from) do
    case kind do
      :relative -> {:ok, DateTime.add(from, parsed, :second)}
      :interval -> {:ok, DateTime.add(from, parsed, :second)}
      :timestamp -> timestamp_next(parsed, from)
      :cron -> cron_next(parsed, from)
    end
  end

  # -- interval / relative ----------------------------------------------------

  defp parse_interval("every " <> rest) do
    case parse_duration(String.trim(rest)) do
      {:ok, seconds} ->
        {:ok,
         %__MODULE__{kind: :interval, source: "every " <> rest, recurring?: true, parsed: seconds}}

      :error ->
        {:error, {:bad_interval, rest}}
    end
  end

  defp parse_single_or_cron(trimmed) do
    case String.split(trimmed, ~r/\s+/, trim: true) do
      [single] -> parse_single(single)
      fields when length(fields) == 5 -> parse_cron(fields, trimmed)
      _other -> {:error, {:unrecognized_schedule, trimmed}}
    end
  end

  defp parse_single(token) do
    case parse_duration(token) do
      {:ok, seconds} ->
        {:ok, %__MODULE__{kind: :relative, source: token, recurring?: false, parsed: seconds}}

      :error ->
        parse_timestamp(token)
    end
  end

  # A duration is <positive-int><s|m|h|d>, e.g. "30m", "2h".
  defp parse_duration(token) do
    case Regex.run(~r/^(\d+)([smhd])$/, token) do
      [_all, value, unit] ->
        int = String.to_integer(value)
        if int > 0, do: {:ok, int * @duration_units[unit]}, else: :error

      _no_match ->
        :error
    end
  end

  # -- timestamp --------------------------------------------------------------

  defp parse_timestamp(token) do
    case DateTime.from_iso8601(token) do
      {:ok, dt, _offset} ->
        {:ok, %__MODULE__{kind: :timestamp, source: token, recurring?: false, parsed: dt}}

      {:error, _reason} ->
        {:error, {:unrecognized_schedule, token}}
    end
  end

  defp timestamp_next(dt, from) do
    if DateTime.compare(dt, from) == :gt, do: {:ok, dt}, else: :never
  end

  # -- cron -------------------------------------------------------------------

  defp parse_cron(fields, source) do
    case reduce_cron_fields(fields) do
      {:error, _reason} = error ->
        error

      map when is_map(map) ->
        {:ok, %__MODULE__{kind: :cron, source: source, recurring?: true, parsed: map}}
    end
  end

  defp reduce_cron_fields(fields) do
    fields
    |> Enum.zip(@cron_fields)
    |> Enum.reduce_while(%{}, &reduce_cron_field/2)
  end

  defp reduce_cron_field({field, {name, min, max}}, acc) do
    case parse_cron_field(field, min, max) do
      {:ok, set} -> {:cont, Map.put(acc, name, normalize_field(name, set))}
      :error -> {:halt, {:error, {:bad_cron_field, name, field}}}
    end
  end

  # Day-of-week 7 is an alias for Sunday (0); fold it in so `* * * * 7` and
  # `* * * * 0` are identical and a full field is exactly 7 distinct days.
  defp normalize_field(:dow, set) do
    if MapSet.member?(set, 7),
      do: set |> MapSet.delete(7) |> MapSet.put(0),
      else: set
  end

  defp normalize_field(_name, set), do: set

  # A field is a comma-separated list of items over `min..max`; `*` means the
  # whole range. Returns a MapSet of the allowed integers, or :error.
  defp parse_cron_field(field, min, max) do
    field
    |> String.split(",", trim: true)
    |> Enum.reduce_while(MapSet.new(), fn item, acc ->
      case parse_cron_item(item, min, max) do
        {:ok, set} -> {:cont, MapSet.union(acc, set)}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      set -> if MapSet.size(set) == 0, do: :error, else: {:ok, set}
    end
  end

  defp parse_cron_item(item, min, max) do
    case String.split(item, "/", parts: 2) do
      [range] ->
        parse_cron_range(range, min, max, 1)

      [range, step] ->
        with {:ok, s} <- positive_int(step), do: parse_cron_range(range, min, max, s)
    end
  end

  defp parse_cron_range("*", min, max, step), do: stepped(min, max, step)

  defp parse_cron_range(range, min, max, step) do
    case String.split(range, "-", parts: 2) do
      [single] -> parse_cron_point(single, min, max, step)
      [lo, hi] -> parse_cron_bounds(lo, hi, min, max, step)
    end
  end

  # A bare number with a step (`5/2`) means "from 5 to max, step"; without a
  # step it is just that one value.
  defp parse_cron_point(single, min, max, step) do
    with {:ok, n} <- bounded_int(single, min, max) do
      if step == 1, do: {:ok, MapSet.new([n])}, else: stepped(n, max, step)
    end
  end

  defp parse_cron_bounds(lo, hi, min, max, step) do
    with {:ok, low} <- bounded_int(lo, min, max),
         {:ok, high} <- bounded_int(hi, min, max),
         true <- low <= high do
      stepped(low, high, step)
    else
      _ -> :error
    end
  end

  defp stepped(lo, hi, step) do
    {:ok, lo |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 <= hi)) |> MapSet.new()}
  end

  defp bounded_int(str, min, max) do
    case Integer.parse(str) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _other -> :error
    end
  end

  defp positive_int(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> :error
    end
  end

  # Walk forward to the first matching minute strictly after `from`. To keep an
  # impossible date (e.g. February 30th) cheap, whole non-matching days are
  # skipped to the next midnight rather than stepped minute by minute; the
  # horizon is counted in days so the search always terminates.
  defp cron_next(cron, from) do
    start =
      from
      |> DateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 0})
      |> DateTime.add(60, :second)

    search_cron(cron, start, @cron_horizon_days)
  end

  defp search_cron(_cron, _dt, 0), do: :never

  defp search_cron(cron, dt, days_left) do
    cond do
      not date_match?(cron, dt) ->
        search_cron(cron, next_midnight(dt), days_left - 1)

      cron_match?(cron, dt) ->
        {:ok, dt}

      true ->
        # The day matches but this minute does not; step within the day, and
        # only spend a day of the horizon when the step crosses midnight.
        next = DateTime.add(dt, 60, :second)

        if DateTime.to_date(next) == DateTime.to_date(dt),
          do: search_cron(cron, next, days_left),
          else: search_cron(cron, next, days_left - 1)
    end
  end

  defp next_midnight(dt) do
    dt |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00])
  end

  defp cron_match?(cron, dt) do
    MapSet.member?(cron.minute, dt.minute) and
      MapSet.member?(cron.hour, dt.hour) and
      date_match?(cron, dt)
  end

  # The date (month + day) matches, independent of the time of day.
  defp date_match?(cron, dt) do
    MapSet.member?(cron.month, dt.month) and day_match?(cron, dt)
  end

  # Vixie cron: when both day-of-month and day-of-week are restricted, a day
  # matches if either does; otherwise only the restricted field (if any) gates.
  defp day_match?(cron, dt) do
    dom_restricted = MapSet.size(cron.day) < 31
    dow_restricted = MapSet.size(cron.dow) < 7

    dom_ok = MapSet.member?(cron.day, dt.day)
    dow_ok = MapSet.member?(cron.dow, cron_dow(dt))

    cond do
      dom_restricted and dow_restricted -> dom_ok or dow_ok
      dom_restricted -> dom_ok
      dow_restricted -> dow_ok
      true -> true
    end
  end

  # Date.day_of_week is 1 (Monday)..7 (Sunday); cron is 0 (Sunday)..6 (Saturday).
  defp cron_dow(dt) do
    dt |> DateTime.to_date() |> Date.day_of_week() |> rem(7)
  end
end
