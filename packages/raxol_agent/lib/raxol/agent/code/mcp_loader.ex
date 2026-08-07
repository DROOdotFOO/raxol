defmodule Raxol.Agent.Code.McpLoader do
  @moduledoc """
  Bridge from `.mcp.json` server config to live agent tools for the coding
  surfaces: converts `Raxol.Agent.Code.McpConfig` servers into
  `Raxol.Agent.McpBundle` specs, starts each server's MCP client, and returns
  the bundle result (tools as `Raxol.Agent.Action.Dynamic` values, plus a
  janitor pid that owns every started client).

  Ownership is tied to the session, not to a slash command. `load/2` spawns a
  janitor that starts each client linked to itself and monitors the session
  process (`:owner`). When the session ends by ANY path — Ctrl+C, an SSH
  disconnect, or a crash — the janitor's monitor fires and it exits, taking
  its linked clients (and their OS subprocesses) with it. A client that
  crashes is trapped and dropped, never propagating to the session. This
  needs no external supervisor and cannot leak on a termination path that
  forgets to call a cleanup function, because there is no such function to
  forget.
  """

  alias Raxol.Agent.McpBundle
  alias __MODULE__.Janitor

  @type result :: %{
          tools: [struct()],
          connected: [term()],
          failed: [{term(), term()}],
          janitor: pid() | nil
        }

  @doc """
  Load the configured servers; never raises or exits.

  Options: `:owner` (the session process to monitor; when it dies the clients
  are terminated — defaults to the caller), `:bundle` (the load function,
  default `McpBundle.load/2`), and `:client_start` (the raw client starter,
  default `Raxol.MCP.Client.start_link/1`), the latter two injectable for
  tests.
  """
  @spec load([map()], keyword()) :: result()
  def load(servers, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    bundle = Keyword.get(opts, :bundle, &McpBundle.load/2)

    client_start =
      Keyword.get(opts, :client_start, &Raxol.MCP.Client.start_link/1)

    janitor = start_janitor(owner, client_start)
    start = fn client_opts -> Janitor.start_client(janitor, client_opts) end

    result = bundle.(Enum.map(servers, &to_spec/1), start: start)

    # Report connected server NAMES only; the janitor owns the client pids so
    # nothing else can outlive the session by holding one.
    connected =
      Enum.map(Map.get(result, :servers, []), fn {name, _pid} -> name end)

    %{
      tools: Map.get(result, :tools, []),
      connected: connected,
      failed: Map.get(result, :failed, []),
      janitor: janitor
    }
  catch
    kind, reason ->
      %{
        tools: [],
        connected: [],
        failed: [{:bundle, {kind, reason}}],
        janitor: nil
      }
  end

  @doc "Stop the janitor (and its clients). A nil janitor or dead pid is a no-op."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(janitor) when is_pid(janitor) do
    if Process.alive?(janitor), do: Janitor.stop(janitor)
    :ok
  end

  defp start_janitor(owner, client_start) do
    Janitor.start(owner, client_start)
  end

  # McpConfig servers carry string names and an env MAP; the bundle spec
  # wants an atom name and an env LIST. The atom is minted from the user's
  # own local `.mcp.json` (bounded, not wire input).
  defp to_spec(server) do
    %{
      name: String.to_atom(server.name),
      command: server.command,
      args: Map.get(server, :args, []),
      env: server |> Map.get(:env, %{}) |> Map.to_list()
    }
  end

  defmodule Janitor do
    @moduledoc false
    # Owns the MCP client processes for one coding session. Starts each client
    # linked to itself (so it can bring them down together), traps their exits
    # (so a crashing server does not cascade), and monitors the session
    # process — when the session dies, the janitor exits and its links tear
    # the clients down. Unlinked from its spawner, so it outlives the
    # short-lived loader task and is bounded only by the session monitor.

    @spec start(pid(), (keyword() -> {:ok, pid()} | {:error, term()})) :: pid()
    def start(owner, client_start) do
      spawn(fn -> init(owner, client_start) end)
    end

    @spec start_client(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
    def start_client(janitor, client_opts) do
      ref = make_ref()
      send(janitor, {:start_client, self(), ref, client_opts})

      receive do
        {^ref, reply} -> reply
      after
        30_000 -> {:error, :janitor_timeout}
      end
    end

    @spec stop(pid()) :: :ok
    def stop(janitor) do
      send(janitor, :stop)
      :ok
    end

    defp init(owner, client_start) do
      Process.flag(:trap_exit, true)
      mon = Process.monitor(owner)
      loop(%{client_start: client_start, owner_mon: mon, clients: []})
    end

    defp loop(state) do
      receive do
        {:start_client, from, ref, client_opts} ->
          reply = state.client_start.(client_opts)

          state =
            case reply do
              {:ok, pid} -> %{state | clients: [pid | state.clients]}
              _error -> state
            end

          send(from, {ref, reply})
          loop(state)

        {:DOWN, mon, :process, _pid, _reason} when mon == state.owner_mon ->
          # The session ended: stop every client (and its OS subprocess),
          # then exit. A :normal janitor exit would not cascade over the
          # links, so termination is explicit.
          terminate_clients(state.clients)

        {:EXIT, pid, _reason} ->
          # A client crashed (or was stopped): forget it, do not cascade.
          loop(%{state | clients: List.delete(state.clients, pid)})

        :stop ->
          terminate_clients(state.clients)

        _other ->
          loop(state)
      end
    end

    defp terminate_clients(clients) do
      # A `:shutdown` exit signal, the same one a supervisor sends: it kills a
      # non-trapping client (and its linked port + OS subprocess) at once, and
      # triggers `terminate/2` on one that traps. Fast and OTP-idiomatic — no
      # blocking synchronous stop on a client that might ignore it.
      Enum.each(clients, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      end)

      :ok
    end
  end
end
