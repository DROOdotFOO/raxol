defmodule Raxol.ACP.Xochi.CapacityRefresher do
  @moduledoc """
  Periodically re-derives per-destination capacity from the solver's live
  on-chain balances and loads it into `Raxol.ACP.Xochi.CapacityLedger`, so the
  offering's aggregate cap tracks the chain as fills drain inventory.

  On the configured interval it calls the derive function (by default
  `Raxol.ACP.Xochi.CapacityDeriver.capacity_map/1`, one `balanceOf` per corridor)
  and `CapacityLedger.load/2` (a MERGE -- corridors whose RPC was unreachable keep
  their prior capacity rather than dropping to unbounded). A derive that raises or
  returns empty is logged and skipped, leaving the ledger untouched; the next tick
  retries. Runs in the `CapacityGate` supervisor alongside the ledger.

  Options: `:ledger` (server, default `CapacityLedger`), `:interval_ms` (default
  15 min), `:derive_fn` (0-arity, overrides the network deriver -- injected in
  tests), `:deriver_opts` (forwarded to the default deriver), `:refresh_on_start`
  (default `true`).
  """

  use GenServer
  require Logger

  alias Raxol.ACP.Xochi.{CapacityDeriver, CapacityLedger}

  @default_interval_ms 900_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force a refresh now (synchronous). Returns `:ok` or `{:error, :refresh_failed}`."
  @spec refresh(GenServer.server()) :: :ok | {:error, :refresh_failed}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 60_000)

  @impl true
  def init(opts) do
    state = %{
      ledger: Keyword.get(opts, :ledger, CapacityLedger),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      derive_fn: Keyword.get(opts, :derive_fn) || default_derive_fn(opts)
    }

    if Keyword.get(opts, :refresh_on_start, true) do
      send(self(), :refresh)
    else
      schedule(state.interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {:reply, do_refresh(state), state}
  end

  # -- Internal --

  defp do_refresh(state) do
    capacity = state.derive_fn.()

    if is_map(capacity) and map_size(capacity) > 0 do
      CapacityLedger.load(state.ledger, capacity)
      :ok
    else
      Logger.info("[capacity_refresher] derive returned nothing; ledger unchanged")
      :ok
    end
  rescue
    error ->
      Logger.warning("[capacity_refresher] refresh failed: #{Exception.message(error)}")
      {:error, :refresh_failed}
  end

  defp default_derive_fn(opts) do
    deriver_opts = Keyword.get(opts, :deriver_opts, [])
    fn -> CapacityDeriver.capacity_map(deriver_opts) end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :refresh, interval_ms)
end
