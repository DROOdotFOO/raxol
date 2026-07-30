defmodule Raxol.Console.Boot do
  @moduledoc """
  Boot a Console runtime from a `Raxol.Console.RuntimeConfig`.

  `start/2` brings up `Raxol.Console.Supervisor` (the scheduler wired with the
  agent's persona + delivery, plus a reconciler) and returns a boot report.
  `reconcile_jobs/2` is the convergence step: it makes a running scheduler's job
  set match the desired `tasks.json` jobs, keyed by task name (the stable id), so
  a reboot updates and prunes rather than duplicating (the scheduler is
  DETS-persisted and replays on start).
  """

  alias Raxol.Agent.{McpBundle, Scheduler}

  @type jobs_report :: %{
          created: [String.t()],
          updated: [String.t()],
          removed: [String.t()]
        }

  @type report :: %{
          supervisor: pid(),
          jobs: jobs_report(),
          mcp: %{tools: non_neg_integer(), failed: [{atom(), term()}]},
          channels: [atom()]
        }

  @doc """
  Start the Console runtime tree for `runtime_config` and reconcile its jobs.

  Options are forwarded to `Raxol.Console.Supervisor` (`:adapters`,
  `:scheduler_name`, `:reconciler_name`, `:name`). Returns `{:ok, report}` with
  the supervisor pid and the reconciliation result.
  """
  @spec start(Raxol.Console.RuntimeConfig.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def start(runtime_config, opts \\ []) do
    reconciler = Keyword.get(opts, :reconciler_name, Raxol.Console.Reconciler)

    # Start the bundled MCP servers and surface their tools; they join the chat
    # handler's `:actions` so a chat turn (ReAct) can call them.
    mcp = McpBundle.load(runtime_config.mcp_servers, mcp_load_opts(opts))
    actions = Keyword.get(opts, :actions, []) ++ mcp.tools

    with {:ok, adapters} <- connect_channels(runtime_config.channels) do
      sup_opts =
        opts
        |> Keyword.put(:runtime_config, runtime_config)
        |> Keyword.put(:adapters, adapters)
        |> put_gateway(runtime_config, adapters, actions, opts)

      case Raxol.Console.Supervisor.start_link(sup_opts) do
        {:ok, sup} ->
          {:ok,
           %{
             supervisor: sup,
             jobs: Raxol.Console.Reconciler.report(reconciler),
             mcp: %{tools: length(mcp.tools), failed: mcp.failed},
             channels: Map.keys(adapters)
           }}

        {:error, _} = error ->
          error
      end
    end
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

  defp mcp_load_opts(opts) do
    case Keyword.get(opts, :mcp_start) do
      fun when is_function(fun, 1) -> [start: fun]
      _ -> []
    end
  end

  # Build the gateway subtree opts only when at least one channel is connected;
  # a headless (scheduler-only) runtime skips it. The chat handler runs the
  # agent's persona + the combined toolset, and outbound goes through the same
  # adapters map the scheduler delivers to.
  defp put_gateway(sup_opts, _rc, adapters, _actions, _opts) when map_size(adapters) == 0,
    do: sup_opts

  defp put_gateway(sup_opts, rc, adapters, actions, opts) do
    base = Keyword.get(opts, :name, Raxol.Console)

    handler =
      {Raxol.Gateway.Handler.Agent,
       [
         system_prompt: rc.system_prompt,
         agent_opts: Keyword.put(rc.agent_opts, :actions, actions)
       ]}

    gateway = [
      handler: handler,
      deliver: fn route, rendered ->
        Raxol.Gateway.Delivery.deliver(adapters, {:direct, route}, rendered)
      end,
      name: gw_name(base, "gateway"),
      router_name: gw_name(base, "router"),
      pairing_name: gw_name(base, "pairing"),
      sessions_sup: gw_name(base, "sessions")
    ]

    Keyword.put(sup_opts, :gateway, gateway)
  end

  defp gw_name(base, suffix), do: :"#{base}.#{suffix}"

  @doc """
  Converge the scheduler's jobs to `desired`.

  Creates jobs missing from the scheduler, updates ones whose definition changed
  (prompt / schedule / target / enabled / skills), and removes ones no longer
  desired. Returns the ids in each bucket.
  """
  @spec reconcile_jobs(GenServer.server(), [map()]) :: jobs_report()
  def reconcile_jobs(server, desired) when is_list(desired) do
    existing = server |> Scheduler.list() |> Map.new(&{&1.id, &1})
    desired_ids = MapSet.new(desired, & &1.id)

    {created, updated} =
      Enum.reduce(desired, {[], []}, fn job, {created, updated} ->
        case Map.get(existing, job.id) do
          nil ->
            {:ok, _} = Scheduler.create(server, job)
            {[job.id | created], updated}

          current ->
            if changed?(current, job) do
              {:ok, _} = Scheduler.update(server, job.id, Map.delete(job, :id))
              {created, [job.id | updated]}
            else
              {created, updated}
            end
        end
      end)

    removed =
      existing
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(desired_ids, &1))
      |> Enum.map(fn id ->
        :ok = Scheduler.remove(server, id)
        id
      end)

    %{created: Enum.reverse(created), updated: Enum.reverse(updated), removed: Enum.sort(removed)}
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
