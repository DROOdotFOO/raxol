defmodule Raxol.Earn.Buyer.Runtime do
  @moduledoc """
  Subscribes to the configured buyer event source and forwards every
  `{:acp_event, event}` message to `Raxol.Earn.Buyer.Queue` -- the mirror of
  `Raxol.Earn.Seller.Runtime`.

  Thin by design: it bridges an asynchronous message source (the backend) to the
  dispatch layer (the Queue) and does not interpret events. If the backend dies,
  `Raxol.Earn.Buyer.Supervisor`'s `:rest_for_one` strategy restarts the Runtime
  too, which re-subscribes on its next `init/1`.

  ## Configuration

  The backend is any `Raxol.Earn.Seller.Backend` implementation (the behaviour is
  a generic ACP event source, shared with the seller):

      config :raxol_earn, buyer_backend: Raxol.Earn.Seller.Backend.InMemory

  For tests and `mix` rehearsals the `InMemory` backend is the primary driver. A
  production buyer points `:buyer_backend` at an SSE-backed source for its own
  jobs (the `Raxol.Earn.Agent` stream) -- that adapter is the one remaining
  integration item flagged for the Sepolia dry-run.

  ## Telemetry

  - `[:raxol, :earn, :buyer, :runtime, :event_received]` -- `%{type, job_id}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Earn.Buyer.Queue
  alias Raxol.Earn.Seller.Backend

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
        Application.get_env(:raxol_earn, :buyer_backend) ||
        raise """
        raxol_earn: no buyer backend configured. Set one of:

          config :raxol_earn, buyer_backend: Raxol.Earn.Seller.Backend.InMemory
        """

    :ok = Backend.subscribe(backend, self())

    {:ok, %{backend: backend}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:backend, _from, state), do: {:reply, state.backend, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:acp_event, event}, state) do
    :telemetry.execute(
      [:raxol, :earn, :buyer, :runtime, :event_received],
      %{},
      %{type: Map.get(event, :type), job_id: Map.get(event, :job_id)}
    )

    Queue.dispatch(event)

    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}
end
