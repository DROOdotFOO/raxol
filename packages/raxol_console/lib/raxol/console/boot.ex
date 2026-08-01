defmodule Raxol.Console.Boot do
  @moduledoc """
  Boot a Console runtime from a `Raxol.Console.RuntimeConfig`.

  `start/2` brings up `Raxol.Console.Supervisor` (the scheduler wired with the
  agent's persona + delivery, a reconciler, and -- when the package ships skills
  -- a `Raxol.Agent.Skills.Store` over them) and returns a boot report.
  `reconcile_jobs/2` is the convergence step: it makes a running scheduler's job
  set match the desired `tasks.json` jobs, keyed by task name (the stable id), so
  a reboot updates and prunes rather than duplicating (the scheduler is
  DETS-persisted and replays on start). A failed job op is recorded in the
  report's `:failed` bucket rather than raised, so one bad task cannot crash the
  reconciler (and, under `:rest_for_one`, hot-loop the whole tree).

  Bundled MCP servers, when present, run under a dedicated `DynamicSupervisor`
  (returned as `:mcp_supervisor`) that `Raxol.Console.Supervisor` starts as its
  own child, so it is torn down when the runtime stops and never leaks on the
  boot caller; a crashed server client is restarted by it rather than left
  dangling. Boot is two-phase: it starts the tree (with the empty MCP supervisor)
  first, then loads the servers into it and starts the gateway last, so the chat
  handler captures the resolved tools.
  """

  alias Raxol.Agent.{McpBundle, Scheduler}

  # Read-only skill access surfaced to the chat agent when the package ships
  # skills: the agent can list/view them on demand (skill authoring stays a
  # deployment opt-in via its own `:actions`).
  @skill_actions [Raxol.Agent.Actions.Skills.List, Raxol.Agent.Actions.Skills.View]

  @type jobs_report :: %{
          created: [String.t()],
          updated: [String.t()],
          removed: [String.t()],
          failed: [{String.t(), term()}]
        }

  @type report :: %{
          supervisor: pid(),
          mcp_supervisor: pid() | nil,
          jobs: jobs_report(),
          mcp: %{tools: non_neg_integer(), failed: [{atom(), term()}]},
          channels: [atom()],
          skills: %{store: atom() | nil, count: non_neg_integer()}
        }

  @doc """
  Start the Console runtime tree for `runtime_config` and reconcile its jobs.

  Options forwarded to `Raxol.Console.Supervisor` (`:name`, `:scheduler_name`,
  `:reconciler_name`, `:adapters`, `:actions`). A `:skills_dir` (an absolute path
  to the package's `skills/` directory) activates a per-Console skills store over
  it. Returns `{:ok, report}`.
  """
  @spec start(Raxol.Console.RuntimeConfig.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def start(runtime_config, opts \\ []) do
    base = Keyword.get(opts, :name, Raxol.Console)
    skills = resolve_skills(opts, base)
    mcp_name = name(base, "mcp")

    with {:ok, adapters} <- connect_channels(runtime_config.channels),
         core_opts = core_sup_opts(opts, runtime_config, adapters, skills, mcp_name),
         {:ok, sup} <- Raxol.Console.Supervisor.start_link(core_opts) do
      # Phase two: the tree (incl. the empty MCP DynamicSupervisor, owned by the
      # root supervisor so its lifecycle is the runtime's) is up. Load servers
      # into that supervised MCP subtree, then start the gateway last, so its chat
      # handler captures the resolved tools. A phase-two failure tears the tree
      # (and the MCP subtree with it) down rather than leaving it half-booted.
      mcp = load_mcp(runtime_config, opts, mcp_name)
      mcp_sup = mcp_supervisor_pid(runtime_config, mcp_name)
      actions = Keyword.get(opts, :actions, []) ++ mcp.tools

      case start_gateway(sup, runtime_config, adapters, actions, base, skills) do
        :ok -> {:ok, report(sup, mcp_sup, mcp, adapters, skills, opts)}
        {:error, _} = error -> stop_supervisor(sup) && error
      end
    end
  end

  # The core supervisor opts: everything the tree starts synchronously at init --
  # the (empty) MCP DynamicSupervisor when servers are bundled, the skills store,
  # the scheduler, and the reconciler. The gateway is NOT here; it is added after
  # MCP tools resolve (see `start_gateway/6`).
  defp core_sup_opts(opts, runtime_config, adapters, skills, mcp_name) do
    opts
    |> Keyword.put(:runtime_config, runtime_config)
    |> Keyword.put(:adapters, adapters)
    |> Keyword.put(:mcp_supervisor_name, mcp_enabled_name(runtime_config, mcp_name))
    |> put_skills(skills)
  end

  defp mcp_enabled_name(%{mcp_servers: []}, _mcp_name), do: nil
  defp mcp_enabled_name(_rc, mcp_name), do: mcp_name

  defp mcp_supervisor_pid(%{mcp_servers: []}, _mcp_name), do: nil
  defp mcp_supervisor_pid(_rc, mcp_name), do: Process.whereis(mcp_name)

  defp report(sup, mcp_sup, mcp, adapters, skills, opts) do
    reconciler = Keyword.get(opts, :reconciler_name, Raxol.Console.Reconciler)

    %{
      supervisor: sup,
      mcp_supervisor: mcp_sup,
      jobs: Raxol.Console.Reconciler.report(reconciler),
      mcp: %{tools: length(mcp.tools), failed: mcp.failed},
      channels: Map.keys(adapters),
      skills: skills_report(skills)
    }
  end

  @doc """
  Connect each channel spec (`%{platform:, adapter:, config:}`) into the gateway
  adapters map `%{platform => {module, conn}}`, used for both chat replies and
  scheduled-task delivery. `{:error, {platform, reason}}` on the first failure.
  """
  @spec connect_channels([map()]) :: {:ok, map()} | {:error, term()}
  def connect_channels(channels) when is_list(channels) do
    Enum.reduce_while(channels, {:ok, %{}}, fn ch, {:ok, acc} ->
      case ch.adapter.connect(ch.config) do
        {:ok, conn} -> {:cont, {:ok, Map.put(acc, ch.platform, {ch.adapter, conn})}}
        {:error, reason} -> {:halt, {:error, {ch.platform, reason}}}
      end
    end)
  end

  def connect_channels(_), do: {:ok, %{}}

  # -- MCP servers ------------------------------------------------------------

  # Load the bundled MCP servers into the MCP DynamicSupervisor the root tree
  # already started (named `mcp_name`), so every client runs under the runtime's
  # supervision, not the transient boot caller's. An empty server set is a no-op.
  # `:mcp_start` overrides how each client is started (tests) but it still runs
  # under the supervised tree.
  defp load_mcp(%{mcp_servers: []}, _opts, _mcp_name), do: McpBundle.load([], [])

  defp load_mcp(rc, opts, mcp_name) do
    client_start = Keyword.get(opts, :mcp_start, &Raxol.MCP.Client.start_link/1)
    McpBundle.load(rc.mcp_servers, start: supervised_client_start(mcp_name, client_start))
  end

  # Wrap the client-start as a supervised child so the MCP `DynamicSupervisor`
  # (addressed by name) owns the client pid (the wrapped fn -- real
  # `MCP.Client.start_link/1` or an injected one -- runs under and links into it).
  defp supervised_client_start(mcp_name, client_start) do
    fn client_opts ->
      DynamicSupervisor.start_child(mcp_name, %{
        id: :mcp_client,
        start: {:erlang, :apply, [client_start, [client_opts]]},
        restart: :transient
      })
    end
  end

  # -- skills -----------------------------------------------------------------

  # A skills store is activated only when the deployment points at a real
  # `skills/` directory (the materialized package). Its name is derived from the
  # runtime base, so the store, scheduler, and chat handler all agree on it.
  defp resolve_skills(opts, base) do
    case Keyword.get(opts, :skills_dir) do
      dir when is_binary(dir) -> if File.dir?(dir), do: {name(base, "skills"), dir}, else: nil
      _ -> nil
    end
  end

  defp put_skills(sup_opts, nil), do: sup_opts

  defp put_skills(sup_opts, {store, dir}) do
    sup_opts
    |> Keyword.put(:skills_store, store)
    |> Keyword.put(:skills_dir, dir)
  end

  defp skills_report(nil), do: %{store: nil, count: 0}

  defp skills_report({store, _dir}),
    do: %{store: store, count: length(Raxol.Agent.Skills.Store.list(server: store))}

  # -- gateway ----------------------------------------------------------------

  # Start the gateway subtree as the LAST child of the running tree, only when at
  # least one channel is connected; a headless (scheduler-only) runtime skips it.
  # It is added dynamically (after MCP tools resolve) so the chat handler can
  # carry the combined toolset. As the last-started child under `:rest_for_one`,
  # this matches the ordering a static gateway child would have had. The chat
  # handler runs the agent's persona + the combined toolset (read-only skill
  # access + the skills store in context when the package ships skills), outbound
  # through the same adapters map the scheduler delivers to.
  defp start_gateway(_sup, _rc, adapters, _actions, _base, _skills)
       when map_size(adapters) == 0,
       do: :ok

  defp start_gateway(sup, rc, adapters, actions, base, skills) do
    case Supervisor.start_child(
           sup,
           {Raxol.Gateway.Supervisor, gateway_opts(rc, adapters, actions, base, skills)}
         ) do
      {:ok, _pid} -> :ok
      {:error, _} = error -> error
    end
  end

  defp gateway_opts(rc, adapters, actions, base, skills) do
    agent_opts =
      rc.agent_opts
      |> Keyword.put(:actions, skill_actions(skills) ++ actions)
      |> put_skills_context(skills)

    handler =
      {Raxol.Gateway.Handler.Agent, [system_prompt: rc.system_prompt, agent_opts: agent_opts]}

    [
      handler: handler,
      deliver: fn route, rendered ->
        Raxol.Gateway.Delivery.deliver(adapters, {:direct, route}, rendered)
      end,
      name: name(base, "gateway"),
      router_name: name(base, "router"),
      pairing_name: name(base, "pairing"),
      sessions_sup: name(base, "sessions")
    ]
  end

  defp skill_actions(nil), do: []
  defp skill_actions(_), do: @skill_actions

  defp put_skills_context(agent_opts, nil), do: agent_opts

  # The skill Actions read `context[:skills]` as a `{module, opts}` pair
  # (`mod.list(opts)`); the scheduler's `Fire` wants the bare server name. Hence
  # two shapes for the two consumers.
  defp put_skills_context(agent_opts, {store, _dir}) do
    skills = {Raxol.Agent.Skills.Store, [server: store]}
    context = agent_opts |> Keyword.get(:context, %{}) |> Map.put(:skills, skills)
    Keyword.put(agent_opts, :context, context)
  end

  defp name(base, suffix), do: :"#{base}.#{suffix}"

  defp stop_supervisor(nil), do: :ok

  defp stop_supervisor(sup) do
    Supervisor.stop(sup)
  catch
    :exit, _ -> :ok
  end

  # -- job reconciliation -----------------------------------------------------

  @doc """
  Converge the scheduler's jobs to `desired`.

  Creates jobs missing from the scheduler, updates ones whose definition changed
  (prompt / schedule / target / enabled / skills), and removes ones no longer
  desired. A scheduler op that errors lands in `:failed` (`{id, reason}`) rather
  than raising, so a single bad job cannot crash the reconciler.
  """
  @spec reconcile_jobs(GenServer.server(), [map()]) :: jobs_report()
  def reconcile_jobs(server, desired) when is_list(desired) do
    existing = server |> Scheduler.list() |> Map.new(&{&1.id, &1})
    desired_ids = MapSet.new(desired, & &1.id)

    %{created: [], updated: [], removed: [], failed: []}
    |> apply_desired(server, desired, existing)
    |> apply_removals(server, existing, desired_ids)
    |> finalize_report()
  end

  defp apply_desired(acc, server, desired, existing) do
    Enum.reduce(desired, acc, fn job, acc ->
      reconcile_one(acc, server, job, Map.get(existing, job.id))
    end)
  end

  defp reconcile_one(acc, server, job, nil),
    do: record(acc, :created, job.id, fn -> Scheduler.create(server, job) end)

  defp reconcile_one(acc, server, job, current) do
    if changed?(current, job),
      do:
        record(acc, :updated, job.id, fn ->
          Scheduler.update(server, job.id, Map.delete(job, :id))
        end),
      else: acc
  end

  defp apply_removals(acc, server, existing, desired_ids) do
    existing
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(desired_ids, &1))
    |> Enum.reduce(acc, fn id, acc ->
      record(acc, :removed, id, fn -> Scheduler.remove(server, id) end)
    end)
  end

  defp finalize_report(acc) do
    %{
      created: Enum.reverse(acc.created),
      updated: Enum.reverse(acc.updated),
      removed: Enum.sort(acc.removed),
      failed: Enum.reverse(acc.failed)
    }
  end

  # Run one scheduler op; on success add the id to `bucket`, on error record
  # `{id, reason}` in `:failed`. Accepts `:ok` (remove) and `{:ok, _}` (create /
  # update) as success.
  defp record(acc, bucket, id, fun) do
    case fun.() do
      :ok -> Map.update!(acc, bucket, &[id | &1])
      {:ok, _} -> Map.update!(acc, bucket, &[id | &1])
      {:error, reason} -> Map.update!(acc, :failed, &[{id, reason} | &1])
    end
  end

  # A live job carries the ORIGINAL schedule string as `schedule_spec` (plus a
  # parsed `schedule`); compare against the desired job's `schedule` string.
  defp changed?(current, job) do
    current.prompt != job.prompt or
      current.schedule_spec != job.schedule or
      current.target != job.target or
      current.enabled != job.enabled or
      current.skills != Map.get(job, :skills, [])
  end
end
