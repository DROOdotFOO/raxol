defmodule Raxol.Core.ErrorRecovery.ContextManagerTest do
  # The context manager is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Core.ErrorRecovery.ContextManager

  # A bare child spec starts it with `start_link([])`, passing no name.
  test "a context manager started without a name serves the API" do
    start_supervised!({ContextManager, []})

    :ok = ContextManager.store_context(:worker, %{attempts: 1})
    assert ContextManager.has_context?(:worker)
  end
end
