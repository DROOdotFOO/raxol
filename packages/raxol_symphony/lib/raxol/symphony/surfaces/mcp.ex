defmodule Raxol.Symphony.Surfaces.MCP do
  @moduledoc """
  MCP tool + resource surface for the Symphony orchestrator.

  Exposes 5 tools and 1 resource so remote operators (and other agents)
  can introspect and control Symphony via any MCP client.

  ## Tools

  | Name                      | Args                          | Returns                              |
  |---------------------------|-------------------------------|--------------------------------------|
  | `symphony_list_runs`      | none                          | `{counts, running, retrying, codex_totals, generated_at}` |
  | `symphony_get_run`        | `{issue_id}`                  | run entry, or `{status: "not_found"}`|
  | `symphony_refresh`        | none                          | `{status: "refreshed"}`              |
  | `symphony_stop_run`       | `{issue_id}`                  | `{status: "stopped"}` or error       |
  | `symphony_get_evidence`   | `{issue_id}`                  | placeholder; full impl in Phase 14   |

  ## Resources

  | URI                | Returns                          |
  |--------------------|----------------------------------|
  | `symphony://runs`  | full snapshot of running + retrying |

  ## Registration

  The surface is registered via `register/1` after both the MCP Registry
  and the Symphony Orchestrator have started:

      Raxol.Symphony.Surfaces.MCP.register(
        registry: Raxol.MCP.Registry,
        orchestrator: Raxol.Symphony.Orchestrator
      )

  Pass `:registry` and `:orchestrator` opts to override defaults (useful in
  tests). The surface is gated on `Code.ensure_loaded?(Raxol.MCP.Registry)`
  -- when raxol_mcp is not present, `register/1` is a no-op returning `:ok`.
  """

  alias Raxol.Symphony.Orchestrator

  @compile {:no_warn_undefined, [Raxol.MCP.Registry]}

  @typedoc """
  Options accepted by `register/1`:

  - `:registry` (default `Raxol.MCP.Registry`) -- target MCP registry
  - `:orchestrator` (default `Raxol.Symphony.Orchestrator`) -- orchestrator
    server reference
  """
  @type opts :: [registry: GenServer.server(), orchestrator: GenServer.server()]

  @tool_names [
    "symphony_list_runs",
    "symphony_get_run",
    "symphony_refresh",
    "symphony_stop_run",
    "symphony_get_evidence"
  ]

  @resource_uris ["symphony://runs"]

  @doc "Returns the tool definitions, parameterised by the orchestrator reference."
  @spec tools(GenServer.server()) :: list(map())
  def tools(orchestrator) do
    [
      list_runs_tool(orchestrator),
      get_run_tool(orchestrator),
      refresh_tool(orchestrator),
      stop_run_tool(orchestrator),
      get_evidence_tool(orchestrator)
    ]
  end

  @doc "Returns the resource definitions, parameterised by the orchestrator reference."
  @spec resources(GenServer.server()) :: list(map())
  def resources(orchestrator) do
    [
      %{
        uri: "symphony://runs",
        name: "Symphony runs",
        description: "Full snapshot of active and pending Symphony runs.",
        callback: fn -> {:ok, safe_snapshot(orchestrator)} end
      }
    ]
  end

  @doc """
  Returns true when the optional `raxol_mcp` dep is loaded and the surface
  can be registered.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Raxol.MCP.Registry)

  @doc """
  Registers tools and resources with the MCP registry.

  Returns `:ok` even when `raxol_mcp` is unavailable (logs and skips).
  """
  @spec register(opts()) :: :ok | {:error, term()}
  def register(opts \\ []) do
    registry = Keyword.get(opts, :registry, Raxol.MCP.Registry)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)

    if available?() do
      :ok = Raxol.MCP.Registry.register_tools(registry, tools(orchestrator))
      :ok = Raxol.MCP.Registry.register_resources(registry, resources(orchestrator))
      :ok
    else
      :ok
    end
  end

  @doc "Unregisters all Symphony tools and resources. Useful in test teardown."
  @spec unregister(GenServer.server()) :: :ok
  def unregister(registry \\ Raxol.MCP.Registry) do
    if available?() do
      :ok = Raxol.MCP.Registry.unregister_tools(registry, @tool_names)
      :ok = Raxol.MCP.Registry.unregister_resources(registry, @resource_uris)
    end

    :ok
  end

  @doc "Names of the tools registered by this surface."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @doc "URIs of the resources registered by this surface."
  @spec resource_uris() :: [String.t()]
  def resource_uris, do: @resource_uris

  # -- Tool definitions -------------------------------------------------------

  defp list_runs_tool(orch) do
    %{
      name: "symphony_list_runs",
      description: """
      Returns a snapshot of all active Symphony runs and pending retries.
      Includes per-run state, turn count, last event, and runtime.
      Use this to enumerate work the orchestrator is currently driving.
      """,
      inputSchema: %{type: "object", properties: %{}},
      callback: fn _args -> safe_snapshot(orch) end
    }
  end

  defp get_run_tool(orch) do
    %{
      name: "symphony_get_run",
      description: """
      Returns a single run by issue ID. Run details include state, turn count,
      last event, last message, runtime, and accumulated token totals.
      Returns `{status: "not_found"}` if the issue is not currently running.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          issue_id: %{
            type: "string",
            description: "Tracker-internal issue ID (NOT the human identifier)."
          }
        },
        required: ["issue_id"]
      },
      callback: fn args ->
        case fetch_id(args) do
          {:ok, id} -> get_run_response(orch, id)
          :error -> %{status: "error", message: "issue_id required"}
        end
      end
    }
  end

  defp refresh_tool(orch) do
    %{
      name: "symphony_refresh",
      description: """
      Forces an immediate orchestrator tick (poll + dispatch) without waiting
      for the configured polling interval. Returns immediately; the tick runs
      asynchronously.
      """,
      inputSchema: %{type: "object", properties: %{}},
      callback: fn _args ->
        _ = safe_call(fn -> Orchestrator.refresh(orch) end)
        %{status: "refreshed"}
      end
    }
  end

  defp stop_run_tool(orch) do
    %{
      name: "symphony_stop_run",
      description: """
      Terminates a running issue and releases its claim. The next tick may
      re-dispatch the same issue if it is still in an active tracker state.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          issue_id: %{
            type: "string",
            description: "Tracker-internal issue ID of the run to stop."
          }
        },
        required: ["issue_id"]
      },
      callback: fn args ->
        case fetch_id(args) do
          {:ok, id} -> stop_run_response(orch, id)
          :error -> %{status: "error", message: "issue_id required"}
        end
      end
    }
  end

  defp get_evidence_tool(_orch) do
    %{
      name: "symphony_get_evidence",
      description: """
      Returns evidence for a completed run -- CI status, PR comments, complexity
      metrics, and asciinema replay refs. Currently a placeholder; full
      implementation lands in Phase 14.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          issue_id: %{type: "string", description: "Issue ID for the completed run."}
        },
        required: ["issue_id"]
      },
      callback: fn _args ->
        %{
          status: "not_implemented",
          message: "symphony_get_evidence ships in Phase 14 (evidence collection)"
        }
      end
    }
  end

  # -- Helpers ----------------------------------------------------------------

  defp fetch_id(args) when is_map(args) do
    case args["issue_id"] || args[:issue_id] do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp fetch_id(_), do: :error

  defp get_run_response(orch, id) do
    snapshot = safe_snapshot(orch)

    case find_by_issue_id(snapshot.running, id) do
      nil -> retrying_or_not_found(snapshot, id)
      run -> %{status: "running", run: run}
    end
  end

  defp retrying_or_not_found(snapshot, id) do
    case find_by_issue_id(snapshot.retrying, id) do
      nil -> %{status: "not_found", issue_id: id}
      retry -> %{status: "retrying", run: retry}
    end
  end

  defp find_by_issue_id(list, id) do
    Enum.find(list, fn run -> run.issue_id == id end)
  end

  defp stop_run_response(orch, id) do
    case safe_call(fn -> Orchestrator.stop_run(orch, id) end) do
      {:ok, :ok} ->
        %{status: "stopped", issue_id: id}

      {:ok, {:error, :not_running}} ->
        %{status: "not_running", issue_id: id}

      _ ->
        %{status: "error", issue_id: id, message: "orchestrator unavailable"}
    end
  end

  defp safe_snapshot(orch) do
    case safe_call(fn -> Orchestrator.snapshot(orch) end) do
      {:ok, %{} = snap} ->
        snap

      _ ->
        %{
          generated_at: nil,
          counts: %{running: 0, retrying: 0},
          running: [],
          retrying: [],
          codex_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 0.0
          },
          rate_limits: nil,
          orchestrator_unavailable: true
        }
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> :error
    :error, _ -> :error
  end
end
