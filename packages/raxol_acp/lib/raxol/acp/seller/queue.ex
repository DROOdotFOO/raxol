defmodule Raxol.ACP.Seller.Queue do
  @moduledoc """
  Routes ACP backend events to job processes.

  The Queue is a single GenServer that owns the dispatch policy for the
  seller. Backend events arrive via `dispatch/1` (called by
  `Raxol.ACP.Seller.Runtime` after it receives an `{:acp_event, event}`
  message). The Queue translates each event into the right
  `Raxol.ACP.Job.Server` interaction.

  ## Configuration

      config :raxol_acp,
        seller_address: "0x...",          # 0x string, surfaced in handler ctx
        seller_max_active_jobs: 100        # backpressure cap (default 100)

  Read from `Application` on every dispatch (not cached) so the seller
  address and cap can be rotated without restarting the supervision tree.

  ## Backpressure

  A `:job_offered` starts a supervised `Job.Server`, so an unbounded stream of
  offers is an unbounded stream of processes. The Queue caps concurrent jobs at
  `:seller_max_active_jobs`: once `Job.Supervisor.active_count/0` reaches the cap,
  further offers are dropped with reason `:at_capacity` (the seller is simply
  full) rather than started. Events for jobs already in flight are never capped.
  Because an over-cap offer is O(1) to reject, a flood drains the mailbox fast
  instead of exhausting memory.

  ## Events handled

  - `:job_offered` -- start a `Job.Server` under `Job.Supervisor`, then
    call `Job.Server.accept_request/1`. The handler decides accept vs.
    reject; the Queue does not policy-gate.
  - `:payment_received` -- look up the running `Job.Server` and call
    `accept_payment/3`. The Queue does NOT auto-deliver afterwards;
    handlers control delivery timing per design choice (sync handlers
    can call `deliver/1` from `handle_request/2`'s caller; async
    handlers signal via their own mechanism).
  - `:approval_received` -- call `Job.Server.approve/3`.
  - `:job_expired` -- transition via `Job.Server.transition/4` with
    `:expire`. No-op if the server is already terminal.

  Unknown event types are logged and dropped. Events for unknown
  job_ids (no offering registered, no running job) emit telemetry and
  drop.

  ## Telemetry

  - `[:raxol, :acp, :seller, :queue, :dispatched]` -- successful dispatch.
    Metadata: `%{type, job_id, offering}`.
  - `[:raxol, :acp, :seller, :queue, :dropped]` -- event dropped.
    Metadata: `%{type, job_id, reason}` where reason is one of
    `:offering_not_registered`, `:job_not_running`, `:start_failed`,
    `:at_capacity`, `:malformed`, `:unknown_event`, or
    `{:handler_error, reason}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.Job
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch a backend event. Asynchronous: returns `:ok` immediately and
  the Queue processes the event in its mailbox.

  Accepts any map: a malformed event (wrong shape, missing keys) is dropped
  with telemetry inside the Queue rather than crashing the caller, so a
  misbehaving backend cannot take the dispatch path down.
  """
  @spec dispatch(map()) :: :ok
  def dispatch(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:dispatch, event})
  end

  @doc "Inspect the Queue's currently resolved defaults from Application config."
  @spec defaults() :: %{seller_address: String.t() | nil}
  def defaults, do: read_defaults()

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts), do: {:ok, %{}}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:dispatch, event}, state) do
    handle_event(event, read_defaults())
    {:noreply, state}
  end

  defp read_defaults do
    %{
      seller_address: Application.get_env(:raxol_acp, :seller_address),
      max_active_jobs: Application.get_env(:raxol_acp, :seller_max_active_jobs, 100)
    }
  end

  # -- Event handlers --
  #
  # Each clause requires the keys it needs in the head, so a malformed backend
  # event (missing job_id / offering / payload) drops with telemetry instead of
  # crashing the Queue. Downstream Job.Server results are checked -- a failed
  # transition drops with `{:handler_error, reason}` rather than being reported
  # as a successful dispatch.

  @known_types [:job_offered, :payment_received, :approval_received, :job_expired]

  defp handle_event(%{type: :job_offered, job_id: job_id, offering: name} = event, state) do
    with {:ok, spec} <- lookup_offering(name, job_id),
         :ok <- within_capacity(job_id, name, state),
         {:ok, _pid} <- start_job(event, spec, state) do
      dispatch_result(Job.Server.accept_request(job_id), %{
        type: :job_offered,
        job_id: job_id,
        offering: name
      })
    end
  end

  defp handle_event(%{type: :payment_received, job_id: job_id, payload: payload} = event, _state) do
    signature = Map.get(event, :signature)

    route(:payment_received, job_id, fn ->
      Job.Server.accept_payment(job_id, payload, signature)
    end)
  end

  defp handle_event(%{type: :approval_received, job_id: job_id, payload: payload} = event, _state) do
    signature = Map.get(event, :signature)
    route(:approval_received, job_id, fn -> Job.Server.approve(job_id, payload, signature) end)
  end

  defp handle_event(%{type: :job_expired, job_id: job_id} = event, _state) do
    reason = Map.get(event, :reason, "expired")

    route(:job_expired, job_id, fn ->
      Job.Server.transition(job_id, :expire, %{reason: inspect(reason)}, <<>>)
    end)
  end

  # A known type that reaches here is missing a required field -- malformed, not
  # an unrecognised type.
  defp handle_event(%{type: type} = event, _state) when type in @known_types do
    emit(:dropped, %{type: type, job_id: Map.get(event, :job_id), reason: :malformed})
  end

  defp handle_event(%{type: type} = event, _state) do
    emit(:dropped, %{type: type, job_id: Map.get(event, :job_id), reason: :unknown_event})
  end

  defp handle_event(event, _state) do
    emit(:dropped, %{
      type: Map.get(event, :type),
      job_id: Map.get(event, :job_id),
      reason: :malformed
    })
  end

  # -- Helpers --

  # Route an event to a running Job.Server, checking the result so a failed
  # transition is reported as a drop, not a dispatch.
  defp route(type, job_id, fun) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        emit(:dropped, %{type: type, job_id: job_id, reason: :job_not_running})

      _pid ->
        dispatch_result(fun.(), %{type: type, job_id: job_id})
    end
  end

  defp dispatch_result({:error, reason}, meta),
    do: emit(:dropped, Map.put(meta, :reason, {:handler_error, reason}))

  defp dispatch_result(_ok, meta), do: emit(:dispatched, meta)

  # Backpressure: cap the number of concurrent job processes. When the seller is
  # already at `:seller_max_active_jobs` (default 100), a fresh :job_offered is
  # rejected rather than started, so a flood of offers from a misbehaving or
  # compromised backend cannot exhaust processes/memory. Events for jobs already
  # in flight (payment/approval/expiry) are never capped.
  defp within_capacity(job_id, name, %{max_active_jobs: max}) do
    if Job.Supervisor.active_count() < max do
      :ok
    else
      emit(:dropped, %{type: :job_offered, job_id: job_id, offering: name, reason: :at_capacity})
      :error
    end
  end

  defp lookup_offering(name, job_id) do
    case OfferingRegistry.lookup(name) do
      {:ok, spec} ->
        {:ok, spec}

      :error ->
        emit(:dropped, %{
          type: :job_offered,
          job_id: job_id,
          offering: name,
          reason: :offering_not_registered
        })

        :error
    end
  end

  defp start_job(event, spec, state) do
    %{job_id: job_id, request: request} = event
    buyer = Map.get(event, :buyer)

    opts = [
      job_id: job_id,
      handler: spec.handler,
      request: request,
      buyer: buyer,
      seller: state.seller_address
    ]

    case Job.Supervisor.start_job(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        emit(:dropped, %{
          type: :job_offered,
          job_id: job_id,
          offering: spec.name,
          reason: {:start_failed, reason}
        })

        :error
    end
  end

  defp emit(suffix, metadata) do
    :telemetry.execute([:raxol, :acp, :seller, :queue, suffix], %{}, metadata)
  end
end
