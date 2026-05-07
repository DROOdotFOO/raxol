defmodule Raxol.ACP.Bench.Runner do
  @moduledoc """
  Drives N synthetic ACP jobs through the in-memory seller stack and
  reports outcomes.

  ## Method

  Each job traverses the full ACP lifecycle:

      InMemory.publish(:job_offered)        # Queue starts Job.Server,
                                            # calls accept_request -> :negotiation
      InMemory.publish(:payment_received)   # Queue routes to existing
                                            # server -> :transaction
      Job.Server.deliver(job_id)            # handler runs -> :evaluation
      InMemory.publish(:approval_received)  # Queue routes -> :completed

  The Queue intentionally does not auto-deliver after `:payment_received`
  (handlers control delivery timing -- see `Raxol.ACP.Seller.Queue`).
  The bench triggers `deliver/1` synchronously between events because
  the Bench.Offering returns immediately.

  ## Outcomes

  A job is **success** iff:

  - It reached the `:completed` terminal state inside `:job_timeout`
  - The final `Store.load/1` shows exactly four memos (`:negotiation`,
    `:transaction`, `:evaluation`, `:completed`)
  - Each memo has a 65-byte EIP-712 signature
  - The chain-side `InMemory.list_memos/1` shows the same four types

  Otherwise the job is **failure** with a tagged reason for the
  summary.

  ## Result shape

      %Raxol.ACP.Bench.Runner.Summary{
        jobs: [%Raxol.ACP.Bench.Runner.Outcome{...}],   # one per job, in order
        successes: 9,
        failures: 1,
        longest_consecutive_successes: 7,
        gate: 3,
        gate_met?: true,
        elapsed_ms: 312
      }

  ## Caller responsibility

  The caller (the Mix task) must have:

  - Set `:contract_client` to `Raxol.ACP.ContractClient.InMemory`
  - Set `:seller_enabled` to `true`
  - Set `:seller_backend` to `Raxol.ACP.Seller.Backend.InMemory`
  - Configured a wallet (`:seller_wallet`, `:seller_memo_opts`,
    `:seller_address`)
  - Started the application so the supervisor tree is live
  - Registered an offering handler (the runner does NOT register one
    itself -- pass the offering name and let the caller register
    `Raxol.ACP.Bench.Offering` or any compatible echo handler)

  This separation keeps the Runner a pure driver and lets tests mix
  in different offerings.
  """

  alias Raxol.ACP.{ContractClient, Job}
  alias Raxol.ACP.ContractClient.InMemory, as: ChainInMem
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.Seller.Backend.InMemory, as: BackendInMem

  defmodule Outcome do
    @moduledoc "One job's outcome from a bench run."

    @enforce_keys [:job_id, :status, :elapsed_ms]
    defstruct [:job_id, :status, :elapsed_ms, :reason]

    @type status :: :success | :failure
    @type t :: %__MODULE__{
            job_id: binary(),
            status: status(),
            elapsed_ms: non_neg_integer(),
            reason: term() | nil
          }
  end

  defmodule Summary do
    @moduledoc "Aggregated result of a bench run."

    @enforce_keys [
      :jobs,
      :successes,
      :failures,
      :longest_consecutive_successes,
      :gate,
      :gate_met?,
      :elapsed_ms
    ]
    defstruct [
      :jobs,
      :successes,
      :failures,
      :longest_consecutive_successes,
      :gate,
      :gate_met?,
      :elapsed_ms
    ]

    @type t :: %__MODULE__{
            jobs: [Outcome.t()],
            successes: non_neg_integer(),
            failures: non_neg_integer(),
            longest_consecutive_successes: non_neg_integer(),
            gate: non_neg_integer(),
            gate_met?: boolean(),
            elapsed_ms: non_neg_integer()
          }
  end

  @default_jobs 10
  @default_gate 3
  @default_job_timeout_ms 2_000
  @default_seller_address "0x" <> String.duplicate("11", 20)
  @default_buyer_address "0x" <> String.duplicate("22", 20)

  @doc """
  Run a bench session.

  ## Options

  - `:jobs` -- number of jobs to drive. Default `#{@default_jobs}`.
  - `:gate` -- minimum consecutive successes required for the run to
    pass. Default `#{@default_gate}`.
  - `:offering` -- the registered offering name to drive. Required.
  - `:price_usdc` -- price per job (`Decimal` or string). Default
    `"0.01"`.
  - `:seller` -- 0x-prefixed seller address (any string is fine for
    the in-memory client). Default a synthetic constant.
  - `:buyer` -- 0x-prefixed buyer address. Default a synthetic
    constant.
  - `:request_builder` -- 1-arity fn that takes the job index (1..N)
    and returns the request map. Default returns `%{"payload" =>
    %{"i" => idx}}`.
  - `:job_timeout_ms` -- how long to wait for a job to reach
    `:completed`. Default `#{@default_job_timeout_ms}`.
  - `:reset?` -- whether to wipe ContractClient.InMemory and Store
    state before starting. Default `true`.
  """
  @spec run(keyword()) :: Summary.t()
  def run(opts \\ []) do
    jobs = Keyword.get(opts, :jobs, @default_jobs)
    gate = Keyword.get(opts, :gate, @default_gate)
    offering = Keyword.fetch!(opts, :offering)
    price = price(opts)
    seller = Keyword.get(opts, :seller, @default_seller_address)
    buyer = Keyword.get(opts, :buyer, @default_buyer_address)
    builder = Keyword.get(opts, :request_builder, &default_request/1)
    timeout = Keyword.get(opts, :job_timeout_ms, @default_job_timeout_ms)

    if Keyword.get(opts, :reset?, true) do
      ChainInMem.reset()
      Store.clear()
    end

    started_at = System.monotonic_time(:millisecond)

    outcomes =
      for idx <- 1..jobs do
        run_one(%{
          idx: idx,
          offering: offering,
          price: price,
          seller: seller,
          buyer: buyer,
          request: builder.(idx),
          timeout_ms: timeout
        })
      end

    elapsed = System.monotonic_time(:millisecond) - started_at
    successes = Enum.count(outcomes, &(&1.status == :success))

    longest =
      outcomes
      |> Enum.map(& &1.status)
      |> longest_run(:success)

    %Summary{
      jobs: outcomes,
      successes: successes,
      failures: jobs - successes,
      longest_consecutive_successes: longest,
      gate: gate,
      gate_met?: longest >= gate,
      elapsed_ms: elapsed
    }
  end

  # -- Per-job driver --

  defp run_one(ctx) do
    started_at = System.monotonic_time(:millisecond)

    result =
      with {:ok, job_id} <- create_job(ctx),
           :ok <- offer_job(ctx, job_id),
           :ok <- wait_for_state(job_id, :negotiation, ctx.timeout_ms),
           :ok <- send_payment(job_id),
           :ok <- wait_for_state(job_id, :transaction, ctx.timeout_ms),
           :ok <- handler_deliver(job_id),
           :ok <- wait_for_state(job_id, :evaluation, ctx.timeout_ms),
           :ok <- send_approval(job_id),
           :ok <- wait_for_state(job_id, :completed, ctx.timeout_ms),
           :ok <- verify_persisted(job_id) do
        {:ok, job_id}
      end

    elapsed = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, job_id} ->
        %Outcome{job_id: job_id, status: :success, elapsed_ms: elapsed}

      {:error, {stage, reason}} ->
        %Outcome{
          job_id: stage_job_id(stage, ctx),
          status: :failure,
          elapsed_ms: elapsed,
          reason: {stage, reason}
        }

      {:error, reason} ->
        %Outcome{
          job_id: "job-#{ctx.idx}",
          status: :failure,
          elapsed_ms: elapsed,
          reason: reason
        }
    end
  end

  defp stage_job_id(:create_job, ctx), do: "pending-#{ctx.idx}"
  defp stage_job_id(_, _ctx), do: "<unknown>"

  defp create_job(ctx) do
    case ContractClient.create_job(ctx.seller, ctx.price, <<>>) do
      {:ok, job_id} -> {:ok, job_id}
      {:error, reason} -> {:error, {:create_job, reason}}
    end
  end

  defp offer_job(ctx, job_id) do
    BackendInMem.publish(%{
      type: :job_offered,
      job_id: job_id,
      offering: ctx.offering,
      request: ctx.request,
      buyer: ctx.buyer
    })
  end

  defp send_payment(job_id) do
    BackendInMem.publish(%{
      type: :payment_received,
      job_id: job_id,
      payload: %{auth: "bench-payment-#{job_id}"}
    })
  end

  defp send_approval(job_id) do
    BackendInMem.publish(%{
      type: :approval_received,
      job_id: job_id,
      payload: %{ok: true}
    })
  end

  defp handler_deliver(job_id) do
    case Job.Server.deliver(job_id) do
      {:ok, :evaluation} -> :ok
      {:error, reason} -> {:error, {:deliver, reason}}
    end
  catch
    :exit, reason -> {:error, {:deliver, reason}}
  end

  # -- State polling --

  defp wait_for_state(job_id, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(job_id, target, deadline)
  end

  defp do_wait_for_state(job_id, target, deadline) do
    case current_state(job_id) do
      ^target ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(2)
          do_wait_for_state(job_id, target, deadline)
        else
          {:error, {:wait_for_state, %{job_id: job_id, target: target, observed: other}}}
        end
    end
  end

  defp current_state(job_id) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        from_store(job_id)

      pid ->
        try do
          Job.Server.current_state(pid)
        catch
          :exit, _ -> from_store(job_id)
        end
    end
  end

  defp from_store(job_id) do
    case Store.load(job_id) do
      {:ok, %{state: state}} -> state
      :error -> :no_record
    end
  end

  # -- Persistence checks --

  defp verify_persisted(job_id) do
    with {:ok, %{state: :completed, memos: memos}} <- Store.load(job_id),
         :ok <- check_memo_count(memos),
         :ok <- check_memo_types(memos),
         :ok <- check_memo_signatures(memos),
         :ok <- check_chain_memos(job_id) do
      :ok
    else
      {:error, _} = err -> err
      :error -> {:error, {:verify_persisted, :no_store_record}}
    end
  end

  defp check_memo_count(memos) when length(memos) == 4, do: :ok

  defp check_memo_count(memos) do
    {:error, {:verify_persisted, {:wrong_memo_count, length(memos)}}}
  end

  @expected_memo_types [:negotiation, :transaction, :evaluation, :completed]

  defp check_memo_types(memos) do
    actual = Enum.map(memos, & &1.type)

    if actual == @expected_memo_types do
      :ok
    else
      {:error, {:verify_persisted, {:wrong_memo_types, actual}}}
    end
  end

  defp check_memo_signatures(memos) do
    if Enum.all?(memos, &(byte_size(&1.signature) == 65)) do
      :ok
    else
      sizes = Enum.map(memos, &byte_size(&1.signature))
      {:error, {:verify_persisted, {:bad_signatures, sizes}}}
    end
  end

  defp check_chain_memos(job_id) do
    types = ChainInMem.list_memos(job_id) |> Enum.map(& &1.type)

    if types == @expected_memo_types do
      :ok
    else
      {:error, {:verify_persisted, {:chain_memos_mismatch, types}}}
    end
  end

  # -- Helpers --

  defp default_request(idx), do: %{"payload" => %{"i" => idx}}

  defp price(opts) do
    case Keyword.get(opts, :price_usdc, "0.01") do
      %Decimal{} = d -> d
      n when is_integer(n) -> Decimal.new(n)
      s when is_binary(s) -> Decimal.new(s)
    end
  end

  # Longest run of consecutive `target` values in a list of statuses.
  # Pure helper; exposed for testing.
  @doc false
  @spec longest_run([atom()], atom()) :: non_neg_integer()
  def longest_run(statuses, target) do
    {longest, _} =
      Enum.reduce(statuses, {0, 0}, fn
        ^target, {longest, current} ->
          new_current = current + 1
          {max(longest, new_current), new_current}

        _other, {longest, _current} ->
          {longest, 0}
      end)

    longest
  end
end
