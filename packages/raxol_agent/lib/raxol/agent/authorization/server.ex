defmodule Raxol.Agent.Authorization.Server do
  @moduledoc """
  Per-workflow authorization engine as a GenServer.

  Holds the ordered policy list and the engine `State` (labels, approvals), and
  serializes `evaluate`/`approve` so concurrent phases never race the label state.
  ALLOW and DENY decisions commit their labels immediately; ASK decisions commit
  the prior-ALLOW labels but hold their own writes in escrow until `approve/2`.

  Pending ASKs are keyed by evaluation `route`, so a spawn tree (one root route)
  has at most one outstanding approval, and `approve/2` releases it for the whole
  tree.
  """

  use GenServer

  alias Raxol.Agent.Authorization.Engine

  defstruct policies: [], state: nil, pending: %{}

  @type server :: GenServer.server()

  @doc """
  Start the engine.

  Options: `:policies` (ordered list), `:labels`, `:monotonic`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Evaluate the policies at `phase`. Returns a `Engine.Decision`."
  @spec evaluate(server(), atom(), map(), keyword()) :: Engine.Decision.t()
  def evaluate(server, phase, context, opts \\ []),
    do: GenServer.call(server, {:evaluate, phase, context, opts})

  @doc "Approve the pending ASK for `route`: release escrow and remember it."
  @spec approve(server(), term()) :: :ok | {:error, :no_pending}
  def approve(server, route \\ :default), do: GenServer.call(server, {:approve, route})

  @doc "Reject the pending ASK for `route` (drops it; no label change)."
  @spec reject(server(), term()) :: :ok | {:error, :no_pending}
  def reject(server, route \\ :default), do: GenServer.call(server, {:reject, route})

  @doc "The current label snapshot."
  @spec labels(server()) :: map()
  def labels(server), do: GenServer.call(server, :labels)

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      policies: Keyword.get(opts, :policies, []),
      state:
        Engine.new(
          labels: Keyword.get(opts, :labels, %{}),
          monotonic: Keyword.get(opts, :monotonic, %{})
        )
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, phase, context, opts}, _from, server) do
    route = Keyword.get(opts, :route, :default)
    decision = Engine.evaluate(server.policies, phase, context, server.state, route: route)
    server = apply_decision(server, decision, route)
    {:reply, decision, server}
  end

  def handle_call({:approve, route}, _from, server) do
    case Map.pop(server.pending, route) do
      {nil, _pending} ->
        {:reply, {:error, :no_pending}, server}

      {decision, pending} ->
        engine_state = Engine.approve(decision, server.state)
        {:reply, :ok, %{server | state: engine_state, pending: pending}}
    end
  end

  def handle_call({:reject, route}, _from, server) do
    case Map.pop(server.pending, route) do
      {nil, _pending} -> {:reply, {:error, :no_pending}, server}
      {_decision, pending} -> {:reply, :ok, %{server | pending: pending}}
    end
  end

  def handle_call(:labels, _from, server), do: {:reply, server.state.labels, server}

  # ALLOW/DENY commit their labels now; ASK commits prior-ALLOW labels and parks
  # the decision (its escrow waits for approval).
  defp apply_decision(server, %{action: :ask} = decision, route) do
    engine_state = Engine.commit(decision, server.state)
    %{server | state: engine_state, pending: Map.put(server.pending, route, decision)}
  end

  defp apply_decision(server, decision, _route),
    do: %{server | state: Engine.commit(decision, server.state)}
end
