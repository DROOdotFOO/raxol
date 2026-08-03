defmodule Raxol.Earn.Buyer.Resync do
  @moduledoc """
  Drain-before-act on boot and after a backend restart, for the buyer -- the
  mirror of `Raxol.Earn.Seller.Resync`.

  A buyer that crashes mid-flight loses its in-memory `Raxol.Earn.Buyer.Queue`
  tracking. On (re)start this reads the authoritative job list via
  `JobApi.get_active_jobs/1`, filters to jobs where WE are the buyer and the
  status is non-terminal, and re-tracks each through `Queue.adopt/1` so later
  lifecycle events route to it. For a job observed at `:budget_set` -- the seller
  set the budget but our fund was interrupted -- it also synthesizes a
  `:budget_set` dispatch to resume the interrupted fund (idempotent: the escrow's
  funded-state guard reverts a duplicate fund, and the checkpoint short-circuits
  a fund already recorded).

  Started before `Runtime` under the buyer supervisor's `:rest_for_one`, so
  rehydration precedes live dispatch. A failed drain emits telemetry and does
  NOT block buying (best-effort, like the seller). Requires `:buyer_job_api_opts`
  to be configured; with no job API it is inert.

  ## Resume boundary (flag for the Sepolia dry-run)

  Re-tracking derives a fresh `request_key` from the job identity (`nonce:
  job_id`), so the reservation made under the ORIGINAL pre-crash `request_key`
  is not matched here. With the default ETS ledger a restart clears reservations
  anyway; with a durable ledger the original reservation is reclaimed by the
  ledger's reservation TTL sweep rather than here. The active-job field names /
  status encoding normalized below, and the job-key form, are the same open
  items `Seller.Resync` flags.

  ## Telemetry

  - `[:raxol, :earn, :buyer, :resync, :rehydrated]` -- `%{job_id, status}`.
  - `[:raxol, :earn, :buyer, :resync, :skipped]` -- `%{job_id, reason}`.
  - `[:raxol, :earn, :buyer, :resync, :drain_failed]` -- `%{reason}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Earn.Buyer.Queue
  alias Raxol.Earn.JobApi
  alias Raxol.Earn.JobSession.Status

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    # Drain on the next tick so the Queue (started ahead of us) is ready.
    send(self(), :drain)
    {:ok, %{api: Keyword.get(opts, :api, buyer_job_api())}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:drain, %{api: nil} = state), do: {:noreply, state}

  def handle_manager_info(:drain, %{api: api} = state) do
    case JobApi.get_active_jobs(api) do
      {:ok, jobs} ->
        buyer = Application.get_env(:raxol_earn, :buyer_address)
        Enum.each(jobs, &rehydrate(&1, buyer))

      {:error, reason} ->
        emit(:drain_failed, %{reason: reason})
    end

    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Rehydration --

  defp rehydrate(job, buyer) do
    case normalize(job, buyer) do
      {:ok, intent} -> adopt(intent)
      {:skip, job_id, reason} -> emit(:skipped, %{job_id: job_id, reason: reason})
    end
  end

  defp adopt(intent) do
    case Queue.adopt(intent) do
      {:ok, job_id} ->
        emit(:rehydrated, %{job_id: job_id, status: intent.status})
        maybe_redrive(intent)

      {:error, reason} ->
        emit(:skipped, %{job_id: intent[:job_id], reason: reason})
    end
  end

  # A job we should resume: we are the buyer, status is non-terminal, and the
  # required fields (job_id, provider, budget) are present.
  defp normalize(job, buyer) do
    job_id = read(job, ["onChainJobId", "jobId", "job_id"]) |> coerce_id()
    provider = read(job, ["provider", "providerAddress", "provider_address"])
    job_buyer = read(job, ["buyer", "clientAddress", "client_address"])
    status = job |> read(["status", "phase", "state"]) |> to_status()
    budget_raw = read(job, ["budget", "budgetRaw", "budget_raw", "amount"]) |> coerce_id()

    cond do
      is_nil(job_id) -> {:skip, nil, :no_job_id}
      not ours?(buyer, job_buyer) -> {:skip, job_id, :not_our_job}
      is_nil(status) or Status.terminal?(status) -> {:skip, job_id, :terminal_or_unknown}
      is_nil(provider) -> {:skip, job_id, :no_provider}
      is_nil(budget_raw) -> {:skip, job_id, :no_budget}
      true -> {:ok, build_intent(job_id, provider, status, budget_raw)}
    end
  end

  defp build_intent(job_id, provider, status, budget_raw) do
    chain_id = Application.get_env(:raxol_earn, :buyer_chain_id, 8453)

    %{
      job_id: job_id,
      provider: provider,
      status: status,
      amount: Raxol.Earn.AssetToken.usdc_from_raw(budget_raw, chain_id)
    }
  end

  # Only :budget_set has an interrupted action we can resume from on-chain data
  # alone (the fund). :submitted needs the off-chain deliverable, which a live
  # event carries -- so we adopt and wait rather than guess.
  defp maybe_redrive(%{status: :budget_set, job_id: job_id, amount: amount}) do
    Queue.dispatch(%{type: :budget_set, job_id: job_id, budget_raw: amount.raw_amount})
  end

  defp maybe_redrive(_intent), do: :ok

  # -- Field readers (tolerant of the live vs mock shapes) --

  defp ours?(nil, _job_buyer), do: true

  defp ours?(buyer, job_buyer) when is_binary(buyer) and is_binary(job_buyer),
    do: String.downcase(buyer) == String.downcase(job_buyer)

  defp ours?(_buyer, _job_buyer), do: false

  # Live active-job maps are string-keyed (mirroring `Seller.Resync`'s `pick/2`).
  defp read(job, keys), do: Enum.find_value(keys, &Map.get(job, &1))

  defp to_status(nil), do: nil
  defp to_status(status) when is_atom(status), do: if(status in Status.all(), do: status)

  defp to_status(status) when is_binary(status) do
    Enum.find(Status.all(), &(Atom.to_string(&1) == status))
  end

  defp coerce_id(nil), do: nil
  defp coerce_id(n) when is_integer(n), do: n

  defp coerce_id(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp coerce_id(_), do: nil

  defp buyer_job_api do
    case Application.get_env(:raxol_earn, :buyer_job_api_opts) do
      nil -> nil
      opts when is_list(opts) -> JobApi.HTTP.new(opts)
    end
  end

  defp emit(suffix, metadata) do
    :telemetry.execute([:raxol, :earn, :buyer, :resync, suffix], %{}, metadata)
  end
end
