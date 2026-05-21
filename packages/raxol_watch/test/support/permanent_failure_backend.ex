defmodule Raxol.Watch.Push.PermanentFailureBackend do
  @moduledoc false
  # Test-only push backend that returns a configurable permanent failure
  # reason (e.g. :bad_device_token, :unregistered). Use to exercise the
  # auto-prune path in Notifier.

  @behaviour Raxol.Watch.Push.Backend

  @impl true
  def push(_token, _notification) do
    reason = Application.get_env(:raxol_watch, __MODULE__, :bad_device_token)
    {:error, reason}
  end
end
