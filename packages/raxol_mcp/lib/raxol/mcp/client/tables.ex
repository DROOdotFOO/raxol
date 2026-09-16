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

  @eras {__MODULE__, :eras}
  @breakers {__MODULE__, :breakers}

  @doc "Start the table owner. One per node, named."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @doc """
  Both tables, starting the owner if nothing has yet.

  Idempotent, and safe from a transient caller: the owner is started unlinked.
  """
  @spec ensure_started() :: %{eras: :ets.table(), breakers: :ets.table()}
  def ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    %{eras: eras(), breakers: breakers()}
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

    {:ok, %{}}
  end
end
