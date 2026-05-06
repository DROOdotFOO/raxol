defmodule Raxol.ACP.Job.Server do
  @moduledoc """
  GenServer holding the in-flight state for a single ACP job.

  One process per active job, registered by job ID via
  `Raxol.ACP.Job.Registry`. Two layers of API:

  - **Low-level** -- `transition/4` accepts event + payload + opaque
    signature. Validates against `Raxol.ACP.Job.StateMachine`, submits
    a memo via `Raxol.ACP.ContractClient`, appends to memo history,
    emits telemetry. Caller owns signing.

  - **Orchestration** -- `accept_request/1`, `deliver/1`,
    `accept_payment/3`, `approve/3`. Active when the server is
    configured with a `:handler` (any module implementing
    `Raxol.ACP.Offering.Handler`) and a `:wallet`. The orchestration
    helpers invoke the handler at the right state, sign the result via
    `Raxol.ACP.Job.Memo`, and fire the next transition.

  Terminates with `:normal` on a transition into a terminal state
  (`:completed` or `:expired`). Combined with the transient restart in
  `Raxol.ACP.Job.Supervisor`, completed jobs do not resurrect.

  ## Telemetry

  Emits `[:raxol, :acp, :job, :transition]` on every successful
  transition with metadata
  `%{job_id, from, to, memo_type, tx_hash}`.
  """

  use GenServer

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Job.{Memo, Registry, StateMachine}

  @type memo :: %{
          type: ContractClient.memo_type(),
          payload: map(),
          signature: binary(),
          tx_hash: ContractClient.tx_hash(),
          transitioned_at: DateTime.t()
        }

  @type config :: %{
          optional(:handler) => module(),
          optional(:wallet) => module(),
          optional(:memo_opts) => keyword(),
          optional(:request) => map(),
          optional(:buyer) => String.t(),
          optional(:seller) => String.t()
        }

  @type t :: %__MODULE__{
          job_id: ContractClient.job_id(),
          state: StateMachine.state(),
          memos: [memo()],
          config: config()
        }

  defstruct [:job_id, :state, memos: [], config: %{}]

  # -- Public API --

  @doc """
  Start a Job.Server registered under the given job ID.

  ## Required options

  - `:job_id` -- the ACP job id (binary or integer).

  ## Optional state options

  - `:initial_state` -- defaults to `StateMachine.initial/0`.

  ## Optional orchestration options

  These enable the high-level helpers (`accept_request/1`, `deliver/1`,
  `accept_payment/3`, `approve/3`). Without them, only `transition/4`
  works.

  - `:handler` -- module implementing `Raxol.ACP.Offering.Handler`.
  - `:wallet` -- module implementing `Raxol.Payments.Wallet`.
  - `:memo_opts` -- keyword passed to `Raxol.ACP.Job.Memo.build_and_sign/5`
    (must include `:chain_id` and `:verifying_contract`).
  - `:request` -- the buyer's request map; passed to handler callbacks.
  - `:buyer` -- buyer address (0x string), surfaced in handler ctx.
  - `:seller` -- seller address (0x string), surfaced in handler ctx.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(job_id))
  end

  @doc """
  Drive the state machine forward by `event` with a caller-supplied
  payload and signature. Low-level entry point used by both
  orchestration helpers and tests that want to bypass the handler.
  """
  @spec transition(GenServer.server() | binary(), StateMachine.event(), map(), binary()) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def transition(server, event, payload, signature) do
    GenServer.call(resolve(server), {:transition, event, payload, signature})
  end

  @doc """
  Invoke the configured handler's `handle_request/2` callback. On
  `{:accept, response}`, sign the response and fire `:accept_request`
  (advancing to `:negotiation`). On `{:reject, reason}`, fire `:expire`.

  Requires `:handler`, `:wallet`, `:memo_opts`, and `:request` in the
  server's config.
  """
  @spec accept_request(GenServer.server() | binary()) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def accept_request(server) do
    GenServer.call(resolve(server), :accept_request)
  end

  @doc """
  Buyer-side: record the buyer's payment authorization and advance to
  `:transaction`.

  If `payload` is supplied, it becomes the memo body (the buyer's
  signed authorization). If `signature` is `nil`, the server signs the
  payload itself via the configured wallet -- useful in tests; in
  production, the buyer's signature is what matters.
  """
  @spec accept_payment(GenServer.server() | binary(), map(), binary() | nil) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def accept_payment(server, payload, signature \\ nil) do
    GenServer.call(resolve(server), {:accept_payment, payload, signature})
  end

  @doc """
  Invoke the configured handler's `handle_deliver/2` callback. On
  `{:deliver, deliverable}`, sign the deliverable and fire `:deliver`
  (advancing to `:evaluation`). On `{:error, reason}`, fire `:expire`.
  """
  @spec deliver(GenServer.server() | binary()) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def deliver(server) do
    GenServer.call(resolve(server), :deliver)
  end

  @doc """
  Buyer/evaluator-side: approve the deliverable and finalize the job.

  Same payload/signature semantics as `accept_payment/3`.
  """
  @spec approve(GenServer.server() | binary(), map(), binary() | nil) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def approve(server, payload, signature \\ nil) do
    GenServer.call(resolve(server), {:approve, payload, signature})
  end

  @doc "Return the full Job.Server struct for inspection."
  @spec get_state(GenServer.server() | binary()) :: t()
  def get_state(server), do: GenServer.call(resolve(server), :get_state)

  @doc "Return the current StateMachine state."
  @spec current_state(GenServer.server() | binary()) :: StateMachine.state()
  def current_state(server), do: GenServer.call(resolve(server), :current_state)

  @doc "Return the memo history in submission order."
  @spec memos(GenServer.server() | binary()) :: [memo()]
  def memos(server), do: GenServer.call(resolve(server), :memos)

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: name
  defp resolve(job_id) when is_binary(job_id), do: Registry.via(job_id)
  defp resolve({:via, _, _} = via), do: via

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    config =
      opts
      |> Keyword.take([:handler, :wallet, :memo_opts, :request, :buyer, :seller])
      |> Map.new()

    state = %__MODULE__{
      job_id: Keyword.fetch!(opts, :job_id),
      state: Keyword.get(opts, :initial_state, StateMachine.initial()),
      memos: [],
      config: config
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:transition, event, payload, signature}, _from, state) do
    do_transition(state, event, payload, signature)
  end

  def handle_call(:accept_request, _from, state) do
    with {:ok, %{handler: handler, request: request}} <- need(state.config, [:handler, :request]) do
      case handler.handle_request(request, ctx(state)) do
        {:accept, response} ->
          sign_and_transition(state, :accept_request, response)

        {:reject, reason} ->
          sign_and_transition(state, :expire, %{reason: inspect(reason)})
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:accept_payment, payload, signature}, _from, state) do
    sign_or_use(state, :accept_payment, payload, signature)
  end

  def handle_call(:deliver, _from, state) do
    with {:ok, %{handler: handler, request: request}} <- need(state.config, [:handler, :request]) do
      case handler.handle_deliver(request, ctx(state)) do
        {:deliver, deliverable} ->
          sign_and_transition(state, :deliver, deliverable)

        {:error, reason} ->
          sign_and_transition(state, :expire, %{reason: inspect(reason)})
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:approve, payload, signature}, _from, state) do
    sign_or_use(state, :approve, payload, signature)
  end

  def handle_call(:get_state, _from, state), do: {:reply, state, state}
  def handle_call(:current_state, _from, state), do: {:reply, state.state, state}
  def handle_call(:memos, _from, state), do: {:reply, state.memos, state}

  # -- Private --

  defp do_transition(state, event, payload, signature) do
    with {:ok, new_state} <- StateMachine.next(state.state, event),
         memo_type = new_state,
         {:ok, tx_hash} <-
           ContractClient.submit_memo(state.job_id, memo_type, payload, signature) do
      memo = %{
        type: memo_type,
        payload: payload,
        signature: signature,
        tx_hash: tx_hash,
        transitioned_at: DateTime.utc_now()
      }

      :telemetry.execute(
        [:raxol, :acp, :job, :transition],
        %{},
        %{
          job_id: state.job_id,
          from: state.state,
          to: new_state,
          memo_type: memo_type,
          tx_hash: tx_hash
        }
      )

      new_full_state = %{state | state: new_state, memos: state.memos ++ [memo]}

      if StateMachine.terminal?(new_state) do
        {:stop, :normal, {:ok, new_state}, new_full_state}
      else
        {:reply, {:ok, new_state}, new_full_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Caller can override the signature; otherwise we sign the payload
  # ourselves with the configured wallet. Both paths require the
  # state machine to accept the event from the current state.
  defp sign_or_use(state, event, payload, nil), do: sign_and_transition(state, event, payload)

  defp sign_or_use(state, event, payload, signature) when is_binary(signature) do
    do_transition(state, event, payload, signature)
  end

  defp sign_and_transition(state, event, payload) do
    with {:ok, %{wallet: wallet, memo_opts: memo_opts}} <-
           need(state.config, [:wallet, :memo_opts]),
         {:ok, new_state} <- StateMachine.next(state.state, event),
         payload_hash <- payload_hash(payload),
         {:ok, %{signature: signature}} <-
           Memo.build_and_sign(state.job_id, new_state, payload_hash, wallet, memo_opts) do
      do_transition(state, event, payload, signature)
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  defp ctx(state) do
    %{
      job_id: state.job_id,
      buyer: Map.get(state.config, :buyer),
      seller: Map.get(state.config, :seller),
      state: state.state
    }
  end

  defp need(config, keys) do
    case Enum.reject(keys, &Map.has_key?(config, &1)) do
      [] -> {:ok, Map.take(config, keys)}
      missing -> {:error, {:config_missing, missing}}
    end
  end

  # Canonicalize the payload as keccak256 of its JSON encoding. This is
  # a v0.1 placeholder -- the real ACP contract may require a different
  # canonicalization. The Node SDK parity test (planned in the v0.1
  # milestone) is the canonical correctness check.
  defp payload_hash(payload) when is_map(payload) do
    "0x" <>
      (payload
       |> Jason.encode!()
       |> ExKeccak.hash_256()
       |> Base.encode16(case: :lower))
  end
end
