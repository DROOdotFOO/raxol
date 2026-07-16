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
  # The `scope` is a TAGGED budget-identity tuple derived by
  # `SpendGate.reserve_scope/1`, in preference order: `{:budget_id, id}` ->
  # `{:scope, s}` -> `{:budget, handle}` -> `{:try_reserve, closure}` (the
  # closure TERM is the documented last-resort fallback only — it is fragile
  # for callers that rebuild the closure per call; see the `reserve_scope`
  # comment in `Raxol.Agent.SpendGate`). Two contexts that share a budget
  # identity share a reservation namespace; the tags keep values from
  # different fields from ever aliasing, so independent budgets never collide.
  #
  # SECURITY TRADEOFF (documented, accepted for U7): the table is `:public` —
  # required by the direct-to-ETS `claim`/`release` design (`:protected` would
  # force every reserve through this process, serializing the hot path). Any
  # co-resident VM process (a plugin, another agent) can therefore delete a
  # live claim (permitting one bounded duplicate reserve per cost_ref) or
  # insert a fake claim (wedging a cost_ref until swept). Money-adjacent but
  # cap-bounded; revisit at U7-I if untrusted in-VM code becomes a real
  # deployment shape.
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

  # Start-race spin bounds (`await_table/1`): how long a loser of the
  # first-use start race waits for the winner's `init/1` to create the table.
  @table_await_retries 100
  @table_await_interval_ms 1

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

  @doc """
  Reclaim EVERY claim held under `scope` — the per-scope teardown/GC path.

  Claims are otherwise removed only on settle or refusal, so a reserver killed
  mid-flight (crash contour) or a run/session budget that simply ended leaks its
  claims forever, growing the table without bound (finding #6). The owner of a
  `scope` (a run/session budget) MUST call this when that scope ends; growth is
  then bounded by scope lifetime, not by process uptime. Returns the number of
  claims reclaimed.

  NOT YET WIRED IN PRODUCTION: nothing in `lib/` drives the gate yet (U7-I —
  the primary-loop integration — is where a run/session scope first EXISTS to
  end). U7-I MUST call `sweep_scope/1` from its scope-teardown path (e.g. the
  budget owner's `terminate/2` or the run supervisor's shutdown); until then
  the leak-and-reclaim behavior is pinned by the robustness suite, including
  the brutal-`:kill` contour (`Process.exit(_, :kill)` runs no `rescue`/
  `after`, so a killed reserver ALWAYS leaks its claim — sweep is the only
  reclaim path).
  """
  @spec sweep_scope(term()) :: non_neg_integer()
  def sweep_scope(scope) do
    ensure_started()
    # match_delete every {{scope, _cost_ref}, _} tuple; select_delete returns
    # the count so callers/telemetry can observe how much was reclaimed.
    :ets.select_delete(@table, [{{{scope, :_}, :_}, [], [true]}])
  end

  @doc "How many claims are currently held (across all scopes) — bound observability."
  @spec count() :: non_neg_integer()
  def count do
    ensure_started()
    :ets.info(@table, :size)
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
  defp await_table(retries \\ @table_await_retries)
  defp await_table(0), do: raise("SpendGate.Reservations table failed to start")

  defp await_table(retries) do
    case :ets.whereis(@table) do
      :undefined ->
        Process.sleep(@table_await_interval_ms)
        await_table(retries - 1)

      _ref ->
        :ok
    end
  end
end
