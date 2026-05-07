defmodule Raxol.ACP.Seller.Queue do
  @moduledoc """
  Routes ACP backend events to job processes.

  The Queue is a single GenServer that owns the dispatch policy for the
  seller. Backend events arrive via `dispatch/1` (called by
  `Raxol.ACP.Seller.Runtime` after it receives an `{:acp_event, event}`
  message). The Queue translates each event into the right
  `Raxol.ACP.Job.Server` interaction.

  ## Wallet + memo_opts resolution (hybrid)

  Per-offering overrides win, with the Queue's defaults (read from
  `Application` config at start) as the fallback. Concretely, on every
  `:job_offered` dispatch:

      wallet    = spec.wallet    || queue_default_wallet
      memo_opts = spec.memo_opts || queue_default_memo_opts

  Most sellers run one wallet for everything and leave the spec fields
  `nil`. An offering that needs to settle on a different chain sets
  both fields on its `use Raxol.ACP.Offering` line.

  ## Configuration (read per dispatch)

      config :raxol_acp,
        seller_wallet: MyApp.Wallet,                  # Raxol.Payments.Wallet impl
        seller_memo_opts: [chain_id: 8453,
                           verifying_contract: "0x..."],
        seller_address: "0x..."                       # 0x string

  Defaults are read from `Application` on every dispatch, not cached at
  start. This keeps the Queue cheap to re-key at runtime (e.g. rotate
  the seller wallet without restarting the supervision tree).

  ## Events handled

  - `:job_offered` -- start a `Job.Server` under `Job.Supervisor` with
    the resolved wallet/memo_opts/address, then call
    `Job.Server.accept_request/1`. The handler decides accept vs.
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
    `:unknown_event`, `:wallet_unconfigured`.
  """

  use GenServer

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
  """
  @spec dispatch(map()) :: :ok
  def dispatch(%{type: type} = event) when is_atom(type) do
    GenServer.cast(__MODULE__, {:dispatch, event})
  end

  @doc "Inspect the Queue's currently resolved defaults from Application config."
  @spec defaults() :: %{
          wallet: module() | nil,
          memo_opts: keyword() | nil,
          seller_address: String.t() | nil
        }
  def defaults, do: read_defaults()

  # -- GenServer callbacks --

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:dispatch, event}, state) do
    handle_event(event, read_defaults())
    {:noreply, state}
  end

  defp read_defaults do
    %{
      wallet: Application.get_env(:raxol_acp, :seller_wallet),
      memo_opts: Application.get_env(:raxol_acp, :seller_memo_opts),
      seller_address: Application.get_env(:raxol_acp, :seller_address)
    }
  end

  # -- Event handlers --

  defp handle_event(%{type: :job_offered} = event, state) do
    %{job_id: job_id, offering: name} = event

    with {:ok, spec} <- lookup_offering(name, job_id),
         {:ok, wallet, memo_opts} <- resolve_signing(spec, state, job_id),
         {:ok, _pid} <- start_job(event, spec, wallet, memo_opts, state) do
      _ = Job.Server.accept_request(job_id)
      emit(:dispatched, %{type: :job_offered, job_id: job_id, offering: name})
    end
  end

  defp handle_event(%{type: :payment_received} = event, _state) do
    %{job_id: job_id, payload: payload} = event
    signature = Map.get(event, :signature)

    case Job.Registry.whereis(job_id) do
      :undefined ->
        emit(:dropped, %{type: :payment_received, job_id: job_id, reason: :job_not_running})

      _pid ->
        _ = Job.Server.accept_payment(job_id, payload, signature)
        emit(:dispatched, %{type: :payment_received, job_id: job_id})
    end
  end

  defp handle_event(%{type: :approval_received} = event, _state) do
    %{job_id: job_id, payload: payload} = event
    signature = Map.get(event, :signature)

    case Job.Registry.whereis(job_id) do
      :undefined ->
        emit(:dropped, %{type: :approval_received, job_id: job_id, reason: :job_not_running})

      _pid ->
        _ = Job.Server.approve(job_id, payload, signature)
        emit(:dispatched, %{type: :approval_received, job_id: job_id})
    end
  end

  defp handle_event(%{type: :job_expired} = event, _state) do
    %{job_id: job_id} = event
    reason = Map.get(event, :reason, "expired")

    case Job.Registry.whereis(job_id) do
      :undefined ->
        emit(:dropped, %{type: :job_expired, job_id: job_id, reason: :job_not_running})

      _pid ->
        _ = Job.Server.transition(job_id, :expire, %{reason: inspect(reason)}, <<>>)
        emit(:dispatched, %{type: :job_expired, job_id: job_id})
    end
  end

  defp handle_event(%{type: type} = event, _state) do
    emit(:dropped, %{type: type, job_id: Map.get(event, :job_id), reason: :unknown_event})
  end

  # -- Helpers --

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

  defp resolve_signing(spec, state, job_id) do
    wallet = spec.wallet || state.wallet
    memo_opts = spec.memo_opts || state.memo_opts

    if wallet do
      {:ok, wallet, memo_opts}
    else
      emit(:dropped, %{type: :job_offered, job_id: job_id, reason: :wallet_unconfigured})

      :error
    end
  end

  defp start_job(event, spec, wallet, memo_opts, state) do
    %{job_id: job_id, request: request} = event
    buyer = Map.get(event, :buyer)

    opts = [
      job_id: job_id,
      handler: spec.handler,
      wallet: wallet,
      memo_opts: memo_opts || [],
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
