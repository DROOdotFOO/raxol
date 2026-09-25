defmodule Raxol.Benchmark.SuiteRegistryTest do
  # The registry is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Benchmark.SuiteRegistry

  # `mix raxol.bench.advanced` starts it with `start_link/0`.
  test "a registry started without a name serves the API" do
    start_supervised!(SuiteRegistry)

    assert is_list(SuiteRegistry.list_suites())
  end
end
