defmodule Raxol.Core.Runtime.Plugins.PluginErrorHandler do
  @moduledoc """
  Handles plugin error handling and logging.
  """

  @doc """
  Handles event processing errors.
  """
  def handle_event_error(event, reason) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Failed to process event through plugins",
      nil,
      nil,
      %{module: __MODULE__, event: event, reason: reason}
    )

    {:error, reason}
  end
end
