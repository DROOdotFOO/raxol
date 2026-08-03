defmodule Raxol.Earn.Seller.Resync do
  @moduledoc """
  Drain-before-act: on seller boot (and after every Backend restart, via
  `:rest_for_one` ordering), read the authoritative set of in-flight jobs from
  the ACP job API and reconcile local state to it — rebuilding the
  `JobSession`s a BEAM restart destroyed and re-enqueueing any delivery the
  crash interrupted, before live events are acted on.

  This closes the restart half of M1. The `Provider` checkpoints close the
  step half: a re-enqueued delivery finds the pinned deliverable/tx record and
  resumes instead of re-doing work or double-submitting (see
  `Raxol.Earn.JobSession.Provider`).

  ## Mechanism

  Everything flows through the Queue's existing, idempotent dispatch — Resync
  owns no job state:

  1. `Raxol.Earn.JobApi.get_active_jobs/1` (the API configured by
     `:seller_job_api_opts`; when unset, resync is disabled and boot proceeds).
  2. Per job on the seller chain: rehydrate the session with
     `initial_status:` = the API phase (an already-live session is advanced
     with `apply_event/3` only if it lags).
  3. Synthesize `:job_offered` — the Queue re-tracks the job: a still-`:open`
     job runs the normal accept; `:budget_set` no-ops idempotently; `:funded` /
     `:submitted` take the Queue's mid-flight adoption path.
  4. For `:funded`, additionally synthesize `:payment_received` — re-enqueueing
     the pending delivery.
  5. Terminal phases only clear any leftover checkpoint records.

  A failed drain emits `[:raxol, :earn, :seller, :resync, :failed]` and does
  **not** crash the seller tree: inability to reach the API must not stop new
  live jobs. Job ids are used exactly as the API returns them; the session key
  must match the form the live backend delivers (verified in the Sepolia
  dry-run).

  ## Phase mapping

  Accepts the v2 names (`open`, `budget_set`, `funded`, `submitted`,
  `completed`, `rejected`, `expired`) and the acp-node-v2 aliases (`request`,
  `negotiation`, `transaction`, `evaluation`) in any case/camelCase. A numeric
  phase is skipped, not mapped: the integer enum order is not pinned here, so
  acting on a guessed mapping could re-drive the wrong phase. Unknown or numeric
  phases skip the job with telemetry rather than acting on a state we do not
  understand.
  """

  use GenServer

  alias Raxol.Earn.{JobApi, JobSession}
  alias Raxol.Earn.Offering.Registry, as: OfferingRegistry
  alias Raxol.Earn.Seller.Queue

  @live_phases [:open, :budget_set, :funded, :submitted]
  @terminal_phases [:completed, :rejected, :expired]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}, {:continue, :resync}}
  end

  @impl true
  def handle_continue(:resync, state) do
    _ = run()
    {:noreply, state}
  end

  @doc """
  Run one drain now. `api` defaults to the Queue's configured
  `:seller_job_api_opts` API; with none configured this is a no-op `{:ok,
  :disabled}`. Returns `{:ok, summary}` with per-outcome counts.
  """
  @spec run(JobApi.t() | nil) :: {:ok, map() | :disabled} | {:error, term()}
  def run(api \\ nil) do
    case api || Queue.defaults().job_api do
      nil ->
        {:ok, :disabled}

      api ->
        case JobApi.get_active_jobs(api) do
          {:ok, jobs} -> {:ok, reconcile(jobs, Queue.defaults())}
          {:error, reason} -> failed(reason)
        end
    end
  end

  # -- Reconciliation --

  defp reconcile(jobs, defaults) do
    summary =
      Enum.reduce(jobs, %{adopted: 0, redelivered: 0, cleaned: 0, skipped: 0}, fn job, acc ->
        case normalize(job, defaults) do
          {:ok, norm} -> reconcile_job(norm, defaults, acc)
          {:skip, reason} -> skip(job, reason, acc)
        end
      end)

    emit(:completed, Map.put(summary, :jobs, length(jobs)))
    summary
  end

  defp reconcile_job(%{phase: phase} = norm, defaults, acc) when phase in @terminal_phases do
    clear_checkpoints(defaults.chain_id, norm.job_id)
    %{acc | cleaned: acc.cleaned + 1}
  end

  defp reconcile_job(%{phase: phase} = norm, defaults, acc) when phase in @live_phases do
    rehydrate_session(defaults.chain_id, norm.job_id, phase)

    Queue.dispatch(%{
      type: :job_offered,
      job_id: norm.job_id,
      offering: norm.offering,
      request: norm.request,
      buyer: norm.buyer
    })

    if phase == :funded do
      Queue.dispatch(%{type: :payment_received, job_id: norm.job_id, payload: %{resync: true}})
      %{acc | redelivered: acc.redelivered + 1}
    else
      %{acc | adopted: acc.adopted + 1}
    end
  end

  # Rebuild the session at the authoritative phase; advance a surviving
  # session only when it lags (apply_event is an observed transition and
  # bypasses adjacency, so catching up is always legal).
  defp rehydrate_session(chain_id, job_id, phase) do
    case JobSession.Supervisor.start_session(
           chain_id: chain_id,
           job_id: job_id,
           role: :provider,
           initial_status: phase
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        advance_if_lagging({chain_id, job_id}, phase)

      {:error, reason} ->
        emit(:skipped, %{job_id: job_id, reason: {:session_start_failed, reason}})
        :ok
    end
  end

  # The session can stop (terminal) between the API read and this call; a gone
  # session is fine -- the Queue's own guards handle whatever comes next.
  defp advance_if_lagging(key, phase) do
    if JobSession.status(key) != phase, do: JobSession.apply_event(key, phase, %{resync: true})
    :ok
  catch
    :exit, _ -> :ok
  end

  defp clear_checkpoints(chain_id, job_id) do
    case Raxol.Earn.Checkpoint.store() do
      nil ->
        :ok

      store ->
        for step <- [:accept, :submit] do
          Raxol.Payments.Checkpoint.delete(
            store,
            Raxol.Earn.Checkpoint.key(chain_id, job_id, step)
          )
        end

        :ok
    end
  end

  # -- Normalization --

  defp normalize(job, defaults) do
    with {:ok, job_id} <- field(job, ["id", "jobId", "job_id", "onChainJobId"], :no_job_id),
         {:ok, phase} <- phase(pick(job, ["phase", "status"])),
         :ok <- chain_ok(pick(job, ["chainId", "chain_id"]), defaults.chain_id),
         {:ok, offering} <- offering_name(job) do
      {:ok,
       %{
         job_id: job_id,
         phase: phase,
         offering: offering,
         request: request_of(job),
         buyer: pick(job, ["clientAddress", "client", "buyer", "buyerAddress"])
       }}
    end
  end

  defp field(job, keys, error) do
    case pick(job, keys) do
      nil -> {:skip, error}
      value -> {:ok, value}
    end
  end

  defp pick(job, keys), do: Enum.find_value(keys, &Map.get(job, &1))

  defp chain_ok(nil, _default), do: :ok
  defp chain_ok(chain, chain), do: :ok

  defp chain_ok(chain, default) when is_binary(chain) do
    case Integer.parse(chain) do
      {^default, ""} -> :ok
      _ -> {:skip, {:other_chain, chain}}
    end
  end

  defp chain_ok(chain, _default), do: {:skip, {:other_chain, chain}}

  defp offering_name(job) do
    named =
      case pick(job, ["offering", "jobOffering"]) do
        %{"name" => name} when is_binary(name) -> name
        name when is_binary(name) -> name
        _ -> pick(job, ["offeringName", "name"])
      end

    cond do
      is_binary(named) and match?({:ok, _}, OfferingRegistry.lookup(named)) -> {:ok, named}
      is_binary(named) -> {:skip, {:offering_not_registered, named}}
      true -> sole_registered_offering()
    end
  end

  # An unlabelled job is only unambiguous when exactly one offering is live.
  defp sole_registered_offering do
    case Raxol.Earn.Seller.Offerings.configured() do
      [only] -> {:ok, only.offering_name()}
      _ -> {:skip, :offering_unlabelled}
    end
  end

  defp request_of(job) do
    case pick(job, ["requirement", "serviceRequirement", "request", "memo"]) do
      %{} = req -> req
      _ -> %{}
    end
  end

  defp phase(nil), do: {:skip, :no_phase}

  # Numeric phases are NOT mapped positionally. The on-chain / API integer enum
  # order is not pinned in this package, so guessing it risks acting on the wrong
  # phase (e.g. treating `funded` as `submitted` and re-arming a delivery). Skip
  # loudly until a dry-run confirms the encoding; string phases are unambiguous.
  defp phase(n) when is_integer(n), do: {:skip, {:ambiguous_numeric_phase, n}}

  defp phase(s) when is_binary(s) do
    case s |> Macro.underscore() |> String.downcase() do
      "open" -> {:ok, :open}
      "request" -> {:ok, :open}
      "budget_set" -> {:ok, :budget_set}
      "negotiation" -> {:ok, :budget_set}
      "funded" -> {:ok, :funded}
      "transaction" -> {:ok, :funded}
      "submitted" -> {:ok, :submitted}
      "evaluation" -> {:ok, :submitted}
      "completed" -> {:ok, :completed}
      "rejected" -> {:ok, :rejected}
      "expired" -> {:ok, :expired}
      other -> {:skip, {:unknown_phase, other}}
    end
  end

  defp phase(other), do: {:skip, {:unknown_phase, other}}

  # -- Telemetry --

  defp skip(job, reason, acc) do
    emit(:skipped, %{job_id: Map.get(job, "id"), reason: reason})
    %{acc | skipped: acc.skipped + 1}
  end

  defp failed(reason) do
    emit(:failed, %{reason: reason})
    {:error, reason}
  end

  defp emit(suffix, metadata) do
    :telemetry.execute([:raxol, :earn, :seller, :resync, suffix], %{}, metadata)
  end
end
