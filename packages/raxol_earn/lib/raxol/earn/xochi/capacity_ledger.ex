defmodule Raxol.Earn.Xochi.CapacityLedger do
  @moduledoc """
  Rolling per-destination reservation ledger for `Raxol.Earn.Xochi.TransferOffering`.

  The offering's `:destination_caps` bound a SINGLE order; this ledger bounds the
  RUNNING TOTAL committed to a `{dst_chain, dst_token}` fill leg across concurrent
  jobs. Each accepted job reserves its amount; a reservation is confirmed on
  settlement (kept, so it keeps counting until the capacity is re-derived),
  released on failure, and swept after a TTL if the job never settles. So N
  concurrent small orders can never over-commit inventory the solver cannot fill.

  Opt-in and inert by default: start it in the seller supervision tree and seed
  capacity from `config :raxol_earn, :destination_capacity` (or `load/2`, e.g. from
  the `raxol_earn.derive_caps` mix task). When the process is not running, the
  offering's aggregate check is a no-op; a `{chain, token}` with no configured
  capacity is unbounded.

      # config
      config :raxol_earn, :destination_capacity, %{
        {8453, "0x833589...2913"} => 48_000_000_000   # Base USDC aggregate
      }

      # supervision
      children = [Raxol.Earn.Xochi.CapacityLedger]
  """

  use GenServer

  @type dest_key :: {pos_integer(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reserve `amount` (atomic) for `job_id` against `dest_key`. Idempotent per job.
  Returns `:ok`, or `{:error, :over_capacity}` when the reservation would push the
  destination's running total past its capacity. A dest with no capacity is
  unbounded (`:ok`, untracked).
  """
  @spec reserve(GenServer.server(), term(), dest_key(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :over_capacity}
  def reserve(server \\ __MODULE__, job_id, dest_key, amount, ttl_ms)
      when is_integer(amount) and amount >= 0 do
    GenServer.call(server, {:reserve, job_id, normalize(dest_key), amount, ttl_ms})
  end

  @doc "Confirm a job's reservation on settlement (kept until capacity is reset)."
  @spec confirm(GenServer.server(), term()) :: :ok
  def confirm(server \\ __MODULE__, job_id), do: GenServer.call(server, {:confirm, job_id})

  @doc "Release a job's reservation on failure (frees the capacity)."
  @spec release(GenServer.server(), term()) :: :ok
  def release(server \\ __MODULE__, job_id), do: GenServer.call(server, {:release, job_id})

  @doc "Remaining capacity for a destination (`:infinity` when uncapped)."
  @spec available(GenServer.server(), dest_key()) :: non_neg_integer() | :infinity
  def available(server \\ __MODULE__, dest_key),
    do: GenServer.call(server, {:available, normalize(dest_key)})

  @doc "Set/replace one destination's capacity (e.g. periodic re-derivation)."
  @spec set_capacity(GenServer.server(), dest_key(), non_neg_integer()) :: :ok
  def set_capacity(server \\ __MODULE__, dest_key, cap),
    do: GenServer.call(server, {:set_capacity, normalize(dest_key), cap})

  @doc "Merge a full capacity map (from config or the derive_caps mix task)."
  @spec load(GenServer.server(), %{dest_key() => non_neg_integer()}) :: :ok
  def load(server \\ __MODULE__, capacity_map),
    do: GenServer.call(server, {:load, normalize_map(capacity_map)})

  # -- GenServer --

  @impl true
  def init(opts) do
    capacity =
      Keyword.get_lazy(opts, :capacity, fn ->
        Application.get_env(:raxol_earn, :destination_capacity, %{})
      end)

    now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)

    {:ok, %{capacity: normalize_map(capacity), reservations: %{}, now_fn: now_fn}}
  end

  @impl true
  def handle_call({:reserve, job_id, dest_key, amount, ttl_ms}, _from, state) do
    state = sweep(state)

    cond do
      Map.has_key?(state.reservations, job_id) ->
        {:reply, :ok, state}

      is_nil(Map.get(state.capacity, dest_key)) ->
        {:reply, :ok, state}

      active_sum(state, dest_key) + amount <= Map.fetch!(state.capacity, dest_key) ->
        expires = state.now_fn.() + ttl_ms
        reservations = Map.put(state.reservations, job_id, {dest_key, amount, expires})
        {:reply, :ok, %{state | reservations: reservations}}

      true ->
        {:reply, {:error, :over_capacity}, state}
    end
  end

  def handle_call({:confirm, job_id}, _from, state) do
    reservations =
      case Map.fetch(state.reservations, job_id) do
        {:ok, {dest_key, amount, _expires}} ->
          Map.put(state.reservations, job_id, {dest_key, amount, :confirmed})

        :error ->
          state.reservations
      end

    {:reply, :ok, %{state | reservations: reservations}}
  end

  def handle_call({:release, job_id}, _from, state) do
    {:reply, :ok, %{state | reservations: Map.delete(state.reservations, job_id)}}
  end

  def handle_call({:available, dest_key}, _from, state) do
    state = sweep(state)

    available =
      case Map.get(state.capacity, dest_key) do
        nil -> :infinity
        cap -> max(cap - active_sum(state, dest_key), 0)
      end

    {:reply, available, state}
  end

  def handle_call({:set_capacity, dest_key, cap}, _from, state) do
    {:reply, :ok, %{state | capacity: Map.put(state.capacity, dest_key, cap)}}
  end

  def handle_call({:load, capacity_map}, _from, state) do
    {:reply, :ok, %{state | capacity: Map.merge(state.capacity, capacity_map)}}
  end

  # -- Helpers --

  # Drop TTL-expired, still-in-flight reservations; confirmed ones are permanent.
  defp sweep(state) do
    now = state.now_fn.()

    kept =
      Map.reject(state.reservations, fn {_job, {_dk, _amt, expires}} ->
        expires != :confirmed and expires < now
      end)

    %{state | reservations: kept}
  end

  defp active_sum(state, dest_key) do
    state.reservations
    |> Map.values()
    |> Enum.filter(fn {dk, _amt, _expires} -> dk == dest_key end)
    |> Enum.map(fn {_dk, amount, _expires} -> amount end)
    |> Enum.sum()
  end

  defp normalize({chain, token}) when is_binary(token), do: {chain, String.downcase(token)}
  defp normalize(key), do: key

  defp normalize_map(map), do: Map.new(map, fn {k, v} -> {normalize(k), v} end)
end
