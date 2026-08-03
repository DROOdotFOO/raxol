defmodule Raxol.Earn.Console.BenchSlots do
  @moduledoc """
  Bounds concurrent `bench_validated` jobs, the console offering's scarce
  resource — the same reserve-at-accept / release-at-deliver / TTL-sweep shape
  as the Xochi `CapacityLedger`, sized down to a slot counter.

  `handle_request/2` reserves a slot (per `job_id`, idempotent) before
  accepting; a full bench rejects with `:at_bench_capacity` **before escrow**,
  so a buyer is never funded into a job we cannot validate in SLA. Delivery
  releases in an `after` clause; the TTL sweep (default 45 min, ≈ SLA + margin)
  reclaims slots from jobs that died without releasing.

  Config: `config :raxol_earn, console_bench_slots: 1, console_bench_slot_ttl_ms:
  2_700_000`. Started by `Raxol.Earn.Seller.Supervisor` ahead of the Queue (like
  the capacity gate) only when the console offering is configured; when the
  process is not running, `reserve/1` fails closed with
  `{:error, :bench_unavailable}`.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reserve a slot for `job_id`. Idempotent per job."
  @spec reserve(binary()) :: :ok | {:error, :at_bench_capacity | :bench_unavailable}
  def reserve(job_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :bench_unavailable}
      pid -> GenServer.call(pid, {:reserve, job_id})
    end
  end

  @doc "Release the slot held by `job_id`. Idempotent; safe when not running."
  @spec release(binary()) :: :ok
  def release(job_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:release, job_id})
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       max: opts[:max] || Application.get_env(:raxol_earn, :console_bench_slots, 1),
       ttl_ms:
         opts[:ttl_ms] || Application.get_env(:raxol_earn, :console_bench_slot_ttl_ms, 2_700_000),
       slots: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, job_id}, _from, state) do
    state = sweep(state)

    cond do
      Map.has_key?(state.slots, job_id) ->
        {:reply, :ok, state}

      map_size(state.slots) >= state.max ->
        {:reply, {:error, :at_bench_capacity}, state}

      true ->
        {:reply, :ok, put_in(state.slots[job_id], System.monotonic_time(:millisecond))}
    end
  end

  def handle_call({:release, job_id}, _from, state),
    do: {:reply, :ok, %{state | slots: Map.delete(state.slots, job_id)}}

  defp sweep(%{ttl_ms: ttl} = state) do
    cutoff = System.monotonic_time(:millisecond) - ttl
    %{state | slots: :maps.filter(fn _k, at -> at > cutoff end, state.slots)}
  end
end
