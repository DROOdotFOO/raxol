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

  alias Raxol.Symphony.{Evidence, Orchestrator, PathSafety}
  alias Raxol.Symphony.Evidence.Subject

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

  defp get_evidence_tool(orch) do
    %{
      name: "symphony_get_evidence",
      description: """
      Collects evidence for a Symphony run -- CI status, recent PR comments,
      code complexity, and asciinema replay refs -- by combining outputs from
      the GitHub, Complexity, and Recording backends.

      The orchestrator infers `identifier` from `issue_id` when the run is
      still tracked (running or in retry). Pass `identifier` directly to
      collect evidence for runs the orchestrator has forgotten. `repo`,
      `ref`, and `issue_number` are inferred from the workspace's git
      configuration when omitted.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          issue_id: %{
            type: "string",
            description: "Tracker-internal issue ID."
          },
          identifier: %{
            type: "string",
            description:
              "Tracker identifier (e.g. \"MT-1\"). Falls back when issue_id is unknown."
          },
          repo: %{
            type: "string",
            description: "GitHub repo as owner/name. Inferred from workspace git when omitted."
          },
          ref: %{
            type: "string",
            description: "Git ref (branch or sha). Inferred from workspace HEAD when omitted."
          },
          issue_number: %{
            type: "integer",
            description: "Numeric PR/issue number for comment lookup."
          }
        }
      },
      callback: fn args -> evidence_response(orch, args) end
    }
  end

  defp evidence_response(orch, args) do
    with {:ok, identifier} <- resolve_identifier(orch, args),
         {:ok, config} <- safe_get_config(orch),
         {:ok, workspace} <- compute_workspace(config, identifier) do
      subject = build_subject(workspace, args)
      evidence = Evidence.collect(config, subject)
      Map.put(Evidence.to_map(evidence), :status, "ok")
    else
      {:error, reason} -> %{status: "error", message: format_reason(reason)}
    end
  end

  defp resolve_identifier(orch, args) do
    explicit = args["identifier"] || args[:identifier]

    if is_binary(explicit) and byte_size(explicit) > 0 do
      {:ok, explicit}
    else
      resolve_identifier_via_snapshot(orch, args)
    end
  end

  defp resolve_identifier_via_snapshot(orch, args) do
    with {:ok, id} <- fetch_id(args),
         snapshot <- safe_snapshot(orch),
         {:ok, identifier} <- find_identifier(snapshot, id) do
      {:ok, identifier}
    else
      :error -> {:error, :issue_id_or_identifier_required}
      other -> other
    end
  end

  defp find_identifier(snapshot, id) do
    case Enum.find(snapshot.running, fn r -> r.issue_id == id end) ||
           Enum.find(snapshot.retrying, fn r -> r.issue_id == id end) do
      %{issue_identifier: identifier} when is_binary(identifier) -> {:ok, identifier}
      _ -> {:error, {:identifier_not_found, id}}
    end
  end

  defp safe_get_config(orch) do
    case safe_call(fn -> Orchestrator.get_config(orch) end) do
      {:ok, %_{} = config} -> {:ok, config}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  defp compute_workspace(config, identifier) do
    PathSafety.workspace_path(config.workspace.root, identifier)
  end

  defp build_subject(workspace, args) do
    explicit_repo = args["repo"] || args[:repo]
    explicit_ref = args["ref"] || args[:ref]
    explicit_issue = args["issue_number"] || args[:issue_number]

    workspace
    |> Subject.from_workspace()
    |> maybe_replace(:repo, explicit_repo)
    |> maybe_replace(:ref, explicit_ref)
    |> maybe_replace(:issue_number, normalize_issue_number(explicit_issue))
  end

  defp maybe_replace(subject, _key, nil), do: subject
  defp maybe_replace(subject, key, value), do: Map.put(subject, key, value)

  defp normalize_issue_number(nil), do: nil
  defp normalize_issue_number(n) when is_integer(n) and n > 0, do: n

  defp normalize_issue_number(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp normalize_issue_number(_), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

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
