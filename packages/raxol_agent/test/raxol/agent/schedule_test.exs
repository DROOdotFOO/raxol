defmodule Raxol.Agent.ScheduleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Agent.Schedule

  @factors %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  describe "parse/1 relative durations" do
    test "parses <n><unit> as a one-shot relative schedule" do
      assert {:ok, schedule} = Schedule.parse("30m")
      assert schedule.kind == :relative
      refute schedule.recurring?
    end

    test "next fire is the reference time plus the duration" do
      {:ok, schedule} = Schedule.parse("2h")
      from = ~U[2026-07-27 08:00:00Z]

      assert {:ok, ~U[2026-07-27 10:00:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "rejects a zero or non-positive duration" do
      assert {:error, _} = Schedule.parse("0m")
    end
  end

  describe "parse/1 intervals" do
    test "parses \"every <duration>\" as a recurring schedule" do
      assert {:ok, schedule} = Schedule.parse("every 2h")
      assert schedule.kind == :interval
      assert schedule.recurring?
    end

    test "next fire is the reference time plus the interval" do
      {:ok, schedule} = Schedule.parse("every 15m")
      from = ~U[2026-07-27 08:00:00Z]

      assert {:ok, ~U[2026-07-27 08:15:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "rejects a malformed interval" do
      assert {:error, _} = Schedule.parse("every banana")
    end
  end

  describe "parse/1 cron" do
    test "parses a 5-field crontab as recurring" do
      assert {:ok, schedule} = Schedule.parse("0 9 * * 1-5")
      assert schedule.kind == :cron
      assert schedule.recurring?
    end

    test "computes the next daily fire" do
      {:ok, schedule} = Schedule.parse("30 14 * * *")
      from = ~U[2026-07-27 08:00:00Z]

      assert {:ok, ~U[2026-07-27 14:30:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "rolls over to the next day when today's fire has passed" do
      {:ok, schedule} = Schedule.parse("30 14 * * *")
      from = ~U[2026-07-27 15:00:00Z]

      assert {:ok, ~U[2026-07-28 14:30:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "every-minute cron fires on the next minute boundary" do
      {:ok, schedule} = Schedule.parse("* * * * *")
      from = ~U[2026-07-27 08:00:30Z]

      assert {:ok, ~U[2026-07-27 08:01:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "weekday-only cron lands on a weekday at the right time" do
      {:ok, schedule} = Schedule.parse("0 9 * * 1-5")
      # A Saturday; the next weekday 9am is Monday.
      from = ~U[2026-07-25 12:00:00Z]

      assert {:ok, next} = Schedule.next_fire(schedule, from)
      assert next.hour == 9 and next.minute == 0
      assert Date.day_of_week(DateTime.to_date(next)) in 1..5
    end

    test "day-of-week 0 and 7 both mean Sunday" do
      {:ok, zero} = Schedule.parse("0 12 * * 0")
      {:ok, seven} = Schedule.parse("0 12 * * 7")
      from = ~U[2026-07-27 00:00:00Z]

      assert Schedule.next_fire(zero, from) == Schedule.next_fire(seven, from)
      {:ok, next} = Schedule.next_fire(zero, from)
      assert Date.day_of_week(DateTime.to_date(next)) == 7
    end

    test "supports lists and steps" do
      {:ok, schedule} = Schedule.parse("0 */6 * * *")
      from = ~U[2026-07-27 07:00:00Z]

      assert {:ok, ~U[2026-07-27 12:00:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "an impossible cron never fires" do
      # February 30th does not exist.
      {:ok, schedule} = Schedule.parse("0 0 30 2 *")
      assert :never = Schedule.next_fire(schedule, ~U[2026-01-01 00:00:00Z])
    end

    test "a rare-but-valid date (Feb 29) lands on the next leap year" do
      {:ok, schedule} = Schedule.parse("0 0 29 2 *")
      # 2027 is not a leap year; the next Feb 29 is in 2028.
      assert {:ok, ~U[2028-02-29 00:00:00Z]} =
               Schedule.next_fire(schedule, ~U[2026-03-01 00:00:00Z])
    end

    test "rejects an out-of-range field" do
      assert {:error, {:bad_cron_field, :minute, "99"}} = Schedule.parse("99 9 * * *")
    end

    test "rejects an inverted range" do
      assert {:error, {:bad_cron_field, :hour, "9-5"}} = Schedule.parse("0 9-5 * * *")
    end
  end

  describe "parse/1 timestamps" do
    test "parses an ISO 8601 instant as a one-shot" do
      assert {:ok, schedule} = Schedule.parse("2026-08-01T09:00:00Z")
      assert schedule.kind == :timestamp
      refute schedule.recurring?
    end

    test "a future timestamp fires at that instant" do
      {:ok, schedule} = Schedule.parse("2026-08-01T09:00:00Z")
      from = ~U[2026-07-27 00:00:00Z]

      assert {:ok, ~U[2026-08-01 09:00:00Z]} = Schedule.next_fire(schedule, from)
    end

    test "a past timestamp never fires" do
      {:ok, schedule} = Schedule.parse("2020-01-01T00:00:00Z")
      assert :never = Schedule.next_fire(schedule, ~U[2026-07-27 00:00:00Z])
    end
  end

  describe "parse/1 errors" do
    test "rejects an empty schedule" do
      assert {:error, :empty_schedule} = Schedule.parse("   ")
    end

    test "rejects unrecognized input" do
      assert {:error, {:unrecognized_schedule, "banana"}} = Schedule.parse("banana")
    end

    test "rejects a non-string" do
      assert {:error, :invalid_schedule} = Schedule.parse(:not_a_string)
    end
  end

  describe "properties" do
    property "any positive relative duration parses and fires exactly one duration out" do
      check all(
              n <- integer(1..100_000),
              unit <- member_of(["s", "m", "h", "d"])
            ) do
        {:ok, schedule} = Schedule.parse("#{n}#{unit}")
        from = ~U[2026-07-27 08:00:00Z]

        assert {:ok, next} = Schedule.next_fire(schedule, from)
        assert DateTime.diff(next, from, :second) == n * @factors[unit]
      end
    end

    property "every-minute cron always fires strictly within the next minute" do
      {:ok, schedule} = Schedule.parse("* * * * *")

      check all(offset <- integer(0..1_000_000)) do
        from = DateTime.add(~U[2026-07-27 00:00:00Z], offset, :second)
        assert {:ok, next} = Schedule.next_fire(schedule, from)
        assert DateTime.compare(next, from) == :gt
        assert DateTime.diff(next, from, :second) <= 60
        assert next.second == 0
      end
    end
  end
end
