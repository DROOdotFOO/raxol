defmodule Raxol.ACP.Buyer.Runtime do
  @moduledoc """
  Subscribes to the configured buyer event source and forwards every
  `{:acp_event, event}` message to `Raxol.ACP.Buyer.Queue` -- the mirror of
  `Raxol.ACP.Seller.Runtime`.

  Thin by design: it bridges an asynchronous message source (the backend) to the
  dispatch layer (the Queue) and does not interpret events. If the backend dies,
  `Raxol.ACP.Buyer.Supervisor`'s `:rest_for_one` strategy restarts the Runtime
  too, which re-subscribes on its next `init/1`.

  ## Configuration

  The backend is any `Raxol.ACP.Seller.Backend` implementation (the behaviour is
  a generic ACP event source, shared with the seller):

      config :raxol_acp, buyer_backend: Raxol.ACP.Seller.Backend.InMemory

  For tests and `mix` rehearsals the `InMemory` backend is the primary driver. A
  production buyer points `:buyer_backend` at an SSE-backed source for its own
  jobs (the `Raxol.ACP.Agent` stream) -- that adapter is the one remaining
  integration item flagged for the Sepolia dry-run.

  ## Telemetry

  - `[:raxol, :acp, :buyer, :runtime, :event_received]` -- `%{type, job_id}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.Buyer.Queue
  alias Raxol.ACP.Seller.Backend

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the backend module the Runtime subscribed to."
  @spec backend() :: module()
  def backend, do: GenServer.call(__MODULE__, :backend)

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    backend =
      Keyword.get(opts, :backend) ||
        Application.get_env(:raxol_acp, :buyer_backend) ||
        raise """
        raxol_acp: no buyer backend configured. Set one of:

          config :raxol_acp, buyer_backend: Raxol.ACP.Seller.Backend.InMemory
        """

    :ok = Backend.subscribe(backend, self())

    {:ok, %{backend: backend}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:backend, _from, state), do: {:reply, state.backend, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:acp_event, event}, state) do
    :telemetry.execute(
      [:raxol, :acp, :buyer, :runtime, :event_received],
      %{},
      %{type: Map.get(event, :type), job_id: Map.get(event, :job_id)}
    )

    Queue.dispatch(event)

    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}
end
