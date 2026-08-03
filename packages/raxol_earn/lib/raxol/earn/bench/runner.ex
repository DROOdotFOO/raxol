defmodule Raxol.Earn.Bench.Runner do
  @moduledoc """
  Drives N synthetic ACP jobs through the in-memory seller stack and
  reports outcomes.

  ## Method

  Each job traverses the full v2 ACP lifecycle, driven entirely by
  backend events through `Raxol.Earn.Seller.Queue` ->
  `Raxol.Earn.JobSession.Provider`:

      InMemory.publish(:job_offered)        # Queue starts a provider
                                            # JobSession, sets the budget
                                            # on-chain -> :budget_set
      InMemory.publish(:payment_received)   # Queue mirrors :funded and
                                            # auto-delivers -> :submitted
      InMemory.publish(:approval_received)  # Queue mirrors :completed
                                            # (terminal; session stops)

  Unlike v1, the Queue auto-delivers on `:payment_received` -- there is
  no out-of-band `deliver/1` step.

  ## On-chain writes

  The Queue must be able to write hook calls on-chain. The bench seeds a
  `Raxol.Earn.ProviderAdapter.Mock` into `:seller_provider_adapter`: the
  Mock stands in for the bundler/RPC so a bench run never touches a real
  chain. This is the sanctioned use of a fake -- the bench is a local
  validation harness, not a live gate.

  ## Outcomes

  A job is **success** iff it reaches `:completed` (observed as `:gone`,
  the terminal session having stopped) inside `:job_timeout`, having
  passed through `:budget_set` and `:submitted` along the way.

  Otherwise the job is **failure** with a tagged reason for the summary.

  ## Result shape

      %Raxol.Earn.Bench.Runner.Summary{
        jobs: [%Raxol.Earn.Bench.Runner.Outcome{...}],   # one per job, in order
        successes: 9,
        failures: 1,
        longest_consecutive_successes: 7,
        gate: 3,
        gate_met?: true,
        elapsed_ms: 312
      }

  ## Caller responsibility

  The caller (the Mix task) must have:

  - Set `:seller_enabled` to `true`
  - Set `:seller_backend` to `Raxol.Earn.Seller.Backend.InMemory`
  - Started the application so the supervisor tree is live
  - Registered an offering handler (the runner does NOT register one
    itself -- pass the offering name and let the caller register
    `Raxol.Earn.Bench.Offering` or any compatible echo handler)

  The runner configures the seller Queue's on-chain plumbing
  (`:seller_provider_adapter`, `:seller_chain_id`,
  `:seller_acp_core_address`, `:seller_address`) itself on every run.

  This separation keeps the Runner a pure driver and lets tests mix
  in different offerings.
  """

  alias Raxol.Earn.{Chain, JobSession, ProviderAdapter}
  alias Raxol.Earn.Seller.Backend.InMemory, as: BackendInMem

  # The chain the bench jobs live on. Must match the `:seller_chain_id`
  # the runner configures so JobSession lookups resolve.
  @chain_id 8453

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
  - `:seller` -- 0x-prefixed seller address surfaced in handler ctx.
    Default a synthetic constant.
  - `:buyer` -- 0x-prefixed buyer address. Default a synthetic
    constant.
  - `:request_builder` -- 1-arity fn that takes the job index (1..N)
    and returns the request map. Default returns `%{"payload" =>
    %{"i" => idx}}`.
  - `:job_timeout_ms` -- how long to wait for a job to reach
    `:completed`. Default `#{@default_job_timeout_ms}`.
  - `:reset?` -- whether to terminate any leftover JobSessions before
    starting. Default `true`.
  """
  @spec run(keyword()) :: Summary.t()
  def run(opts \\ []) do
    jobs = Keyword.get(opts, :jobs, @default_jobs)
    gate = Keyword.get(opts, :gate, @default_gate)
    offering = Keyword.fetch!(opts, :offering)
    seller = Keyword.get(opts, :seller, @default_seller_address)
    buyer = Keyword.get(opts, :buyer, @default_buyer_address)
    builder = Keyword.get(opts, :request_builder, &default_request/1)
    timeout = Keyword.get(opts, :job_timeout_ms, @default_job_timeout_ms)

    configure_seller(seller)

    if Keyword.get(opts, :reset?, true) do
      terminate_sessions()
    end

    started_at = System.monotonic_time(:millisecond)

    outcomes =
      for idx <- 1..jobs do
        run_one(%{
          idx: idx,
          offering: offering,
          buyer: buyer,
          request: builder.(idx),
          timeout_ms: timeout,
          job_id: "bench-#{idx}-#{System.unique_integer([:positive])}"
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

  # -- Seller configuration --

  # Seed the seller Queue's on-chain plumbing. A fresh Mock adapter per run
  # keeps recorded calls from accumulating across runs; the chain id must
  # match the one the runner watches for JobSession lookups.
  defp configure_seller(seller) do
    Application.put_env(:raxol_earn, :seller_provider_adapter, ProviderAdapter.Mock.new())
    Application.put_env(:raxol_earn, :seller_chain_id, @chain_id)
    Application.put_env(:raxol_earn, :seller_acp_core_address, Chain.mainnet().acp_core_address)
    Application.put_env(:raxol_earn, :seller_address, seller)
    :ok
  end

  defp terminate_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  # -- Per-job driver --

  defp run_one(ctx) do
    started_at = System.monotonic_time(:millisecond)
    job_id = ctx.job_id

    result =
      with :ok <- offer_job(ctx, job_id),
           :ok <- wait_status(job_id, :budget_set, ctx.timeout_ms),
           :ok <- send_payment(job_id),
           :ok <- wait_status(job_id, :submitted, ctx.timeout_ms),
           :ok <- send_approval(job_id),
           :ok <- wait_status(job_id, :gone, ctx.timeout_ms) do
        :ok
      end

    elapsed = System.monotonic_time(:millisecond) - started_at

    case result do
      :ok ->
        %Outcome{job_id: job_id, status: :success, elapsed_ms: elapsed}

      {:error, reason} ->
        %Outcome{job_id: job_id, status: :failure, elapsed_ms: elapsed, reason: reason}
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

  # -- Status polling --

  defp wait_status(job_id, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_status(job_id, target, deadline)
  end

  defp do_wait_status(job_id, target, deadline) do
    case status(job_id) do
      ^target ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(2)
          do_wait_status(job_id, target, deadline)
        else
          {:error, {:wait_status, %{job_id: job_id, target: target, observed: other}}}
        end
    end
  end

  # `:gone` when the session has stopped (terminal status) or never started.
  defp status(job_id) do
    case JobSession.Registry.whereis({@chain_id, job_id}) do
      :undefined ->
        :gone

      pid ->
        try do
          JobSession.status(pid)
        catch
          :exit, _ -> :gone
        end
    end
  end

  # -- Helpers --

  defp default_request(idx), do: %{"payload" => %{"i" => idx}}

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
