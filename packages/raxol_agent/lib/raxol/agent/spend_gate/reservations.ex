defmodule Raxol.Agent.SpendGate.Reservations do
  @moduledoc false
  # Long-lived owner of the SpendGate reservation registry (U7 / AD-6a).
  #
  # Tracks which `cost_ref`s are currently *reserved but not yet settled*, keyed
  # per budget scope, so a duplicate reserve for the same `cost_ref` is rejected
  # BEFORE it touches the budget (no second reserve, no double-hold). A public
  # ETS `set` table lets the gate `claim`/`release` directly via the atomic
  # `:ets.insert_new/2` check-and-set, without serializing every reserve through
  # this process.
  #
  # The `scope` is the frozen `context.try_reserve` closure itself (see
  # `Raxol.Agent.SpendGate` — the one field guaranteed present and unique per
  # budget scope): two contexts that share a budget seam share a reservation
  # namespace, and independent budgets never collide.
  #
  # Ownership: in production this registry belongs in the agent supervision
  # tree. The agent application does not boot under `MIX_ENV=test`, so the gate
  # starts it lazily and UNLINKED on first use — where it must outlive the
  # individual caller processes (which are often short-lived, and in the crash
  # contour deliberately killed). `GenServer.start/3` (not `start_link`) keeps it
  # detached from whoever happened to touch the gate first.
  use GenServer

  require Logger

  @table __MODULE__

  @doc "Idempotently ensure the registry table exists. Race-safe under concurrency."
  @spec ensure_started() :: :ok
  def ensure_started do
    case :ets.whereis(@table) do
      :undefined ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> await_table()
        end

      _ref ->
        :ok
    end
  end

  @doc """
  Atomically claim `cost_ref` as active within `scope`. `:ok` on a fresh claim;
  `{:error, :duplicate}` when an unsettled reserve for the same `cost_ref`
  already exists (the reserve-once guard).
  """
  @spec claim(term(), String.t()) :: :ok | {:error, :duplicate}
  def claim(scope, cost_ref) do
    if :ets.insert_new(@table, {{scope, cost_ref}, true}),
      do: :ok,
      else: {:error, :duplicate}
  end

  @doc "Release a claim — on a refused reserve, or once the reservation settles."
  @spec release(term(), String.t()) :: :ok
  def release(scope, cost_ref) do
    :ets.delete(@table, {scope, cost_ref})
    :ok
  end

  @impl GenServer
  def init(_) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end

  # The owner holds the named ETS table (dedup claims). It MUST survive stray
  # traffic: the GenServer default `handle_call`/`handle_cast` STOP the process
  # on an unexpected message ({:bad_call}/{:bad_cast}), which would destroy the
  # table and vanish every live claim → double-charge (finding #5). Log + ignore
  # instead of dying. The table has no in-process protocol; claim/release go
  # straight to ETS, so there is genuinely nothing these should service.
  @impl GenServer
  def handle_call(request, _from, table) do
    Logger.debug("SpendGate.Reservations: ignoring unexpected call #{inspect(request)}")
    {:reply, {:error, :unsupported}, table}
  end

  @impl GenServer
  def handle_cast(request, table) do
    Logger.debug("SpendGate.Reservations: ignoring unexpected cast #{inspect(request)}")
    {:noreply, table}
  end

  @impl GenServer
  def handle_info(message, table) do
    Logger.debug("SpendGate.Reservations: ignoring unexpected message #{inspect(message)}")
    {:noreply, table}
  end

  # Lost the start race: the winner's `init/1` may not have created the table
  # yet (the name is registered before `init` returns), so spin briefly for it.
  # Only ever hit once, on the very first use across the VM.
  defp await_table(retries \\ 100)
  defp await_table(0), do: raise("SpendGate.Reservations table failed to start")

  defp await_table(retries) do
    case :ets.whereis(@table) do
      :undefined ->
        Process.sleep(1)
        await_table(retries - 1)

      _ref ->
        :ok
    end
  end
end
