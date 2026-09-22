defmodule Raxol.MCP.Client.Tables do
  @moduledoc """
  The one process that owns the MCP client's per-ORIGIN state.

  ADR-0037 decision 2 asked for "a public ETS table with no owning process",
  which is not a thing that can be built: `:ets.new/2` tables are owned by the
  process that creates them (`circuit_breaker.ex:31-33`, whose only in-tree
  caller creates its tables inside a GenServer's `init_manager`). Two concrete
  failures follow from letting each client create its own:

    * an era verdict created by a client is a verdict per client, so every
      client pays for its own probe and the cache caches nothing;
    * a circuit breaker created per client never observes anyone else's
      failures, so a challenge-serving origin is retried by every client
      forever.

  Both pieces of state outlive any one client, so they are created once, here,
  and handed out through `:persistent_term`: a lock-free read of a
  write-once value rather than a message to this process per request.

  This process holds no logic. It creates two tables in `init/1` and answers
  nothing, which is what makes a restart theoretical rather than a live
  concern. Callers read through `eras/0` and `breakers/0` per use rather than
  caching a reference, because a restart replaces both tables and a stale
  reference raises `ArgumentError` from ETS.

  ## Why `ensure_started/0` exists

  The normal path is the supervised child of `Raxol.MCP.Supervisor`. But a
  client is also started directly, outside that tree, by
  `Raxol.Agent.McpBundle`, and an unreachable table there would mean no remote
  server at all rather than a slower one. So the HTTP transport ensures the
  owner exists before its first read. The started process is NOT linked to
  whoever asked: a client that dies must not take the shared verdict cache
  with it.
  """

  use GenServer

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client.Reservation

  @eras {__MODULE__, :eras}
  @breakers {__MODULE__, :breakers}
  @reservations {__MODULE__, :reservations}

  @type t :: %{eras: :ets.table(), breakers: :ets.table(), reservations: :ets.table()}

  @doc """
  Start the table owner. One per node, named.

  A name clash is not a failure here. `ensure_started/0` starts this process
  unlinked and outside any tree, so a client that ran before the subsystem
  booted may already own the tables; the supervised child adopts that owner
  rather than refusing to start the whole MCP subtree over the name. The
  tables are the point, and they are the same ones.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, pid}} -> adopt(pid, opts)
      other -> other
    end
  end

  defp adopt(pid, opts) do
    Process.link(pid)
    {:ok, pid}
  rescue
    # It exited between the name clash and the link, so nobody owns the
    # tables now: start our own.
    ArgumentError -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The era-verdict table, keyed `{origin, path}`.

  Raises if the owner has never run; callers that cannot assume a supervision
  tree call `ensure_started/0` first.
  """
  @spec eras() :: :ets.table()
  def eras, do: :persistent_term.get(@eras)

  @doc "The circuit-breaker table, keyed `{:origin, origin}`."
  @spec breakers() :: :ets.table()
  def breakers, do: :persistent_term.get(@breakers)

  @doc "The minted single-use spend handles (`Raxol.MCP.Client.Reservation`)."
  @spec reservations() :: :ets.table()
  def reservations, do: :persistent_term.get(@reservations)

  @doc """
  Every table, starting the owner if nothing has yet.

  Idempotent, and safe from a transient caller: the owner is started
  unlinked.

  The answer comes from the owner rather than from `:persistent_term` when
  this call did not start it. `GenServer.start/3` registers the name before
  `init/1` runs, so two clients connecting concurrently both get past the
  clash while only one has written the terms, and the loser used to read a
  term that did not exist yet -- an `ArgumentError` from
  `handle_continue`, in the exact embedded configuration (`raxol_agent`
  alone, no `Raxol.MCP.Supervisor`) this function exists for. A call is
  queued behind `init/1`, so it cannot observe the gap.
  """
  @spec ensure_started() :: t()
  def ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> tables()
      {:error, {:already_started, pid}} -> await(pid)
    end
  end

  defp await(pid) do
    GenServer.call(pid, :tables)
  catch
    # The owner exited while we waited on it. One retry, which either starts
    # a fresh owner or waits on whoever else won the race.
    :exit, _gone -> ensure_started()
  end

  @impl GenServer
  def init(_opts) do
    :persistent_term.put(
      @eras,
      :ets.new(:raxol_mcp_client_eras, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    )

    :persistent_term.put(@breakers, CircuitBreaker.new(:raxol_mcp_client_breakers))
    :persistent_term.put(@reservations, Reservation.new(:raxol_mcp_client_reservations))

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:tables, _from, state), do: {:reply, tables(), state}

  defp tables, do: %{eras: eras(), breakers: breakers(), reservations: reservations()}
end
