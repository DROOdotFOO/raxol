defmodule Raxol.Agent.Harness.SessionLane do
  @moduledoc """
  The agent-side implementation of `Raxol.Harness.SessionLane` (main
  `raxol` package -- the harness surface's seam onto a live session,
  which that package must never depend on `raxol_agent` to satisfy). This
  module is the concrete lane that wires the seam to the real
  `Raxol.Agent.SessionStreamer` (outbound events) and `Raxol.Agent.Command`
  (inbound commands).

  See `Raxol.Harness.SessionLane`'s own moduledoc for the interrupt/steer
  asymmetry rationale this module implements.

  ## Steer branches on session capability (Track E / U6-I)

  `steer/2` is no longer an unconditional refusal. It branches on whether the
  session handle is **ACP-backed** — i.e. whether it carries an `:acp_session`
  pid (a live `Raxol.AgentClientProtocol.Session`, the single-writer turn owner
  that owns the running turn's `Raxol.Agent.Steer.TurnState` and resolves the
  compare-and-swap from its own mailbox):

    * **ACP-backed** (`:acp_session` present) — dispatch the steer to that
      Session's synchronous `{:steer, payload}` call and return its CAS reply
      verbatim (the honest vocabulary: `{:ok, {:accepted | :duplicate, ref}}`,
      `{:error, {:stale_turn, _, _}}`, `{:error, :no_live_turn | :client_msg_id_reuse}`).
      Bounded and translated: a slow/dead Session becomes `{:error, :timeout}` /
      `{:error, :no_session}`, never a hung caller. The `{:steer, payload}`
      message contract is shared BY CODE with `Raxol.AgentClientProtocol.Session.steer/2`
      (this package does not depend on the ACP package; the ACP bridge that
      minted the handle owns the pid).
    * **Legacy** (no `:acp_session`) — the honest `{:error, :no_steer_channel}`
      refusal STANDS. A non-ACP session runtime owns no live `TurnState`; there
      is nothing to resolve the CAS against, so a queued-banner surface would be
      dishonest. This refusal was always true for the legacy path and stays true.

  `payload` is validated through `Raxol.Agent.Command.decode/1`'s `:steer` codec
  (the one validation seam) before dispatch, so malformed input (empty text,
  missing `expected_turn_id`) is a loud `{:error, {:invalid_command, reason}}`,
  never a best-effort partial reaching the Session.
  """

  @behaviour Raxol.Harness.SessionLane

  alias Raxol.Agent.Command
  alias Raxol.Agent.Session
  alias Raxol.Agent.SessionStreamer

  # Bounded steer dispatch: a steer is a synchronous typed decision, so a
  # slow/dead ACP Session must translate to a typed error, never hang the caller
  # (the behaviour's steer/2 contract calls this out explicitly).
  @steer_timeout_ms 5_000

  @typedoc "A live session handle, per `Raxol.Harness.SessionLane.session/0`."
  @type session :: Raxol.Harness.SessionLane.session()

  @doc """
  Subscribe the calling process to `session`'s live event stream via
  `Raxol.Agent.SessionStreamer.subscribe/1`. Must be called from the
  process that wants to receive events (`SessionStreamer`'s own contract:
  it monitors the CALLING process, not any process this function could
  pass in on its behalf).

  Requires a running `Raxol.Agent.SessionStreamer` under its default
  registered name; when none is running, the underlying `GenServer.call`
  raises or exits (`:noproc`) rather than hanging -- both are caught here
  and translated to `{:error, :no_streamer}` instead of crashing the
  caller.
  """
  @impl Raxol.Harness.SessionLane
  @spec subscribe(session()) :: :ok | {:error, term()}
  def subscribe(%{session_id: session_id}) do
    SessionStreamer.subscribe(session_id)
  rescue
    _error -> {:error, :no_streamer}
  catch
    :exit, _reason -> {:error, :no_streamer}
  end

  @doc """
  Fire-and-forget interrupt dispatch: builds the wire map `%{"type" =>
  "interrupt", "payload" => payload}` and runs it through
  `Raxol.Agent.Command.decode/1` (the one validation seam) before
  `Raxol.Agent.Command.route/2`. `payload` is passed through as-is --
  `Command.decode/1`'s own `validate/2` already reads `turn_id` under
  either atom or string keys, so no separate key-style translation is
  needed here.

  Acknowledgment is EVENT-OBSERVED (see the behaviour's moduledoc): this
  always returns `:ok` once the command decodes and is routed, or
  `{:error, reason}` if the payload fails `Command.decode/1`'s own
  validation.
  """
  @impl Raxol.Harness.SessionLane
  @spec interrupt(session(), map()) :: :ok | {:error, term()}
  def interrupt(session, payload) when is_map(payload) do
    wire = %{"type" => "interrupt", "payload" => payload}

    case Command.decode(wire) do
      {:ok, cmd} ->
        Command.route(cmd, session)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fire-and-forget submit dispatch: builds the canonical wire map `%{"type"
  => "prompt", "payload" => %{"text" => text}}` and runs it through
  `Raxol.Agent.Command.decode/1` (the one validation seam -- it rejects a
  missing/empty/non-binary `text` loudly) before `Raxol.Agent.Command.route/2`.
  A `:prompt` command routes to `{:start_turn, session_id, payload}` and,
  when the session handle carries a `:pid`, is delivered as
  `{:harness_command, {:start_turn, ...}}` to that process.

  Mirrors `interrupt/2` exactly (same decode+route codec path, same
  event-observed acknowledgment) -- see `Raxol.Harness.SessionLane`'s
  `submit/2` doc: this returns `:ok` once the command decodes and routes,
  or `{:error, reason}` if `Command.decode/1` rejects the request. It does
  NOT report turn acceptance -- that is observed via the `:turn_started`
  event on the `subscribe/1` stream.

  Busy rejection (`{:error, :busy}`) is not produced here: the
  Command/SessionStreamer stack has no single-turn compare-and-swap at
  this seam, so the "one turn in flight" invariant is guarded by the
  driver's local `current_turn_id` belief before it ever calls this. An
  ACP lane over `session/prompt` (which returns JSON-RPC `-32600` for a
  busy session) would translate that reply into `{:error, :busy}` here --
  the seam's reply vocabulary already admits it.
  """
  @impl Raxol.Harness.SessionLane
  @spec submit(session(), map()) :: :ok | {:error, term()}
  def submit(session, %{text: text}) when is_binary(text) do
    wire = %{"type" => "prompt", "payload" => %{"text" => text}}

    case Command.decode(wire) do
      {:ok, cmd} ->
        Command.route(cmd, session)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def submit(_session, _request), do: {:error, :invalid_request}

  @doc """
  Steer a running turn (Track E / U6-I). Branches on session capability:

    * **ACP-backed** (`session[:acp_session]` is a pid) — validate the request
      through `Raxol.Agent.Command.decode/1`'s `:steer` codec, then dispatch the
      compare-and-swap synchronously to that `Raxol.AgentClientProtocol.Session`
      and return its CAS outcome verbatim. Bounded: a slow/dead Session becomes
      `{:error, :timeout}` / `{:error, :no_session}`.
    * **Legacy** (no `:acp_session`) — the honest `{:error, :no_steer_channel}`
      refusal (no live `TurnState` owner exists to resolve against).

  See this module's moduledoc for the full rationale.
  """
  @impl Raxol.Harness.SessionLane
  @spec steer(session(), map()) ::
          {:ok, {:accepted | :duplicate, map()}}
          | {:error, term()}
  def steer(session, request) when is_map(request) do
    case acp_session(session) do
      nil ->
        # Legacy (non-ACP) path: no live TurnState owner — honest refusal.
        {:error, :no_steer_channel}

      acp_pid ->
        with {:ok, %Command{type: :steer, payload: payload}} <-
               Command.decode(%{"type" => "steer", "payload" => request}) do
          dispatch_steer(acp_pid, payload)
        end
    end
  end

  # The ACP-backed capability marker: a live `Raxol.AgentClientProtocol.Session`
  # pid the ACP bridge stamped onto the handle. Absent ⇒ legacy ⇒ refuse.
  @spec acp_session(session()) :: pid() | nil
  defp acp_session(%{acp_session: pid}) when is_pid(pid), do: pid
  defp acp_session(_session), do: nil

  # Dispatch the validated steer payload to the ACP Session's synchronous
  # `{:steer, payload}` call (message contract shared by code, not by a package
  # dep). `client_msg_id` is defaulted so the payload always carries all three
  # CAS fields. Bounded + translated so the caller is never hung by a slow/dead
  # Session.
  @spec dispatch_steer(pid(), map()) :: {:ok, {atom(), map()}} | {:error, term()}
  defp dispatch_steer(acp_pid, payload) do
    payload = Map.put_new(payload, :client_msg_id, nil)
    GenServer.call(acp_pid, {:steer, payload}, @steer_timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :no_session}
  end

  @doc """
  `Process.monitor/1` on the session's `:pid`, when present. `nil` when
  the session handle carries no pid -- nothing to watch.
  """
  @impl Raxol.Harness.SessionLane
  @spec monitor(session()) :: reference() | nil
  def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
  def monitor(_session), do: nil

  @doc """
  Resolve a bare `session_id` to a `Raxol.Harness.SessionLane.session()`
  map via `Raxol.Agent.Session.Supervisor.whereis/1`, or `nil` when no
  live process is registered under that id.
  """
  @spec resolve(term()) :: session() | nil
  def resolve(session_id) do
    case Session.Supervisor.whereis(session_id) do
      nil -> nil
      pid -> %{session_id: session_id, pid: pid}
    end
  end
end
