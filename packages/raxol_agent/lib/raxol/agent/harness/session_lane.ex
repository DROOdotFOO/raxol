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
  """

  @behaviour Raxol.Harness.SessionLane

  alias Raxol.Agent.Command
  alias Raxol.Agent.Session
  alias Raxol.Agent.SessionStreamer

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
  Honest refusal: `{:error, :no_steer_channel}`, always.

  No shipped session runtime owns a live turn's `Raxol.Agent.Steer.TurnState`
  to resolve the compare-and-swap against (`Raxol.Agent.Steer`'s own
  moduledoc documents that single-writer runtime integration as still
  pending). Dispatching a fire-and-forget `:steer` command here
  with no decision reply would let the harness surface render a queued
  banner it has no way to know was ever actually accepted, rejected as
  stale, or silently dropped -- exactly the dishonest-UI failure mode
  `Raxol.Harness.SessionLane`'s own moduledoc calls out for why `steer/2`
  is a synchronous reply in the first place. Refusing loudly here is more
  honest than pretending to deliver.
  """
  @impl Raxol.Harness.SessionLane
  @spec steer(session(), map()) :: {:error, :no_steer_channel}
  def steer(_session, _request), do: {:error, :no_steer_channel}

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
