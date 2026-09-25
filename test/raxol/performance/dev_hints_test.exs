defmodule Raxol.Performance.DevHintsTest do
  # DevHints is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Performance.DevHints

  setup do
    on_exit(fn -> :telemetry.detach("raxol-dev-hints") end)
  end

  # `Raxol.Application` starts it as `{DevHints, []}` in dev.
  test "a server started without a name turns hints on" do
    start_supervised!({DevHints, [enabled: true]})

    assert DevHints.enabled?()
    refute DevHints.stats() == %{enabled: false}
  end
end
