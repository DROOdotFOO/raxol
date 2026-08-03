defmodule Raxol.Earn.JobIdResolver.Mock do
  @moduledoc """
  In-process mock for `Raxol.Earn.JobIdResolver`.

  Tests pre-seed the tx-hash -> jobId and request-tag -> jobId maps; this module
  returns them without touching a chain. A tx hash marked pending returns
  `:pending` so the crash-recovery path (resolve -> reconcile) is exercisable.

      resolver = Raxol.Earn.JobIdResolver.Mock.new()
      Raxol.Earn.JobIdResolver.Mock.put_tx(resolver, "0xtx", 42)
      Raxol.Earn.JobIdResolver.Mock.put_tag(resolver, "rk-abc", 42)
      {:ok, 42} = Raxol.Earn.JobIdResolver.resolve(resolver, adapter, 84_532, "0xtx")
  """

  @behaviour Raxol.Earn.JobIdResolver

  @doc "Construct a fresh mock resolver."
  @spec new(keyword()) :: Raxol.Earn.JobIdResolver.t()
  def new(_opts \\ []) do
    table = :ets.new(:raxol_earn_jobid_mock, [:set, :public])
    :ets.insert(table, {:by_tx, %{}})
    :ets.insert(table, {:by_tag, %{}})
    :ets.insert(table, {:pending, MapSet.new()})
    :ets.insert(table, {:default, nil})
    %{adapter: __MODULE__, config: %{table: table}}
  end

  @doc """
  Resolve any tx hash not explicitly mapped (and not marked pending) to
  `job_id`. Convenient for happy-path tests that do not know the minted tx hash.
  """
  @spec put_default(Raxol.Earn.JobIdResolver.t(), non_neg_integer()) :: :ok
  def put_default(%{config: %{table: table}}, job_id) do
    :ets.insert(table, {:default, job_id})
    :ok
  end

  @doc "Map a `createJob` tx hash to the jobId it assigned."
  @spec put_tx(Raxol.Earn.JobIdResolver.t(), String.t(), non_neg_integer()) :: :ok
  def put_tx(%{config: %{table: table}}, tx_hash, job_id) do
    [{:by_tx, m}] = :ets.lookup(table, :by_tx)
    :ets.insert(table, {:by_tx, Map.put(m, tx_hash, job_id)})
    :ok
  end

  @doc "Map a request tag (stamped into the job description) to a jobId."
  @spec put_tag(Raxol.Earn.JobIdResolver.t(), String.t(), non_neg_integer()) :: :ok
  def put_tag(%{config: %{table: table}}, tag, job_id) do
    [{:by_tag, m}] = :ets.lookup(table, :by_tag)
    :ets.insert(table, {:by_tag, Map.put(m, tag, job_id)})
    :ok
  end

  @doc "Force `resolve/4` to return `:pending` for `tx_hash` (receipt not ready)."
  @spec set_pending(Raxol.Earn.JobIdResolver.t(), String.t()) :: :ok
  def set_pending(%{config: %{table: table}}, tx_hash) do
    [{:pending, set}] = :ets.lookup(table, :pending)
    :ets.insert(table, {:pending, MapSet.put(set, tx_hash)})
    :ok
  end

  # -- Behaviour callbacks --

  @impl Raxol.Earn.JobIdResolver
  def resolve(%{config: %{table: table}}, _adapter, _chain_id, tx_hash) do
    [{:pending, pending}] = :ets.lookup(table, :pending)
    [{:by_tx, by_tx}] = :ets.lookup(table, :by_tx)
    [{:default, default}] = :ets.lookup(table, :default)

    cond do
      MapSet.member?(pending, tx_hash) -> :pending
      Map.has_key?(by_tx, tx_hash) -> {:ok, Map.fetch!(by_tx, tx_hash)}
      not is_nil(default) -> {:ok, default}
      true -> :pending
    end
  end

  @impl Raxol.Earn.JobIdResolver
  def reconcile(%{config: %{table: table}}, _api, _chain_id, request_tag) do
    [{:by_tag, by_tag}] = :ets.lookup(table, :by_tag)

    case Map.fetch(by_tag, request_tag) do
      {:ok, job_id} -> {:ok, job_id}
      :error -> :none
    end
  end
end
