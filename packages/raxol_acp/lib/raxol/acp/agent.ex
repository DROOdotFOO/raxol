defmodule Raxol.ACP.Agent do
  @moduledoc """
  Orchestrator for a v2 raxol_acp agent.

  Mirrors `AcpAgent` in `acp-node-v2`. Owns three injected dependencies:

  - **Provider** (`Raxol.ACP.ProviderAdapter`) -- the chain-facing client
    that submits on-chain hook calls. Any module/struct implementing the
    behaviour is accepted.
  - **Transport** (`Raxol.ACP.Transport`) -- the SSE chat stream + REST
    messaging. `Raxol.ACP.Transport.Mock` for tests; `Raxol.ACP.Transport.SSE`
    for production.
  - **JobApi** (`Raxol.ACP.JobApi`) -- the REST discovery API.

  ## Lifecycle

      {:ok, agent} = Raxol.ACP.Agent.start_link(
        provider: my_provider,
        transport: Raxol.ACP.Transport.SSE.new(network: :mainnet),
        api: Raxol.ACP.JobApi.HTTP.new(network: :mainnet),
        wallet_address: "0x...",
        supported_chain_ids: [8453]
      )

      :ok = Raxol.ACP.Agent.subscribe(agent)
      :ok = Raxol.ACP.Agent.start_stream(agent)

      # Receive {:entry, session_pid, %{kind: :system, ...}} messages.

  ## Event routing

  When the transport delivers an entry, Agent:

  1. Extracts `chain_id` + `job_id` from the entry payload.
  2. Resolves the matching `Raxol.ACP.JobSession` (starting one if it
     doesn't exist yet) via `Raxol.ACP.JobSession.Supervisor`.
  3. Decodes the entry into the canonical `Raxol.ACP.JobSession.entry()`
     shape and threads it into the session.
  4. Forwards the entry to every subscribed caller as
     `{Raxol.ACP.Agent, agent_pid, session_pid, entry}`.

  Inferring the agent's role per session happens lazily on the first
  entry that disambiguates it (e.g. a `budget.set` from another address
  implies this agent is the client). The role is taken from
  `:default_role` or the entry's `role` field if present.
  """

  use GenServer

  require Logger

  alias Raxol.ACP.{Event, JobApi, JobSession, Transport}

  # Backoff before re-opening the SSE stream after it ends (server close or transport
  # error). The stream is a long-lived connection that WILL drop in normal operation;
  # the Agent owns reconnection (see Transport.SSE.stream_loop's contract).
  @stream_reconnect_ms 2_000

  @type t :: %__MODULE__{
          provider: term(),
          transport: Transport.t(),
          api: JobApi.t(),
          wallet_address: String.t(),
          supported_chain_ids: [pos_integer()],
          default_role: JobSession.role(),
          sessions: %{Transport.job_key() => pid()},
          subscribers: MapSet.t(pid()),
          started?: boolean()
        }

  defstruct [
    :provider,
    :transport,
    :api,
    :wallet_address,
    :supported_chain_ids,
    :default_role,
    sessions: %{},
    subscribers: MapSet.new(),
    started?: false
  ]

  # -- Public API --

  @doc """
  Start a supervised agent.

  ## Required options

  - `:transport` -- a `Raxol.ACP.Transport.t()`.
  - `:api` -- a `Raxol.ACP.JobApi.t()`.
  - `:wallet_address` -- agent's on-chain wallet address.
  - `:supported_chain_ids` -- e.g. `[8453]` for Base mainnet only.

  ## Optional options

  - `:provider` -- on-chain client. Required before submitting any
    hook calls (e.g. submit/complete); not yet required for receive-
    only mode.
  - `:default_role` -- `:provider`, `:client`, or `:evaluator`. Used
    when an entry doesn't carry an explicit role. Default `:provider`.
  - `:name` -- if set, registers the GenServer under that name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Open the transport stream. Idempotent.
  """
  @spec start_stream(GenServer.server()) :: :ok | {:error, term()}
  def start_stream(server), do: GenServer.call(server, :start_stream)

  @doc "Close the transport stream."
  @spec stop_stream(GenServer.server()) :: :ok
  def stop_stream(server), do: GenServer.call(server, :stop_stream)

  @doc "Subscribe the calling process to entry notifications from this agent."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server), do: GenServer.call(server, {:subscribe, self()})

  @doc "Unsubscribe the calling process."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server), do: GenServer.call(server, {:unsubscribe, self()})

  @doc "Get this agent's wallet address."
  @spec get_address(GenServer.server()) :: String.t()
  def get_address(server), do: GenServer.call(server, :get_address)

  @doc "Look up an existing JobSession by `{chain_id, job_id}`. Does NOT start a new one."
  @spec get_session(GenServer.server(), Transport.job_key()) :: pid() | nil
  def get_session(server, key), do: GenServer.call(server, {:get_session, key})

  @doc "All active sessions tracked by this agent."
  @spec sessions(GenServer.server()) :: %{Transport.job_key() => pid()}
  def sessions(server), do: GenServer.call(server, :sessions)

  @doc """
  Fetch a job's entry history via the transport (one-shot REST read).

  Used by the reattach path (`Raxol.ACP.Xochi.SolverAgent`) to recover a job's
  requirement after a restart dropped the in-memory session. The SSE stream is
  live-only and does not replay past entries on reconnect, so this is the only
  way to see entries that predate the current connection.
  """
  @spec get_history(GenServer.server(), Transport.job_key()) ::
          {:ok, [Transport.entry()]} | {:error, term()}
  def get_history(server, key), do: GenServer.call(server, {:get_history, key})

  @doc "Convenience wrapper around `JobApi.browse_agents/3`."
  @spec browse_agents(GenServer.server(), String.t(), map()) ::
          {:ok, [JobApi.agent_detail()]} | {:error, term()}
  def browse_agents(server, keyword, params \\ %{}) do
    GenServer.call(server, {:browse_agents, keyword, params})
  end

  @doc "Convenience wrapper around `JobApi.get_agent_by_wallet_address/2`."
  @spec get_agent(GenServer.server(), String.t()) ::
          {:ok, JobApi.agent_detail() | nil} | {:error, term()}
  def get_agent(server, wallet_address) do
    GenServer.call(server, {:get_agent_by_wallet, wallet_address})
  end

  @doc """
  Send a chat message via the transport. Streaming send; use
  `post_message/4` for one-shot REST.
  """
  @spec send_message(
          GenServer.server(),
          Transport.job_key(),
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def send_message(server, key, content, content_type \\ "text") do
    GenServer.call(server, {:send_message, key, content, content_type})
  end

  @doc "Like `send_message/4` but uses transport's one-shot REST POST."
  @spec post_message(
          GenServer.server(),
          Transport.job_key(),
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def post_message(server, key, content, content_type \\ "text") do
    GenServer.call(server, {:post_message, key, content, content_type})
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      provider: Keyword.get(opts, :provider),
      transport: Keyword.fetch!(opts, :transport),
      api: Keyword.fetch!(opts, :api),
      wallet_address: Keyword.fetch!(opts, :wallet_address),
      supported_chain_ids: Keyword.fetch!(opts, :supported_chain_ids),
      default_role: Keyword.get(opts, :default_role, :provider)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start_stream, _from, %{started?: true} = state), do: {:reply, :ok, state}

  def handle_call(:start_stream, _from, state) do
    case open_stream(state) do
      :ok -> {:reply, :ok, %{state | started?: true}}
      err -> {:reply, err, state}
    end
  end

  def handle_call(:stop_stream, _from, state) do
    Transport.disconnect(state.transport)
    {:reply, :ok, %{state | started?: false}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call(:get_address, _from, state), do: {:reply, state.wallet_address, state}

  def handle_call({:get_session, key}, _from, state) do
    {:reply, Map.get(state.sessions, key), state}
  end

  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  def handle_call({:get_history, key}, _from, state) do
    {:reply, Transport.get_history(state.transport, key), state}
  end

  def handle_call({:browse_agents, keyword, params}, _from, state) do
    {:reply, JobApi.browse_agents(state.api, keyword, params), state}
  end

  def handle_call({:get_agent_by_wallet, wallet}, _from, state) do
    {:reply, JobApi.get_agent_by_wallet_address(state.api, wallet), state}
  end

  def handle_call({:send_message, key, content, content_type}, _from, state) do
    {:reply, Transport.send_message(state.transport, key, content, content_type), state}
  end

  def handle_call({:post_message, key, content, content_type}, _from, state) do
    {:reply, Transport.post_message(state.transport, key, content, content_type), state}
  end

  @impl GenServer
  def handle_info({:transport, entry}, state) do
    state = route_entry(entry, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {_k, p} -> p == pid end)
      |> Map.new()

    state = %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        sessions: sessions
    }

    {:noreply, state}
  end

  # The SSE stream runs as a Task.async owned by this Agent (Transport.SSE.connect).
  # When it ends -- the server closed the stream or a transport error occurred -- the
  # Task delivers {ref, result}. Per the transport contract the Agent owns reconnection:
  # flush the paired :DOWN, then re-open after a short backoff, rather than crash on the
  # unhandled message. (Reconnect re-fetches the auth token via Transport.connect.)
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.info("ACP SSE stream ended; reconnecting in #{@stream_reconnect_ms}ms")
    Process.send_after(self(), :reconnect_stream, @stream_reconnect_ms)
    {:noreply, %{state | started?: false}}
  end

  # A reconnect is already-open (e.g. start_stream ran in the interim) -- nothing to do.
  def handle_info(:reconnect_stream, %{started?: true} = state), do: {:noreply, state}

  def handle_info(:reconnect_stream, state) do
    case open_stream(state) do
      :ok ->
        {:noreply, %{state | started?: true}}

      {:error, reason} ->
        Logger.warning("ACP SSE reconnect failed (#{inspect(reason)}); retrying")
        Process.send_after(self(), :reconnect_stream, @stream_reconnect_ms)
        {:noreply, state}
    end
  end

  # -- Stream --

  defp open_stream(state) do
    ctx = %{
      owner: self(),
      chain_ids: state.supported_chain_ids,
      wallet_address: state.wallet_address
    }

    Transport.connect(state.transport, ctx)
  end

  # -- Routing --

  defp route_entry(entry, state) do
    key = job_key(entry)

    {session_pid, state} = ensure_session(key, entry, state)
    propagate_to_session(session_pid, entry)
    broadcast(state, session_pid, entry)

    state
  end

  defp job_key(entry) do
    chain_id = entry["chainId"] || entry[:chainId] || entry["chain_id"] || entry[:chain_id]
    {chain_id, job_id_from(entry)}
  end

  # The live ACP SSE carries the job id as `onChainJobId` (top-level and inside the
  # nested `event` map); older/mock shapes use `jobId`/`job_id`. Accept all so a real
  # `job.created` doesn't yield a nil id (which fails the JobSession registry :via guard).
  defp job_id_from(entry) do
    entry["jobId"] || entry[:jobId] || entry["job_id"] || entry[:job_id] ||
      entry["onChainJobId"] || entry[:onChainJobId] ||
      event_job_id(entry["event"] || entry[:event])
  end

  defp event_job_id(%{} = ev),
    do: ev["onChainJobId"] || ev[:onChainJobId] || ev["jobId"] || ev[:jobId]

  defp event_job_id(_), do: nil

  defp ensure_session(key, _entry, state) do
    case Map.fetch(state.sessions, key) do
      {:ok, pid} ->
        {pid, state}

      :error ->
        {chain_id, job_id} = key

        {:ok, pid} =
          JobSession.Supervisor.start_session(
            chain_id: chain_id,
            job_id: job_id,
            role: state.default_role
          )

        Process.monitor(pid)
        {pid, %{state | sessions: Map.put(state.sessions, key, pid)}}
    end
  end

  # For system entries with a known event type, drive the session into the
  # corresponding status by replacing state. The real on-chain transition
  # (calling FundTransferHook etc.) lives behind ProviderAdapter; this only
  # mirrors the canonical status the event implies.
  defp propagate_to_session(session_pid, %{"kind" => "message"} = entry) do
    JobSession.send_message(
      session_pid,
      entry["content"] || "",
      entry["contentType"] || "text"
    )
  end

  defp propagate_to_session(session_pid, %{"kind" => "system"} = entry) do
    with type when is_binary(type) <- entry["event"] || entry["type"],
         {:ok, atom} <- Event.decode_type(type) do
      # The SSE event is authoritative (the on-chain state already settled),
      # so JobSession.apply_event mirrors the status without role/adjacency
      # gating -- and, unlike the old :sys.replace_state hack, records the
      # entry, notifies the session's own subscribers, and stops the process
      # itself when the status is terminal (the agent's :DOWN handler then
      # drops it from the registry).
      JobSession.apply_event(session_pid, status_for(atom), %{observed_event: type})
    else
      _ -> :ok
    end
  end

  defp propagate_to_session(_session_pid, _entry), do: :ok

  defp status_for(:job_created), do: :open
  defp status_for(:budget_set), do: :budget_set
  defp status_for(:job_funded), do: :funded
  defp status_for(:job_submitted), do: :submitted
  defp status_for(:job_completed), do: :completed
  defp status_for(:job_rejected), do: :rejected
  defp status_for(:job_expired), do: :expired

  defp broadcast(state, session_pid, entry) do
    for pid <- state.subscribers do
      send(pid, {__MODULE__, self(), session_pid, entry})
    end
  end
end
