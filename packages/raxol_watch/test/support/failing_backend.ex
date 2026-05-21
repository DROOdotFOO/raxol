defmodule Raxol.Watch.Push.FailingBackend do
  @moduledoc false
  # Test-only push backend that always returns a transient error
  # (`:too_many_requests`). Use to exercise telemetry on the failure
  # branch without triggering the auto-prune path.
  @behaviour Raxol.Watch.Push.Backend

  @impl true
  def push(_token, _notification), do: {:error, :too_many_requests}
end
