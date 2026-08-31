defmodule Raxol.Agent.Lsp.Pool do
  @moduledoc """
  One language server per language, started on first use and owned by the
  session.

  A language server is expensive to start (rust-analyzer indexes a crate
  before it answers anything), so it must outlive a single turn; and it is an
  OS subprocess, so it must not outlive the session. The pool sits between:
  it starts each server lazily, keeps it for the session's lifetime, and
  monitors the owning process so that when the session ends by any path —
  a clean quit, an SSH disconnect, or a crash — the pool exits and takes its
  linked servers, and their subprocesses, with it.

  This is the `Raxol.Agent.Code.McpLoader` ownership pattern: nothing has to
  remember to call a cleanup function, because there is no such function to
  forget.

  A server that crashes is trapped and dropped, never propagating to the
  session. The next request for that language starts a fresh one.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Lsp.Config
  alias Raxol.Agent.LSPContext

  @start_timeout 30_000
  # A cold server indexes the project before it answers; requests made during
  # that window get `{:not_ready, _}` rather than a wrong answer, so the pool
  # waits for readiness once at startup instead of per call.
  @ready_poll_ms 100

  defstruct [:owner, :root, :servers, :starter, clients: %{}, failed: %{}]

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
  def handle_call({:client_for, path}, _from, state) do
    with {:ok, server} <- Config.for_path(state.servers, path) do
      case Map.fetch(state.clients, server.name) do
        {:ok, client} ->
          {:reply, {:ok, client, server}, state}

        :error ->
          start_client(server, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:running, _from, state) do
    {:reply, state.clients |> Map.keys() |> Enum.sort(), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.clients, fn {_name, client} -> client == pid end) do
      nil ->
        {:noreply, state}

      {name, _client} ->
        Logger.warning("[LSP] #{name} server exited: #{inspect(reason)}")
        {:noreply, %{state | clients: Map.delete(state.clients, name)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- starting ---------------------------------------------------------------

  defp start_client(server, state) do
    case state.starter.(
           command: server.command,
           args: server.args,
           root_uri: path_to_uri(state.root)
         ) do
      {:ok, client} ->
        await_ready(client, server, state)

      {:error, reason} ->
        {:reply, {:error, {:start_failed, reason}}, state}
    end
  catch
    kind, reason -> {:reply, {:error, {:start_failed, {kind, reason}}}, state}
  end

  # `initialize` is a round trip to a process that may be indexing, so the
  # first caller waits for it rather than getting a `:not_ready` it cannot act
  # on. A server that never reaches ready is stopped, not left running as a
  # subprocess nothing will ever ask anything.
  defp await_ready(client, server, state) do
    case poll_ready(client, System.monotonic_time(:millisecond) + @start_timeout) do
      :ok ->
        {:reply, {:ok, client, server}, put_in(state.clients[server.name], client)}

      {:error, reason} ->
        LSPContext.stop(client)
        {:reply, {:error, {:not_ready, reason}}, state}
    end
  catch
    :exit, reason -> {:reply, {:error, {:start_failed, reason}}, state}
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
  end

  @doc "Absolute path to a `file://` URI."
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path), do: "file://" <> path

  @doc "A `file://` URI back to a path."
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> path), do: path
  def uri_to_path(uri), do: uri
end
