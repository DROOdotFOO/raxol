defmodule Raxol.Terminal.Integration.IntegrationApiTest do
  # The functional API must work with no terminal servers running.
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Integration
  alias Raxol.Terminal.Integration.State

  test "write/2 returns the state, as documented in the README" do
    state = Integration.init()

    assert %State{} = written = Integration.write(state, "Hello, World!")
    assert %State{} = Integration.clear(written)
  end

  test "handle_input/2 returns the state" do
    state = Integration.init()

    assert %State{} = Integration.handle_input(state, {:key, ?a})
  end

  test "update_config/2 stores the new config" do
    config = %{behavior: %{scrollback_limit: 2000}}

    assert %State{config: ^config} =
             Integration.update_config(Integration.init(), config)
  end
end
