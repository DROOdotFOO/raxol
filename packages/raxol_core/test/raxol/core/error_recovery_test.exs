defmodule Raxol.Core.ErrorRecoveryTest do
  # ErrorRecovery is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Core.ErrorRecovery

  # `Raxol.Application` starts it as `{ErrorRecovery, [mode: :minimal]}` in
  # minimal mode.
  test "a server started without a name serves the circuit breaker" do
    start_supervised!({ErrorRecovery, [mode: :minimal]})

    assert ErrorRecovery.with_circuit_breaker(:naming, fn -> {:ok, :done} end) ==
             {:ok, :done}
  end
end
