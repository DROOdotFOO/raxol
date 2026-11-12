defmodule Raxol.Agent.McpTools do
  @moduledoc """
  Raxol agents as MCP tools: a client starts agents in this BEAM, asks them,
  and stops them. They live as long as the BEAM; their journals persist.

    * `agent_spawn {app, id}` - start an allowlisted app as agent `id`
    * `agent_list` - the agents this server answers for, and the apps it starts
    * `agent_ask {id, message, timeout_ms}` - `Raxol.Agent.Comm.call/3`
    * `agent_status {id}`, `agent_stop {id}`
    * resource `raxol://agent/<id>/journal` - the agent's journal

  ## Registration

  This process registers the tools with `Raxol.MCP.Registry` when it starts
  and owns them, so they leave the registry with it. It registers only when
  the registry is running at that moment (the `:mcp` startup mode, where the
  MCP tree is up before `:raxol_agent` starts) and
  `config :raxol_agent, :mcp_tools` is not `false`; otherwise it runs with no
  tools registered.

  ## Spawnable apps

  `config :raxol_agent, :mcp_spawnable_apps` lists the modules `agent_spawn`
  may start (default `[Raxol.Agent.Reference.Counter]`). The `app` argument is
  compared with their names as strings and never turned into an atom.

  ## Ownership

  The tools and the journal resource act only on agents this process started,
  which it keeps in an ETS table it owns. An agent started some other way is
  refused, unless its id is in `config :raxol_agent, :mcp_exposed_agents` (a
  list of binary ids). A stopped agent leaves `agent_list` and its id can be
  spawned again; its journal stays readable. A team member is refused by
  `agent_status` and `agent_stop`.

  ## Journals

  An agent is started with `journal_required: true` (see
  `Raxol.Agent.EmitBridge`): it does not start unless its journal is opened,
  private and locked. Journals live under
  `<sessions dir>/<first 8 hex of sha256(root)>/<id>` and record the project
  root and the app in `meta.json`; a journal recorded for another root or app
  is not continued. Spawning an id again continues its journal while the
  model starts from `init/1`.

  The root is the BEAM's working directory unless
  `config :raxol_agent, :mcp_project_root` names it (a path, or
  `{module, function, args}` returning `{:ok, path}`). Where one working
  directory serves several projects, they share journals: an `id` spawned in
  one continues the journal another wrote. `agent_spawn` and `agent_status`
  name the root in use.

  `agent_spawn` is refused on Windows, where the journal has no cross-process
  writer lock (#1299).
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Comm
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Agent.Session

  @table __MODULE__
  @registry Raxol.Agent.Registry

  @id_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @id_rule "an id is 1-64 characters of A-Z a-z 0-9 . _ - and starts with a letter or digit"
  @max_timeout_ms 25_000
  @journal_tail 200
  @uri_prefix "raxol://agent/"
  @uri_suffix "/journal"
  @not_running "agents are not running in this server"

  # -- API ----------------------------------------------------------------------

  @doc """
  Start the server. `:registry` and `:server` name the `Raxol.MCP.Registry`
  it registers with and the `Raxol.MCP.Server` it notifies (default: the
  application's).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Start the allowlisted app named `app` as agent `id`, owned by this server.
  Returns the root the journal is bound to and `continued`, the number of
  events the journal already held.
  """
  @spec spawn_agent(String.t(), String.t()) ::
          {:ok, %{id: String.t(), app: module(), root: Path.t(), continued: non_neg_integer()}}
          | {:error, String.t()}
  def spawn_agent(app, id) when is_binary(app) and is_binary(id), do: call({:spawn, app, id})

  @doc "Stop agent `id` if this server owns it or it is exposed."
  @spec stop_agent(String.t()) :: :ok | {:error, String.t()}
  def stop_agent(id) when is_binary(id), do: call({:stop, id})

  @doc "The names `agent_spawn` accepts as `app`."
  @spec spawnable() :: [String.t()]
  def spawnable do
    for module <- Application.get_env(:raxol_agent, :mcp_spawnable_apps, default_apps()),
        is_atom(module),
        do: inspect(module)
  end

  @doc "The journal resource URI of agent `id`."
  @spec journal_uri(String.t()) :: String.t()
  def journal_uri(id), do: @uri_prefix <> id <> @uri_suffix

  @doc "Whether `uri` is an agent journal URI (of any id)."
  @spec journal_uri?(term()) :: boolean()
  def journal_uri?(@uri_prefix <> rest) do
    String.ends_with?(rest, @uri_suffix) and
      Regex.match?(@id_format, String.replace_suffix(rest, @uri_suffix, ""))
  end

  def journal_uri?(_uri), do: false

  @doc false
  @spec platform_refusal({atom(), atom()}) :: :ok | {:error, String.t()}
  def platform_refusal({:win32, _name}),
    do:
      {:error,
       "agent_spawn is not available on Windows: the journal has no " <>
         "cross-process writer lock there (#1299)"}

  def platform_refusal(_os_type), do: :ok

  @doc "The tool definitions."
  @spec tools() :: [map()]
  def tools, do: [spawn_def(), list_def(), ask_def(), status_def(), stop_def()]

  defp spawn_def do
    %{
      name: "agent_spawn",
      description:
        "Starts an agent in this server under an id you choose. Spawning an " <>
          "id again continues its journal; its state starts fresh. " <>
          "agent_list names the apps.",
      inputSchema: %{
        type: "object",
        required: ["app", "id"],
        properties: %{
          app: %{type: "string", description: "App name, from agent_list"},
          id: %{type: "string", description: "Agent id: " <> @id_rule}
        }
      },
      annotations: %{sensitive: true},
      callback: &spawn_tool/1,
      fault?: &fault?/1
    }
  end

  defp list_def do
    %{
      name: "agent_list",
      description: "Lists the agents this server answers for and the apps agent_spawn starts.",
      inputSchema: %{type: "object", properties: %{}},
      callback: &list_tool/1,
      fault?: &fault?/1
    }
  end

  defp ask_def do
    %{
      name: "agent_ask",
      description: "Sends an agent a message and returns its reply.",
      inputSchema: %{
        type: "object",
        required: ["id", "message"],
        properties: %{
          id: %{type: "string", description: "Agent id"},
          message: %{type: "string", description: "The message"},
          timeout_ms: %{
            type: "integer",
            minimum: 1,
            maximum: @max_timeout_ms,
            description: "How long to wait for the reply (default #{@max_timeout_ms})"
          }
        }
      },
      annotations: %{sensitive: true},
      callback: &ask_tool/1,
      fault?: &fault?/1
    }
  end

  defp status_def do
    %{
      name: "agent_status",
      description: "Reports an agent's app, state, journal root and journal size.",
      inputSchema: id_schema(),
      callback: &status_tool/1,
      fault?: &fault?/1
    }
  end

  defp stop_def do
    %{
      name: "agent_stop",
      description: "Stops an agent. Its journal stays readable.",
      inputSchema: id_schema(),
      annotations: %{sensitive: true},
      callback: &stop_tool/1,
      fault?: &fault?/1
    }
  end

  defp id_schema do
    %{
      type: "object",
      required: ["id"],
      properties: %{id: %{type: "string", description: "Agent id"}}
    }
  end

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

    state = %{
      registry: Keyword.get(opts, :registry, Raxol.MCP.Registry),
      mcp_server: Keyword.get(opts, :server, Raxol.MCP.Server),
      monitors: %{},
      published: MapSet.new()
    }

    {:ok, register(state)}
  end

  @impl GenServer
  def handle_call({:spawn, app, id}, _from, state) do
    with :ok <- platform_refusal(:os.type()),
         :ok <- validate_id(id),
         {:ok, module} <- spawnable_app(app),
         :ok <- id_free(id),
         {:ok, root} <- project_root(),
         {:ok, started, state} <- start(state, module, id, root) do
      {:reply, {:ok, started}, state}
    else
      {:error, _message} = refusal -> {:reply, refusal, state}
    end
  end

  def handle_call({:stop, id}, _from, state) do
    case stoppable(id) do
      {:ok, session_id} ->
        _ = Session.Supervisor.stop_session(session_id)
        # The registry forgets a stopped session a moment after it is gone,
        # and the id is free only then.
        Session.await_free(id)
        Session.await_free({:session_supervisor, session_id})
        {:reply, :ok, stopped(state, id)}

      {:error, _message} = refusal ->
        {:reply, refusal, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, mref, :process, _sup, _reason}, state) do
    case state.monitors do
      %{^mref => id} -> {:noreply, stopped(state, id)}
      _unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Registration -------------------------------------------------------------

  # `:registered?` decides whether a spawned agent's journal is published.
  defp register(state) do
    if Application.get_env(:raxol_agent, :mcp_tools, true) != false and
         GenServer.whereis(state.registry) != nil do
      state.registry
      |> Raxol.MCP.Registry.register_tools(tools(), owner: self())
      |> warn_on_refused_tools()

      exposed = exposed()
      register_resources(state, Enum.map(exposed, &journal_resource/1))
      state |> Map.put(:published, MapSet.new(exposed)) |> Map.put(:registered?, true)
    else
      Map.put(state, :registered?, false)
    end
  end

  defp warn_on_refused_tools(:ok), do: :ok

  defp warn_on_refused_tools({:error, {:name_collision, collisions}}) do
    Logger.warning(
      "[Agent.McpTools] tools refused (their client-side names are taken): " <>
        inspect(collisions)
    )
  end

  defp warn_on_refused_tools({:error, {:invalid_tool_name, name}}) do
    Logger.warning(
      "[Agent.McpTools] tools refused (a tool name is not a binary): #{inspect(name)}"
    )
  end

  defp register_resources(_state, []), do: :ok

  defp register_resources(state, resources),
    do: Raxol.MCP.Registry.register_resources(state.registry, resources, owner: self())

  # A resource registered while a call runs: the client is told the list
  # changed, as it is for tools.
  defp publish_journal(%{registered?: true} = state, id) do
    if MapSet.member?(state.published, id) do
      state
    else
      register_resources(state, [journal_resource(id)])
      Raxol.MCP.Server.notify(state.mcp_server, "notifications/resources/list_changed", %{})
      %{state | published: MapSet.put(state.published, id)}
    end
  end

  defp publish_journal(state, _id), do: state

  defp journal_resource(id) do
    %{
      uri: journal_uri(id),
      name: "Agent #{id} journal",
      description: "The last #{@journal_tail} journal records of agent #{id}.",
      callback: fn -> read_journal(id) end,
      fault?: &fault?/1
    }
  end

  # A refusal is an answer, not a fault of the tool: it must not open the
  # registry's circuit breaker for every agent.
  defp fault?(reason), do: not is_binary(reason)

  # -- Spawn --------------------------------------------------------------------

  defp validate_id(id) do
    if Regex.match?(@id_format, id), do: :ok, else: {:error, @id_rule}
  end

  defp spawnable_app(app) do
    modules = Application.get_env(:raxol_agent, :mcp_spawnable_apps, default_apps())

    case Enum.find(modules, &(is_atom(&1) and app in [inspect(&1), Atom.to_string(&1)])) do
      nil -> {:error, "app #{app} is not spawnable; spawnable: #{names(spawnable())}"}
      module -> {:ok, module}
    end
  end

  defp default_apps, do: [Raxol.Agent.Reference.Counter]

  defp names([]), do: "none"
  defp names(names), do: Enum.join(names, ", ")

  defp id_free(id) do
    case Registry.lookup(@registry, id) do
      [] -> :ok
      [_holder] -> {:error, in_use(id)}
    end
  rescue
    ArgumentError -> {:error, @not_running}
  end

  defp in_use(id) do
    case team_of(id) do
      nil -> "id #{id} in use"
      team -> "id #{id} in use (team #{team})"
    end
  end

  defp project_root do
    configured =
      case Application.get_env(:raxol_agent, :mcp_project_root) do
        nil -> File.cwd()
        root when is_binary(root) -> {:ok, root}
        {module, function, args} -> apply(module, function, args)
        _other -> :error
      end

    case configured do
      {:ok, root} when is_binary(root) ->
        {:ok, Path.expand(root)}

      _unknown ->
        {:error, "the project root is not known (config :raxol_agent, :mcp_project_root)"}
    end
  end

  defp journal_base(root) do
    :sha256
    |> :crypto.hash(root)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
    |> FileStore.session_dir()
  end

  defp start(state, module, id, root) do
    base_dir = journal_base(root)
    continued = FileStore.high_watermark(id, base_dir: base_dir)

    started =
      Session.Supervisor.start_session(module,
        id: id,
        session_id: id,
        journal_required: true,
        journal_opts: [base_dir: base_dir, cwd: root, title: inspect(module)]
      )

    case started do
      {:ok, sup} ->
        mref = Process.monitor(sup)
        :ets.insert(@table, {id, :running, %{app: module, root: root, base_dir: base_dir}})
        state = publish_journal(state, id)

        {:ok, %{id: id, app: module, root: root, continued: continued},
         %{state | monitors: Map.put(state.monitors, mref, id)}}

      {:error, reason} ->
        {:error, start_refusal(id, base_dir, reason)}
    end
  end

  defp start_refusal(id, base_dir, {:journal_locked, :lock_unavailable}),
    do: "no journal lock could be taken (#{lock(id, base_dir)}); agent #{id} was not started"

  defp start_refusal(id, base_dir, {:journal_locked, holder}),
    do:
      "journal #{id} is locked by pid #{holder} (#{lock(id, base_dir)}); " <>
        "a server that is still exiting releases it, so retry"

  defp start_refusal(id, _base_dir, {:journal_bound, %{field: :cwd, journal: root}}),
    do: "journal #{id} belongs to project root #{root || "(none recorded)"}"

  defp start_refusal(id, _base_dir, {:journal_bound, %{field: :title, journal: app}}),
    do: "journal #{id} belongs to app #{app || "(none recorded)"}"

  defp start_refusal(id, _base_dir, {:journal_damaged, _session}),
    do: "journal #{id} is damaged and is not continued"

  defp start_refusal(id, _base_dir, {:already_started, _pid}), do: in_use(id)
  defp start_refusal(_id, _base_dir, :registry_not_running), do: @not_running
  defp start_refusal(_id, _base_dir, :dynsup_not_running), do: @not_running

  defp start_refusal(id, _base_dir, reason),
    do: "agent #{id} did not start: #{inspect(reason)}"

  defp lock(id, base_dir), do: Writer.lock_path(Path.join(base_dir, id))

  # -- Ownership ----------------------------------------------------------------

  # `{:owned, status, info}` for an agent this server started, `{:exposed,
  # session_id, meta}` for a running agent the configuration exposes.
  defp target(id) do
    case owned(id) do
      {status, info} -> {:owned, status, info}
      nil -> exposed_target(id)
    end
  end

  defp owned(id) do
    case :ets.lookup(@table, id) do
      [{^id, status, info}] -> {status, info}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp exposed_target(id) do
    with true <- id in exposed(),
         {session_id, meta} <- session_of(id) do
      {:exposed, session_id, meta}
    else
      _ -> :none
    end
  end

  defp exposed do
    for id <- Application.get_env(:raxol_agent, :mcp_exposed_agents, []), is_binary(id), do: id
  end

  defp sessions do
    Registry.select(@registry, [{{{:session, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  defp session_of(id) do
    Enum.find(sessions(), fn {_session_id, meta} -> Map.get(meta, :id) == id end)
  end

  defp team_of(id) do
    case session_of(id) do
      {_session_id, meta} -> Map.get(meta, :team_id)
      nil -> nil
    end
  end

  defp not_owned(id), do: "no agent #{id} was started by this server"
  defp stopped_refusal(id), do: "agent #{id} is stopped; agent_spawn starts it again"

  defp refuse_team_member(id, tool) do
    case team_of(id) do
      nil -> :ok
      team -> {:error, "#{id} is a member of team #{team}; use #{tool}"}
    end
  end

  defp stoppable(id) do
    case target(id) do
      {:owned, :running, _info} ->
        with :ok <- refuse_team_member(id, "team_stop"), do: {:ok, id}

      {:owned, :stopped, _info} ->
        {:error, stopped_refusal(id)}

      {:exposed, session, _} ->
        with :ok <- refuse_team_member(id, "team_stop"), do: {:ok, session}

      :none ->
        {:error, not_owned(id)}
    end
  end

  defp stopped(state, id) do
    {monitors, kept} = Enum.split_with(state.monitors, fn {_mref, owned} -> owned == id end)
    Enum.each(monitors, fn {mref, _id} -> Process.demonitor(mref, [:flush]) end)

    case owned(id) do
      {:running, info} -> :ets.insert(@table, {id, :stopped, info})
      _exposed_or_stopped -> true
    end

    %{state | monitors: Map.new(kept)}
  end

  # -- Tool callbacks (run in the MCP server's callback workers) ----------------

  defp spawn_tool(%{"app" => app, "id" => id}) when is_binary(app) and is_binary(id) do
    with {:ok, %{app: module, root: root, continued: continued}} <- spawn_agent(app, id) do
      {:ok,
       "started #{id} (#{inspect(module)}); journal root #{root}; #{journal_note(continued)}"}
    end
  end

  defp spawn_tool(_arguments), do: {:error, "app and id are required strings"}

  defp journal_note(0), do: "new journal"
  defp journal_note(count), do: "continued #{count} events"

  defp list_tool(_arguments) do
    owned =
      for {id, :running, info} <- rows(),
          do: %{id: id, app: inspect(info.app), root: info.root, team: team_of(id)}

    exposed =
      for id <- exposed(),
          {_session_id, meta} <- List.wrap(session_of(id)),
          do: %{id: id, app: inspect(meta.app_module), root: nil, team: Map.get(meta, :team_id)}

    {:ok, Jason.encode!(%{agents: owned ++ exposed, spawnable: spawnable()}, pretty: true)}
  end

  defp rows do
    :ets.tab2list(@table)
  rescue
    ArgumentError -> []
  end

  defp ask_tool(%{"id" => id, "message" => message} = arguments)
       when is_binary(id) and is_binary(message) do
    with {:ok, timeout_ms} <- timeout_ms(arguments),
         :ok <- askable(id) do
      ask(id, message, timeout_ms)
    end
  end

  defp ask_tool(_arguments), do: {:error, "id and message are required strings"}

  defp timeout_ms(%{"timeout_ms" => ms}) when is_integer(ms) and ms in 1..@max_timeout_ms,
    do: {:ok, ms}

  defp timeout_ms(%{"timeout_ms" => _other}),
    do: {:error, "timeout_ms is an integer from 1 to #{@max_timeout_ms}"}

  defp timeout_ms(_arguments), do: {:ok, @max_timeout_ms}

  defp askable(id) do
    case target(id) do
      {:owned, :running, _info} -> :ok
      {:owned, :stopped, _info} -> {:error, stopped_refusal(id)}
      {:exposed, _session_id, _meta} -> :ok
      :none -> {:error, not_owned(id)}
    end
  end

  defp ask(id, message, timeout_ms) do
    case Comm.call(id, message, timeout_ms) do
      {:ok, reply} when is_binary(reply) ->
        {:ok, reply}

      {:ok, reply} ->
        {:ok, inspect(reply, pretty: true, limit: 100)}

      {:error, :timeout} ->
        {:error, "agent #{id} did not reply within #{timeout_ms} ms (timeout)"}

      {:error, :agent_down} ->
        {:error, "agent #{id} went down before it replied"}

      {:error, :not_found} ->
        {:error, "agent #{id} is not running"}
    end
  end

  defp status_tool(%{"id" => id}) when is_binary(id) do
    with {:ok, {state, app, root, session_id, journal_opts}} <- status_of(id, target(id)) do
      {:ok,
       Jason.encode!(
         %{
           id: id,
           app: inspect(app),
           state: state,
           root: root,
           journal: %{
             uri: journal_uri(id),
             events: FileStore.high_watermark(session_id, journal_opts)
           }
         },
         pretty: true
       )}
    end
  end

  defp status_tool(_arguments), do: {:error, "id is a required string"}

  defp status_of(id, {:owned, :running, info}) do
    with :ok <- refuse_team_member(id, "team_list"),
         do: {:ok, {live_state(id), info.app, info.root, id, [base_dir: info.base_dir]}}
  end

  defp status_of(id, {:owned, :stopped, info}),
    do: {:ok, {"stopped", info.app, info.root, id, [base_dir: info.base_dir]}}

  defp status_of(id, {:exposed, session_id, meta}) do
    with :ok <- refuse_team_member(id, "team_list"),
         do: {:ok, {"running", meta.app_module, nil, session_id, []}}
  end

  defp status_of(id, :none), do: {:error, not_owned(id)}

  defp live_state(id) do
    if is_pid(Session.Supervisor.whereis(id)), do: "running", else: "restarting"
  end

  defp stop_tool(%{"id" => id}) when is_binary(id) do
    with :ok <- stop_agent(id), do: {:ok, "stopped #{id}; its journal stays readable"}
  end

  defp stop_tool(_arguments), do: {:error, "id is a required string"}

  # The resource handler. Ownership is decided here, on every read, not by
  # the fact that the resource is registered.
  defp read_journal(id) do
    case target(id) do
      {:owned, _status, info} -> journal(id, info.root, id, base_dir: info.base_dir)
      {:exposed, session_id, _meta} -> journal(id, nil, session_id, [])
      :none -> {:error, not_owned(id)}
    end
  end

  defp journal(id, root, session_id, journal_opts) do
    case FileStore.read_records(session_id, journal_opts) do
      {:ok, records} ->
        {:ok,
         %{
           id: id,
           root: root,
           events: length(records),
           records: Enum.take(records, -@journal_tail)
         }}

      {:error, :damaged} ->
        {:error, "journal #{id} is damaged"}
    end
  end

  defp call(request) do
    GenServer.call(__MODULE__, request, :infinity)
  catch
    :exit, {:noproc, _call} -> {:error, @not_running}
  end
end
