defmodule Raxol.Agent.Code.McpLoader do
  @moduledoc """
  Bridge from `.mcp.json` server config to live agent tools for the coding
  surfaces: converts `Raxol.Agent.Code.McpConfig` servers into
  `Raxol.Agent.McpBundle` specs, starts each server's MCP client, and returns
  the bundle result (tools as `Raxol.Agent.Action.Dynamic` values, plus a
  janitor pid that owns every started client).

  Ownership is tied to the session, not to a slash command. `load/2` starts a
  janitor under `Raxol.Agent.TaskSupervisor`; the janitor starts each client
  linked to itself and monitors the session process (`:owner`). When the
  session ends by ANY path — Ctrl+C, an SSH disconnect, or a crash — the
  janitor's monitor fires and it exits, taking its linked clients (and their OS
  subprocesses) with it. A client that crashes is trapped and dropped, never
  propagating to the session. The supervisor makes janitor ownership visible
  and ensures startup is not an untracked process spawn.
  """

  alias __MODULE__.Janitor
  alias Raxol.Agent.McpBundle

  # Each accepted server mints an atom (the bundle spec's name, which
  # `Raxol.MCP.Client` requires) and spawns an OS subprocess, and `.mcp.json`
  # is workspace content, so both costs are bounded here rather than trusted
  # to the file. They are bounded differently, because they expire
  # differently. Subprocesses die with the session, so the count is per load:
  # at most `@max_servers` start. Atoms are never collected and each session
  # re-reads a fresh file, so a per-load cap alone bounded nothing across a
  # node's life -- 1024 sessions of a long-lived host minted up to 16k
  # workspace-chosen atoms. So a name that already HAS an atom is free (the
  # atom is in the table whatever put it there) and a name that would mint a
  # new one draws on `@atom_budget`, counted node-wide for the life of the
  # VM; past it such a name is refused rather than interned. A name outside
  # the conservative charset is refused before either cost. (A jailed session
  # declines to read the file at all — see `Raxol.Agent.Code.App`; this is
  # the second gate, for the single-tenant workspace that is merely careless
  # rather than hostile.)
  @max_servers 16
  @atom_budget 256
  @server_name_re ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  @atom_budget_key {__MODULE__, :atom_budget}

  @doc """
  The most servers one `.mcp.json` may load. Public so a surface bounds
  what it renders by the same number this module bounds what it starts.
  """
  @spec max_servers() :: pos_integer()
  def max_servers, do: @max_servers

  @type result :: %{
          tools: [struct()],
          connected: [term()],
          failed: [{term(), term()}],
          janitor: pid() | nil
        }

  @doc """
  Load the configured servers; never raises or exits.

  Options: `:owner` (the session process to monitor; when it dies the clients
  are terminated — defaults to the caller), `:supervisor` (the TaskSupervisor
  that owns the janitor, default `Raxol.Agent.TaskSupervisor`), `:bundle` (the
  load function, default `McpBundle.load/2`), `:client_start` (the raw client
  starter, default `Raxol.MCP.Client.start_link/1`), plus the `:atom_budget`
  and `:atom_counter` pair `admit/2` bounds atom minting with. All of them are
  injectable for tests and embedders outside the full agent subtree.
  """
  @spec load([map()], keyword()) :: result()
  def load(servers, opts \\ []) do
    {owner, supervisor, bundle, client_start} = loader_options(opts)
    {accepted, rejected} = admit(servers, opts)
    load_accepted(accepted, rejected, owner, supervisor, bundle, client_start)
  catch
    kind, reason ->
      %{
        tools: [],
        connected: [],
        failed: [{:bundle, {kind, reason}}],
        janitor: nil
      }
  end

  defp loader_options(opts) do
    {
      Keyword.get(opts, :owner, self()),
      Keyword.get(opts, :supervisor, Raxol.Agent.TaskSupervisor),
      Keyword.get(opts, :bundle, &McpBundle.load/2),
      Keyword.get(opts, :client_start, &Raxol.MCP.Client.start_link/1)
    }
  end

  defp load_accepted(accepted, rejected, owner, supervisor, bundle, client_start) do
    janitor = start_janitor(supervisor, owner, client_start)
    start = fn client_opts -> Janitor.start_client(janitor, client_opts) end
    result = bundle.(Enum.map(accepted, &to_spec/1), start: start)
    build_result(result, rejected, janitor)
  end

  defp build_result(result, rejected, janitor) do
    # Report connected server NAMES only; the janitor owns the client pids so
    # nothing else can outlive the session by holding one.
    connected =
      Enum.map(Map.get(result, :servers, []), fn {name, _pid} -> name end)

    %{
      tools: Map.get(result, :tools, []),
      connected: connected,
      # Refusals ride the same `failed` channel the surface already reports,
      # so a dropped server is visible in `/mcp` rather than silently absent.
      failed: Map.get(result, :failed, []) ++ rejected,
      janitor: janitor
    }
  end

  @doc "Stop the janitor (and its clients). A nil janitor or dead pid is a no-op."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(janitor) when is_pid(janitor) do
    if Process.alive?(janitor), do: Janitor.stop(janitor)
    :ok
  end

  defp start_janitor(supervisor, owner, client_start) do
    Janitor.start(supervisor, owner, client_start)
  end

  @doc """
  Split configured servers into the ones that may load and the ones refused,
  as `{accepted, rejected}`. Rejections are `{name, reason}` pairs in the
  same shape `McpBundle` reports load failures in.

  This is where a name becomes an atom, so it is also where the node-wide
  atom budget is spent. `:atom_budget` (default `#{@atom_budget}`) and
  `:atom_counter` (default the node's own) are injectable so a test can drive
  the exhausted path without spending the node's budget on the way.
  """
  @spec admit([map()], keyword()) :: {[map()], [{term(), term()}]}
  def admit(servers, opts \\ []) do
    {named, unnamed} =
      Enum.split_with(servers, &valid_server_name?(Map.get(&1, :name)))

    {unique, duplicate} = dedupe(named)
    {within_cap, over_cap} = Enum.split(unique, @max_servers)
    {accepted, unmintable} = intern_names(within_cap, opts)

    rejected =
      Enum.map(unnamed, &{Map.get(&1, :name), :invalid_server_name}) ++
        duplicate ++
        Enum.map(over_cap, &{Map.get(&1, :name), :server_limit_exceeded}) ++
        Enum.map(unmintable, &{Map.get(&1, :name), :atom_budget_exhausted})

    {accepted, rejected}
  end

  # One server per NORMALIZED name, first occurrence wins. The caller lists
  # user-level servers before workspace ones, so a workspace `.mcp.json` cannot
  # shadow an operator's server by reusing its name with a url of its own --
  # which would otherwise inherit that name's allowlisted header references.
  #
  # Normalized, not raw, and the shadowing case is exactly why: `-` is a legal
  # name character here but not in a tool name, so `intel-api` and `intel_api`
  # are two DIFFERENT raw names that both mint `mcp__intel_api__<tool>`. Keyed
  # on the raw name, both were admitted, which put two identically named
  # functions in one tool array -- providers reject the whole request, so every
  # tool call in the session fails -- and reopened the shadowing this exists to
  # prevent, since the operator's name only has to be reachable by a workspace
  # spelling of it. The loser carries the winner it collided with, because
  # `intel-api` refused next to a configured `intel_api` is otherwise a refusal
  # with nothing in the file to point at.
  defp dedupe(servers) do
    {unique, duplicate, _seen} =
      Enum.reduce(servers, {[], [], %{}}, fn server, {unique, duplicate, seen} ->
        name = Map.get(server, :name)
        key = normalized_name(name)

        case Map.fetch(seen, key) do
          {:ok, kept} ->
            {unique, [{name, {:duplicate_server_name, kept}} | duplicate], seen}

          :error ->
            {[server | unique], duplicate, Map.put(seen, key, name)}
        end
      end)

    {Enum.reverse(unique), Enum.reverse(duplicate)}
  end

  # Must agree with `Raxol.MCP.Client.tool_name/2`, which is what actually
  # builds the name a provider sees. Spelled out rather than called because
  # that function takes the spec's ATOM name and this runs before any atom
  # exists -- deciding to intern is the whole point of the caller.
  defp normalized_name(name), do: String.replace(name, ~r/[^a-zA-Z0-9_]/, "_")

  defp valid_server_name?(name),
    do: is_binary(name) and Regex.match?(@server_name_re, name)

  defp intern_names(servers, opts) do
    budget = Keyword.get(opts, :atom_budget, @atom_budget)
    counter = Keyword.get_lazy(opts, :atom_counter, &atom_counter/0)

    Enum.split_with(servers, &intern(Map.fetch!(&1, :name), counter, budget))
  end

  # A name whose atom already exists costs nothing, whatever put it there, so
  # only a name that would mint a NEW one draws the budget down -- which means
  # a host reloading the same `.mcp.json` a million times spends one unit, and
  # only a stream of fresh names ever reaches the refusal. `add_get` rather
  # than read-then-write because two sessions loading at once must not both
  # spend the last unit.
  defp intern(name, counter, budget) do
    _existing = String.to_existing_atom(name)
    true
  rescue
    ArgumentError ->
      if :atomics.add_get(counter, 1, 1) <= budget do
        _minted = String.to_atom(name)
        true
      else
        false
      end
  end

  # One counter per node, published once and never replaced: the read is on
  # every load, and re-reading after the put converges two racing first loads
  # on a single counter instead of leaving each with a budget of its own.
  defp atom_counter do
    case :persistent_term.get(@atom_budget_key, nil) do
      nil ->
        :persistent_term.put(@atom_budget_key, :atomics.new(1, []))
        :persistent_term.get(@atom_budget_key)

      counter ->
        counter
    end
  end

  # McpConfig servers carry string names and an env MAP; the bundle spec wants
  # an atom name and an env LIST. `admit/2` has already bounded the count, the
  # shape and the atom, so the name is interned by the time it gets here and
  # `to_existing_atom` is the assertion that it was. A remote server's keys are
  # carried across as they were parsed, including `:source`, which is what
  # decides whether its header references may resolve; a spec that somehow
  # carries both transports keeps both keys so `McpBundle` refuses it by name
  # rather than this function picking one.
  defp to_spec(server) do
    %{
      name: String.to_existing_atom(server.name),
      source: Map.get(server, :source, :workspace)
    }
    |> put_stdio(server)
    |> put_remote(server)
  end

  defp put_stdio(spec, %{command: command} = server) do
    Map.merge(spec, %{
      command: command,
      args: Map.get(server, :args, []),
      env: server |> Map.get(:env, %{}) |> Map.to_list()
    })
  end

  defp put_stdio(spec, _server), do: spec

  defp put_remote(spec, %{url: url} = server) do
    spec
    |> Map.merge(%{
      url: url,
      headers: Map.get(server, :headers, []),
      metered: Map.get(server, :metered, false),
      prices: Map.get(server, :prices, %{})
    })
    |> put_concurrency(server)
  end

  defp put_remote(spec, _server), do: spec

  defp put_concurrency(spec, %{concurrency: policy}),
    do: Map.put(spec, :concurrency, policy)

  defp put_concurrency(spec, _server), do: spec

  defmodule Janitor do
    @moduledoc false
    # Owns the MCP client processes for one coding session. Starts each client
    # linked to itself (so it can bring them down together), traps their exits
    # (so a crashing server does not cascade), and monitors the session
    # process. It is a TaskSupervisor child, so it outlives the short-lived
    # loader task while remaining inside the agent supervision tree.

    @spec start(GenServer.server(), pid(), (keyword() -> {:ok, pid()} | {:error, term()})) ::
            pid()
    def start(supervisor, owner, client_start) do
      case Task.Supervisor.start_child(supervisor, fn -> init(owner, client_start) end) do
        {:ok, pid} -> pid
        {:error, reason} -> exit({:janitor_start_failed, reason})
      end
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
        message -> handle_message(message, state)
      end
    end

    defp handle_message({:start_client, from, ref, client_opts}, state) do
      reply = state.client_start.(client_opts)

      state =
        case reply do
          {:ok, pid} -> %{state | clients: [pid | state.clients]}
          _error -> state
        end

      send(from, {ref, reply})
      loop(state)
    end

    defp handle_message({:DOWN, mon, :process, _pid, _reason}, %{owner_mon: mon} = state) do
      # The session ended: stop every client (and its OS subprocess),
      # then exit. A :normal janitor exit would not cascade over the
      # links, so termination is explicit.
      terminate_clients(state.clients)
    end

    defp handle_message({:EXIT, pid, reason}, state) do
      if pid in state.clients do
        # A client crashed (or was stopped): forget it, do not cascade.
        loop(%{state | clients: List.delete(state.clients, pid)})
      else
        # Do not trap the TaskSupervisor's shutdown. Its lifecycle owns
        # this janitor, so first stop the clients and honor the signal.
        terminate_clients(state.clients)
        exit(reason)
      end
    end

    defp handle_message(:stop, state), do: terminate_clients(state.clients)
    defp handle_message(_other, state), do: loop(state)

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
