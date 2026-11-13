defmodule Raxol.Agent.Scheduler.Delivery do
  @moduledoc """
  Builds the `(target, rendered -> :ok | {:error, term()})` closures the
  `Scheduler` expects as its `:deliver`.

  A job's `target` is an opaque string to the scheduler. `local/1` delivers to
  an in-process callback (a cron result posted straight into an app). An
  application that routes targets to a messaging surface passes its own
  closure as `:deliver`.
  """

  @doc "Deliver to an in-process `callback.(target, rendered)`."
  @spec local((String.t(), term() -> :ok | {:error, term()})) ::
          (String.t(), term() -> :ok | {:error, term()})
  def local(callback) when is_function(callback, 2) do
    fn target, rendered -> callback.(target, rendered) end
  end
end
