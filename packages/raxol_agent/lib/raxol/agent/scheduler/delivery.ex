defmodule Raxol.Agent.Scheduler.Delivery do
  @moduledoc """
  Builds the `(target, rendered -> :ok | {:error, term()})` closures the
  `Scheduler` expects as its `:deliver`.

  A job's `target` is a gateway route string (`"telegram:-100..."`,
  `"discord:#chan"`). `gateway/1` routes it through `Raxol.Gateway.Delivery` when
  the gateway package is loaded, and returns `{:error, :gateway_unavailable}`
  otherwise: raxol_agent does not depend on raxol_gateway, so the reference is
  resolved at runtime. `local/1` delivers to an in-process callback, for surfaces
  without a gateway (a cron result posted straight into an app).

  The gateway's connected-adapters map is owned by whoever runs the gateway, so
  it is captured here by the caller that wires the scheduler, not looked up.
  """

  @compile {:no_warn_undefined, [Raxol.Gateway.Delivery]}

  @typedoc "A `Raxol.Gateway.Delivery` adapters map: `platform => {module, conn}`."
  @type adapters :: %{atom() => {module(), term()}}

  @doc """
  Deliver a job's output to its gateway `target` string via the gateway's
  connected adapters. Returns `{:error, :gateway_unavailable}` when the gateway
  package is not loaded.
  """
  @spec gateway(adapters()) :: (String.t(), term() -> :ok | {:error, term()})
  def gateway(adapters) when is_map(adapters) do
    fn target, rendered -> deliver_via_gateway(adapters, target, rendered) end
  end

  @doc "Deliver to an in-process `callback.(target, rendered)`, for gateway-less surfaces."
  @spec local((String.t(), term() -> :ok | {:error, term()})) ::
          (String.t(), term() -> :ok | {:error, term()})
  def local(callback) when is_function(callback, 2) do
    fn target, rendered -> callback.(target, rendered) end
  end

  defp deliver_via_gateway(adapters, target, rendered) do
    if Code.ensure_loaded?(Raxol.Gateway.Delivery) do
      Raxol.Gateway.Delivery.deliver(adapters, {:target, target}, rendered)
    else
      {:error, :gateway_unavailable}
    end
  end
end
