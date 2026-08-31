defmodule Raxol.Agent.Lsp.Pool do
  @moduledoc """
  One language server per language, started on first use and owned by the
  session.

  A language server is expensive to start (rust-analyzer indexes a crate
  before it answers anything), so it must outlive a single turn; and it is an
  OS subprocess, so it must not outlive the session. The pool sits between:
  it starts each server lazily, keeps it for the session's lifetime, and
  monitors the owning process so that when the session ends by any path —
  a clean quit, an SSH disconnect, or a crash — the pool stops each server it
  owns before going down itself.

  It stops them EXPLICITLY, in `terminate/2`. Linking is not enough on its
  own: the pool exits `:normal` when its owner goes, and a `:normal` exit
  signal is ignored by a linked process that is not trapping exits, which
  `Raxol.Agent.LSPContext` is not. So the clients used to survive the pool,
  their `terminate/2` never ran, the LSP `shutdown`/`exit` handshake was never
  sent, and rust-analyzer and elixir-ls outlived the session for the life of
  the BEAM. The pool itself traps exits, so its own `terminate/2` does run,
  which is what makes it the right place to do this.

  A server that crashes is trapped and dropped, never propagating to the
  session. The next request for that language starts a fresh one.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Lsp.Config
  alias Raxol.Agent.LSPContext

  @start_timeout 30_000
  # Long enough for a `shutdown`/`exit` handshake, short enough that one
  # wedged server does not hold a session's teardown open.
  @stop_timeout 2_000
  # A cold server indexes the project before it answers; requests made during
  # that window get `{:not_ready, _}` rather than a wrong answer, so the pool
  # waits for readiness once at startup instead of per call.
  @ready_poll_ms 100

  defstruct [
    :owner,
    :root,
    :servers,
    :starter,
    clients: %{},
    # name => %{client: pid, waiters: [GenServer.from()], monitor: reference()}
    # A server whose `initialize` round trip is still in flight. Waiting for it
    # inside `handle_call` blocked the pool for the whole start timeout, and a
    # cold rust-analyzer spends that long -- so an owner that died during a
    # start was not noticed until the wait ended, and the subprocess ran on.
    starting: %{},
    failed: %{}
  ]

  @doc """
  Start a pool for `root`, owned by `:owner` (default: the caller).

  Options: `:root` (workspace root, required), `:owner`, `:servers` (a
  resolved `Config` table, default `Config.load/1` on the root), and
  `:starter` (the client start function, injectable for tests).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a pool without linking to the caller.

  This is what a session uses. The pool holds the workspace's language
  servers, and a fault in it must not propagate to the session that merely
  asked for one; the owner monitor still tears everything down when the
  session ends, so nothing leaks by not linking.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  The client serving `path`, starting it if this is the first request.

  Returns `{:ok, client, server}` where `server` is the config entry (its
  `language_id` is what `did_open` needs).
  """
  @spec client_for(GenServer.server(), String.t()) ::
          {:ok, pid(), Config.server()} | {:error, term()}
  def client_for(pool, path) do
    GenServer.call(pool, {:client_for, path}, @start_timeout + 5_000)
  end

  @doc "Which languages have a running server, for `/inspect` and status."
  @spec running(GenServer.server()) :: [String.t()]
  def running(pool), do: GenServer.call(pool, :running)

  @doc "Stop the pool and every server it owns. A dead pid is a no-op."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pool) when is_pid(pool) do
    if Process.alive?(pool), do: GenServer.stop(pool, :normal, 5_000), else: :ok
  catch
    :exit, _ -> :ok
  end

  # -- callbacks --------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Trapping exits is what makes a crashing server a dropped entry rather
    # than a dead session: the clients are linked so they die with the pool,
    # but their deaths arrive here as messages.
    Process.flag(:trap_exit, true)

    root = Keyword.fetch!(opts, :root)
    owner = Keyword.get(opts, :owner, self())
    Process.monitor(owner)

    {:ok,
     %__MODULE__{
       owner: owner,
       root: root,
       servers: Keyword.get_lazy(opts, :servers, fn -> Config.load(root) end),
       starter: Keyword.get(opts, :starter, &LSPContext.start_link/1)
     }}
  end

  @impl GenServer
  def handle_call({:client_for, path}, from, state) do
    with {:ok, server} <- Config.for_path(state.servers, path) do
      route_request(server, from, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:running, _from, state) do
    {:reply, state.clients |> Map.keys() |> Enum.sort(), state}
  end

  defp route_request(server, from, state) do
    cond do
      client = Map.get(state.clients, server.name) ->
        {:reply, {:ok, client, server}, state}

      Map.has_key?(state.starting, server.name) ->
        # Someone is already paying for this start; join their queue rather
        # than spawning a second server for the same language.
        {:noreply, add_waiter(state, server.name, from)}

      true ->
        start_client(server, from, state)
    end
  end

  @impl GenServer
  # The owner clause must sit above the readiness-waiter one: both are
  # `:DOWN`, and the owner going away outranks anything in flight.
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  # A start finished. Answer everyone queued behind it with one result.
  def handle_info({:lsp_ready, name, result}, state) do
    case Map.pop(state.starting, name) do
      {nil, _starting} ->
        {:noreply, state}

      {%{client: client, waiters: waiters, monitor: monitor}, starting} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | starting: starting}
        {:noreply, settle_start(name, client, waiters, result, state)}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.clients, fn {_name, client} -> client == pid end) do
      nil ->
        {:noreply, drop_starting_client(pid, reason, state)}

      {name, _client} ->
        Logger.warning("[LSP] #{name} server exited: #{inspect(reason)}")
        {:noreply, %{state | clients: Map.delete(state.clients, name)}}
    end
  end

  # The readiness waiter died without reporting. Fail its callers rather than
  # leaving them to time out against a pool that is otherwise healthy.
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.starting, fn {_n, s} -> s.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {name, %{client: client, waiters: waiters}} ->
        state = %{state | starting: Map.delete(state.starting, name)}

        {:noreply, settle_start(name, client, waiters, {:error, {:waiter_down, reason}}, state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The whole reason this module owns anything. `:normal` does not kill a
  # linked non-trapping process, so without this the servers -- and the OS
  # subprocesses behind them -- outlived the pool that was supposed to hold
  # them. Stopping each one runs its `terminate/2`, which sends the LSP
  # `shutdown`/`exit` handshake before closing the port.
  @impl GenServer
  def terminate(_reason, state) do
    starting_clients = Enum.map(state.starting, fn {_name, s} -> s.client end)

    state.clients
    |> Map.values()
    |> Enum.concat(starting_clients)
    |> Enum.each(&stop_client/1)

    :ok
  end

  # Bounded, because this runs while a session is tearing down and
  # `LSPContext.stop/1` waits forever: a server wedged in its own shutdown
  # would hold the teardown open indefinitely. Past the deadline it is killed,
  # which closes the port and hands the subprocess EOF on stdin -- the exit
  # signal the LSP spec gives a server, and the reason the clean path tries
  # the `shutdown`/`exit` handshake first.
  defp stop_client(client) do
    if Process.alive?(client) do
      GenServer.stop(client, :normal, @stop_timeout)
    end

    :ok
  catch
    :exit, _reason ->
      Process.exit(client, :kill)
      :ok
  end

  # -- starting ---------------------------------------------------------------

  defp start_client(server, from, state) do
    case state.starter.(
           command: server.command,
           args: server.args,
           root_uri: path_to_uri(state.root)
         ) do
      {:ok, client} ->
        {:noreply, await_ready(client, server, from, state)}

      {:error, reason} ->
        {:reply, {:error, {:start_failed, reason}}, state}
    end
  catch
    kind, reason -> {:reply, {:error, {:start_failed, {kind, reason}}}, state}
  end

  # `initialize` is a round trip to a process that may be indexing, so the
  # first caller waits for it rather than getting a `:not_ready` it cannot act
  # on. The WAITING happens in a throwaway process, not in `handle_call`: a
  # cold server can take the whole start timeout, and blocking the pool for it
  # meant the owner's `:DOWN` sat unread for that long, so a session that ended
  # mid-start left its subprocess running. The caller still blocks -- the reply
  # is simply deferred until the result arrives.
  defp await_ready(client, server, from, state) do
    pool = self()
    deadline = System.monotonic_time(:millisecond) + @start_timeout

    {_pid, monitor} =
      spawn_monitor(fn ->
        send(pool, {:lsp_ready, server.name, poll_ready(client, deadline)})
      end)

    put_in(state.starting[server.name], %{
      client: client,
      waiters: [from],
      monitor: monitor
    })
  end

  defp add_waiter(state, name, from) do
    update_in(state.starting[name].waiters, &[from | &1])
  end

  # A server that never reaches ready is stopped, not left running as a
  # subprocess nothing will ever ask anything.
  defp settle_start(name, client, waiters, result, state) do
    {reply, state} =
      case result do
        :ok ->
          server = Enum.find(state.servers, &(&1.name == name))
          {{:ok, client, server}, put_in(state.clients[name], client)}

        {:error, reason} ->
          LSPContext.stop(client)
          {{:error, {:not_ready, reason}}, state}
      end

    Enum.each(waiters, &GenServer.reply(&1, reply))
    state
  end

  # A client that died while still starting: its waiters are answered by the
  # readiness result, so this only has to forget it, and must not fall through
  # to the "unknown exit" no-op that would leave a stale entry to be stopped.
  defp drop_starting_client(pid, reason, state) do
    case Enum.find(state.starting, fn {_n, s} -> s.client == pid end) do
      nil ->
        state

      {name, _entry} ->
        Logger.warning("[LSP] #{name} server exited while starting: #{inspect(reason)}")
        state
    end
  end

  defp poll_ready(client, deadline) do
    case LSPContext.status(client) do
      %{status: :ready} ->
        :ok

      %{status: :closed} ->
        {:error, :closed}

      %{status: status} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:timeout, status}}
        else
          Process.sleep(@ready_poll_ms)
          poll_ready(client, deadline)
        end
    end
  catch
    # The client died mid-poll; report it rather than crashing the waiter.
    :exit, reason -> {:error, {:start_failed, reason}}
  end

  @doc "Absolute path to a `file://` URI."
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path), do: "file://" <> path

  @doc "A `file://` URI back to a path."
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> path), do: path
  def uri_to_path(uri), do: uri
end
