defmodule Raxol.ACP.Offering.Registry do
  @moduledoc """
  Registry of ACP offerings the seller agent provides.

  Backed by an ETS table owned by this GenServer (so registrations
  survive a transient client crash but die with the supervisor).
  Reads are direct ETS lookups, no GenServer round-trip; only
  registration and removal go through the process.

  ## Spec shape

      %Raxol.ACP.Offering.Spec{
        name: "xochi.private_swap",
        handler: Xochi.ACP.PrivateSwapOffering,
        price_usdc: Decimal.new("0.50"),
        sla_minutes: 5,
        cluster: "on_chain",
        requirements_schema: %{...},      # JSON Schema map
        deliverables_schema: %{...}
      }

  Modules using `use Raxol.ACP.Offering` get a `register/0` convenience
  that builds and submits the spec automatically. Hand-built specs work
  too -- pass any map matching the struct shape to `register/1`.
  """

  use GenServer

  defmodule Spec do
    @moduledoc "Struct describing one ACP offering registration."

    @enforce_keys [:name, :handler]
    defstruct [
      :name,
      :handler,
      :price_usdc,
      :sla_minutes,
      :cluster,
      :requirements_schema,
      :deliverables_schema
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            handler: module(),
            price_usdc: Decimal.t() | nil,
            sla_minutes: pos_integer() | nil,
            cluster: String.t() | nil,
            requirements_schema: map() | nil,
            deliverables_schema: map() | nil
          }
  end

  @table __MODULE__

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an offering.

  `spec` may be a `Spec` struct or a plain map with the same keys.
  Returns `{:ok, spec}` on success or `{:error, {:already_registered, name}}`
  if an offering with that name already exists.
  """
  @spec register(map() | Spec.t()) :: {:ok, Spec.t()} | {:error, term()}
  def register(spec), do: GenServer.call(__MODULE__, {:register, to_spec(spec)})

  @doc "Remove an offering by name. Returns `:ok` even if it was not registered."
  @spec deregister(String.t()) :: :ok
  def deregister(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:deregister, name})
  end

  @doc """
  Look up an offering by name.

  Returns `{:ok, spec}` or `:error`. Direct ETS read -- safe to call
  from any process.
  """
  @spec lookup(String.t()) :: {:ok, Spec.t()} | :error
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, spec}] -> {:ok, spec}
      [] -> :error
    end
  end

  @doc "List all registered offerings, in unspecified order."
  @spec list_all() :: [Spec.t()]
  def list_all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, spec} -> spec end)
  end

  @doc "Count registered offerings."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Wipe all registrations. Intended for tests."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, %Spec{name: name} = spec}, _from, state) do
    reply =
      case :ets.lookup(@table, name) do
        [] ->
          true = :ets.insert(@table, {name, spec})
          {:ok, spec}

        [_] ->
          {:error, {:already_registered, name}}
      end

    {:reply, reply, state}
  end

  def handle_call({:deregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # -- Helpers --

  defp to_spec(%Spec{} = spec), do: spec
  defp to_spec(map) when is_map(map), do: struct!(Spec, Map.to_list(map))
end
