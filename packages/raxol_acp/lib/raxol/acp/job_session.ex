defmodule Raxol.ACP.JobSession do
  @moduledoc """
  Event-driven session for a single ACP v2 job.

  Replaces v1's `Raxol.ACP.Job.Server` for the v2 model. One GenServer
  per active job, registered under `Raxol.ACP.JobSession.Registry` by
  `{chain_id, job_id}`. The session tracks role-aware status, maintains
  a chronological entry log (events + messages), and notifies
  subscribers via process messages of the shape
  `{Raxol.ACP.JobSession, {chain_id, job_id}, entry}`.

  ## Lifecycle

      {:ok, _pid} = Raxol.ACP.JobSession.start_link(
        chain_id: 8453,
        job_id: "job-42",
        role: :provider
      )

      :ok = Raxol.ACP.JobSession.subscribe(server)

      {:ok, :budget_set} = Raxol.ACP.JobSession.set_budget(server, asset_token)
      # ... time passes; client funds ...
      {:ok, :submitted} = Raxol.ACP.JobSession.submit(server, deliverable)
      # evaluator's process:
      {:ok, :completed} = Raxol.ACP.JobSession.complete(server, "looks good")

  Terminal statuses (`:completed`, `:rejected`, `:expired`) stop the
  GenServer with `:normal` so transient supervisors do not resurrect
  finished jobs.

  ## Role gating

  Actions are gated through `Raxol.ACP.JobSession.Tools.allowed?/3`.
  Calling `complete/2` as a `:client` returns
  `{:error, {:not_allowed_for_role, :client, :complete, status}}` instead
  of executing.

  ## On-chain side

  This module is intentionally pure -- it records intent and notifies
  listeners. Actually submitting hook calls to ACP v2's
  `FundTransferHook` etc. lives behind `Raxol.ACP.ProviderAdapter`:
  transitions here are local, and the adapter wires them to JSON-RPC.

  ## Entries

  The session stores a list of `entry()` maps in submission order:

      %{kind: :system, event: :budget_set, payload: %{budget: ...}, at: dt}
      %{kind: :message, from: role, content: "...", content_type: "text", at: dt}
  """

  use GenServer

  alias Raxol.ACP.AssetToken
  alias Raxol.ACP.JobSession.{Registry, Status, Tools}

  @type role :: :client | :provider | :evaluator
  @type job_key :: {pos_integer(), String.t() | non_neg_integer()}

  @type entry :: %{
          required(:kind) => :system | :message,
          required(:at) => DateTime.t(),
          optional(:event) => atom(),
          optional(:payload) => map(),
          optional(:from) => role(),
          optional(:content) => String.t(),
          optional(:content_type) => String.t()
        }

  @type t :: %__MODULE__{
          job_id: String.t() | non_neg_integer(),
          chain_id: pos_integer(),
          role: role(),
          status: Status.t(),
          entries: [entry()],
          subscribers: MapSet.t(pid()),
          description: String.t() | nil
        }

  defstruct [
    :job_id,
    :chain_id,
    :role,
    :status,
    entries: [],
    subscribers: MapSet.new(),
    description: nil
  ]

  # -- Public API --

  @doc """
  Start a JobSession registered under `Registry`.

  ## Required options

  - `:chain_id` -- the chain on which the ACP v2 job lives (e.g. 8453).
  - `:job_id` -- the v2 job id (string or integer).
  - `:role` -- `:client`, `:provider`, or `:evaluator`.

  ## Optional

  - `:initial_status` (default `:open`)
  - `:description` -- short human-readable label for the job, mirrored
    on `session.job.description` in acp-node-v2.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    chain_id = Keyword.fetch!(opts, :chain_id)
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.via({chain_id, job_id}))
  end

  @doc "Subscribe the calling process to entry notifications for `server`."
  @spec subscribe(GenServer.server() | job_key()) :: :ok
  def subscribe(server), do: GenServer.call(resolve(server), {:subscribe, self()})

  @doc "Unsubscribe the calling process."
  @spec unsubscribe(GenServer.server() | job_key()) :: :ok
  def unsubscribe(server), do: GenServer.call(resolve(server), {:unsubscribe, self()})

  @doc "Append a chat message to the session entry log. Always allowed."
  @spec send_message(GenServer.server() | job_key(), String.t(), String.t()) :: :ok
  def send_message(server, content, content_type \\ "text") do
    GenServer.call(resolve(server), {:send_message, content, content_type})
  end

  @doc """
  Provider action: set or update the budget (open -> budget_set, or
  re-budget within budget_set).
  """
  @spec set_budget(GenServer.server() | job_key(), AssetToken.t()) ::
          {:ok, Status.t()} | {:error, term()}
  def set_budget(server, %AssetToken{} = budget) do
    transition(server, :set_budget, %{budget: budget})
  end

  @doc """
  Provider action: set budget and signal the fund-transfer flow. The
  client funds `budget + transfer_amount` USDC; on submit the
  FundTransferHook routes `transfer_amount` to `destination` and the
  rest (the service fee) stays with the provider.
  """
  @spec set_budget_with_fund_request(
          GenServer.server() | job_key(),
          AssetToken.t(),
          AssetToken.t(),
          String.t()
        ) :: {:ok, Status.t()} | {:error, term()}
  def set_budget_with_fund_request(
        server,
        %AssetToken{} = budget,
        %AssetToken{} = transfer_amount,
        destination
      )
      when is_binary(destination) do
    transition(server, :set_budget_with_fund_request, %{
      budget: budget,
      transfer_amount: transfer_amount,
      destination: destination
    })
  end

  @doc "Client action: fund the escrow (budget_set -> funded)."
  @spec fund(GenServer.server() | job_key(), AssetToken.t() | nil) ::
          {:ok, Status.t()} | {:error, term()}
  def fund(server, transfer_amount \\ nil) do
    payload = if transfer_amount, do: %{transfer_amount: transfer_amount}, else: %{}
    transition(server, :fund, payload)
  end

  @doc "Provider action: submit a deliverable (funded -> submitted)."
  @spec submit(GenServer.server() | job_key(), term(), AssetToken.t() | nil) ::
          {:ok, Status.t()} | {:error, term()}
  def submit(server, deliverable, transfer_amount \\ nil) do
    payload =
      %{deliverable: deliverable}
      |> maybe_put(:transfer_amount, transfer_amount)

    transition(server, :submit, payload)
  end

  @doc "Evaluator action: approve the deliverable (submitted -> completed)."
  @spec complete(GenServer.server() | job_key(), String.t()) ::
          {:ok, Status.t()} | {:error, term()}
  def complete(server, reason) when is_binary(reason) do
    transition(server, :complete, %{reason: reason})
  end

  @doc "Evaluator action: reject the deliverable (submitted -> rejected)."
  @spec reject(GenServer.server() | job_key(), String.t()) ::
          {:ok, Status.t()} | {:error, term()}
  def reject(server, reason) when is_binary(reason) do
    transition(server, :reject, %{reason: reason})
  end

  @doc "Expire the job from any non-terminal status."
  @spec expire(GenServer.server() | job_key(), String.t()) ::
          {:ok, Status.t()} | {:error, term()}
  def expire(server, reason) when is_binary(reason) do
    transition(server, :expire, %{reason: reason})
  end

  @doc """
  Apply an OBSERVED status directly, bypassing BOTH role gating and
  adjacency validation.

  Unlike the role-gated action API (`set_budget`/`fund`/`submit`/...), this
  does not perform a transition -- it mirrors one that already settled
  elsewhere (an on-chain or SSE event, decoded by the caller). The observed
  event is authoritative: an Agent connecting mid-stream may jump straight
  to the current status, so no adjacency check applies. Records a `:system`
  entry, notifies subscribers, emits telemetry, and stops the session if
  `status` is terminal. Rejects an unknown status atom.
  """
  @spec apply_event(GenServer.server() | job_key(), Status.t(), map()) ::
          {:ok, Status.t()} | {:error, {:unknown_status, atom()}}
  def apply_event(server, status, payload \\ %{}) when is_atom(status) and is_map(payload) do
    GenServer.call(resolve(server), {:apply_event, status, payload})
  end

  # -- Read API --

  @doc "Current status."
  @spec status(GenServer.server() | job_key()) :: Status.t()
  def status(server), do: GenServer.call(resolve(server), :status)

  @doc "Role this session was started with."
  @spec role(GenServer.server() | job_key()) :: role()
  def role(server), do: GenServer.call(resolve(server), :role)

  @doc "Full chronological entry log."
  @spec entries(GenServer.server() | job_key()) :: [entry()]
  def entries(server), do: GenServer.call(resolve(server), :entries)

  @doc "Action atoms the LLM tool loop may call right now."
  @spec available_tools(GenServer.server() | job_key()) :: [Tools.tool()]
  def available_tools(server), do: GenServer.call(resolve(server), :available_tools)

  @doc "Full struct (for tests / inspection)."
  @spec get_state(GenServer.server() | job_key()) :: t()
  def get_state(server), do: GenServer.call(resolve(server), :get_state)

  # -- Internal --

  defp transition(server, action, payload) do
    GenServer.call(resolve(server), {:transition, action, payload})
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: name
  defp resolve({chain_id, job_id}) when is_integer(chain_id), do: Registry.via({chain_id, job_id})
  defp resolve({:via, _, _} = via), do: via

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      job_id: Keyword.fetch!(opts, :job_id),
      chain_id: Keyword.fetch!(opts, :chain_id),
      role: Keyword.fetch!(opts, :role),
      status: Keyword.get(opts, :initial_status, Status.initial()),
      description: Keyword.get(opts, :description)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call({:send_message, content, content_type}, _from, state) do
    entry = %{
      kind: :message,
      from: state.role,
      content: content,
      content_type: content_type,
      at: DateTime.utc_now()
    }

    state = %{state | entries: state.entries ++ [entry]}
    broadcast(state, entry)

    {:reply, :ok, state}
  end

  def handle_call({:transition, action, payload}, _from, state) do
    with :ok <- check_role(state.role, state.status, action),
         {:ok, next_status} <- resolve_next_status(action),
         :ok <- Status.validate(state.status, next_status) do
      commit_status(state, next_status, payload, action)
    else
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call({:apply_event, next_status, payload}, _from, state) do
    if next_status in Status.all() do
      commit_status(state, next_status, payload, :apply_event)
    else
      {:reply, {:error, {:unknown_status, next_status}}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:role, _from, state), do: {:reply, state.role, state}
  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call(:available_tools, _from, state),
    do: {:reply, Tools.available(state.role, state.status), state}

  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # -- Helpers --

  defp check_role(role, status, action) do
    # :expire bypasses role gating (timer or supervisor invokes it)
    if action == :expire do
      :ok
    else
      tool = action_to_tool(action)

      if Tools.allowed?(role, status, tool) do
        :ok
      else
        {:error, {:not_allowed_for_role, role, action, status}}
      end
    end
  end

  defp action_to_tool(:set_budget), do: :set_budget
  defp action_to_tool(:set_budget_with_fund_request), do: :set_budget
  defp action_to_tool(:set_budget_with_subscription), do: :set_budget
  defp action_to_tool(:fund), do: :fund
  defp action_to_tool(:submit), do: :submit
  defp action_to_tool(:complete), do: :complete
  defp action_to_tool(:reject), do: :reject
  # No `:expire` clause: `check_role/3` handles `:expire` before it ever reaches
  # here (expiry bypasses role gating), so the clause would be dead code.

  defp resolve_next_status(action) do
    case Status.target_status(action) do
      nil -> {:error, {:unknown_action, action}}
      status -> {:ok, status}
    end
  end

  # Record the status change as a :system entry, notify subscribers, emit
  # telemetry, and stop the process if the new status is terminal. Shared by
  # the role-gated action path (`:transition`) and the observed-event path
  # (`:apply_event`).
  defp commit_status(state, next_status, payload, action) do
    from_status = state.status

    entry = %{
      kind: :system,
      event: next_status,
      payload: payload,
      at: DateTime.utc_now()
    }

    state = %{state | status: next_status, entries: state.entries ++ [entry]}
    broadcast(state, entry)
    emit_telemetry(state, action, from_status, next_status)

    if Status.terminal?(next_status) do
      {:stop, :normal, {:ok, next_status}, state}
    else
      {:reply, {:ok, next_status}, state}
    end
  end

  defp broadcast(%{subscribers: subs} = state, entry) do
    key = {state.chain_id, state.job_id}

    for pid <- subs do
      send(pid, {__MODULE__, key, entry})
    end
  end

  defp emit_telemetry(state, action, from_status, next_status) do
    :telemetry.execute(
      [:raxol, :acp, :job_session, :transition],
      %{},
      %{
        chain_id: state.chain_id,
        job_id: state.job_id,
        role: state.role,
        action: action,
        from: from_status,
        to: next_status
      }
    )
  end
end
