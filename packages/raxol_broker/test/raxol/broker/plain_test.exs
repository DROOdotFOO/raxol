defmodule Raxol.Broker.PlainTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.Plain
  alias Raxol.Broker.Test.Hostile

  defp refute_hostile_ran do
    refute_received {:hostile, _callback}
  end

  describe "accepts plain data unchanged" do
    test "scalars, lists, tuples, maps, decimals and datetimes round-trip" do
      value = %{
        "AAPL" => Decimal.new("201.25"),
        :loss => Decimal.new("-3.5E-2"),
        1 => [nil, true, false, :atom, "text", -42, {:untrusted, "email"}],
        "at" => DateTime.from_unix!(1_700_000_000, :microsecond),
        "nested" => %{"deeper" => [%{}], "kw" => [max: 1, mode: :strict]}
      }

      assert {:ok, ^value} = Plain.normalize(value)
      assert :ok = Plain.check(value)
    end

    test "decimals at the size bounds, which the journal Codec can encode" do
      max_coef = Integer.pow(10, 40) - 1

      for exp <- [-40, 0, 40], sign <- [1, -1] do
        value = %Decimal{sign: sign, coef: max_coef, exp: exp}
        assert {:ok, ^value} = Plain.normalize(value)
        assert Codec.term(value) == Decimal.to_string(value)
      end
    end
  end

  describe "refuses" do
    test "a struct implementing Enumerable, Inspect and String.Chars without running them" do
      hostile = Hostile.new()

      assert {:error, {:not_plain, []}} = Plain.check(hostile)

      assert {:error, {:not_plain, ["quotes", "AAPL"]}} =
               Plain.check(%{"quotes" => %{"AAPL" => hostile}})

      assert {:error, {:not_plain, [:key]}} = Plain.check(%{hostile => 1})
      assert {:error, {:not_plain, [1]}} = Plain.check([1, hostile])
      assert {:error, {:not_plain, [1]}} = Plain.check({:untrusted, hostile})
      refute_hostile_ran()
    end

    test "decimals with a forged coefficient, exponent or sign" do
      assert {:error, {:not_plain, []}} = Plain.check(%Decimal{sign: 1, coef: :inf, exp: 0})
      assert {:error, {:not_plain, []}} = Plain.check(%Decimal{sign: 1, coef: :NaN, exp: 0})
      assert {:error, {:not_plain, []}} = Plain.check(%Decimal{sign: 1, coef: 1.5, exp: 0})
      assert {:error, {:not_plain, []}} = Plain.check(%Decimal{sign: 1, coef: -1, exp: 0})

      assert {:error, {:not_plain, []}} =
               Plain.check(%Decimal{sign: 1, coef: 1, exp: Hostile.new()})

      assert {:error, {:not_plain, []}} = Plain.check(%Decimal{sign: 0, coef: 1, exp: 0})
      assert {:error, {:not_plain, []}} = Plain.check(Decimal.new("Infinity"))
      refute_hostile_ran()
    end

    test "decimals past the size bounds" do
      over_coef = %Decimal{sign: 1, coef: Integer.pow(10, 40), exp: 0}
      assert {:error, {:not_plain, []}} = Plain.check(over_coef)
      assert {:error, {:not_plain, [:q]}} = Plain.check(%{q: %Decimal{sign: 1, coef: 1, exp: 41}})
      assert {:error, {:not_plain, [0]}} = Plain.check([%Decimal{sign: -1, coef: 1, exp: -41}])
    end

    test "a forged decimal loses extra fields when rebuilt" do
      forged = Map.put(Decimal.new("1"), :extra, Hostile.new())

      assert {:ok, rebuilt} = Plain.normalize(forged)
      assert rebuilt == Decimal.new("1")
      refute Map.has_key?(rebuilt, :extra)
    end

    test "a datetime with forged fields" do
      datetime = DateTime.from_unix!(0)

      assert {:error, {:not_plain, []}} = Plain.check(%{datetime | year: Hostile.new()})
      assert {:error, {:not_plain, []}} = Plain.check(%{datetime | calendar: Hostile})
      assert {:error, {:not_plain, []}} = Plain.check(Map.delete(datetime, :year))
      refute_hostile_ran()
    end

    test "floats, pids, references, ports, functions and improper lists" do
      assert {:error, {:not_plain, []}} = Plain.check(1.5)
      assert {:error, {:not_plain, ["a"]}} = Plain.check(%{"a" => self()})
      assert {:error, {:not_plain, [0]}} = Plain.check([make_ref()])
      assert {:error, {:not_plain, []}} = Plain.check(fn -> :ok end)
      assert {:error, {:not_plain, []}} = Plain.check(&Plain.check/1)
      assert {:error, {:not_plain, []}} = Plain.check(hd(Port.list()))
      assert {:error, {:not_plain, [1]}} = Plain.check([1 | 2])
    end

    test "any struct other than Decimal and DateTime" do
      assert {:error, {:not_plain, []}} = Plain.check(~D[2026-01-01])
      assert {:error, {:not_plain, []}} = Plain.check(MapSet.new([1]))
    end

    test "nesting deeper than the maximum depth" do
      nest = fn depth -> Enum.reduce(1..depth, "leaf", fn _, acc -> [acc] end) end

      assert :ok = Plain.check(nest.(Plain.max_depth()))
      assert {:error, {:not_plain, path}} = Plain.check(nest.(Plain.max_depth() + 1))
      assert length(path) == Plain.max_depth() + 1

      deep_map = Enum.reduce(1..(Plain.max_depth() + 1), "leaf", fn _, acc -> %{"k" => acc} end)
      assert {:error, {:not_plain, _path}} = Plain.check(deep_map)
    end
  end
end
