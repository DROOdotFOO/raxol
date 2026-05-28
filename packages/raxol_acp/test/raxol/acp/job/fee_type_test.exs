defmodule Raxol.ACP.Job.FeeTypeTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Job.FeeType

  test "to_uint8/1 matches the canonical ACPSimple.FeeType ordering" do
    assert FeeType.to_uint8(:no_fee) == 0
    assert FeeType.to_uint8(:immediate_fee) == 1
    assert FeeType.to_uint8(:deferred_fee) == 2
    assert FeeType.to_uint8(:percentage_fee) == 3
  end

  test "from_uint8/1 round-trips every defined value" do
    for type <- FeeType.types() do
      assert {:ok, ^type} = FeeType.from_uint8(FeeType.to_uint8(type))
    end
  end

  test "from_uint8/1 returns :error for unknown ids" do
    assert :error = FeeType.from_uint8(4)
    assert :error = FeeType.from_uint8(255)
  end

  test "types/0 lists all four" do
    assert FeeType.types() == [:no_fee, :immediate_fee, :deferred_fee, :percentage_fee]
  end
end
