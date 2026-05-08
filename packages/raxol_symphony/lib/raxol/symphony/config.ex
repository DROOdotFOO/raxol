defmodule Raxol.Symphony.Config do
  @moduledoc """
  Typed view over a Symphony workflow config.

  Implements SPEC s6 (Configuration Specification):

  - Built-in defaults applied for missing OPTIONAL fields.
  - `$VAR_NAME` indirection resolved only for values that explicitly contain it.
  - Path/command fields support `~` home expansion and `$VAR` expansion.
  - Relative `workspace.root` values resolve relative to the directory
    containing the workflow file.
  - `workspace.root` normalized to an absolute path.

  Validation rules live in `Raxol.Symphony.Config.Schema`.
  """

  alias Raxol.Symphony.Config.Schema

  defstruct [
    :tracker,
    :polling,
    :workspace,
    :hooks,
    :agent,
    :codex,
    :runner,
    :recording,
    :workflow_path,
    :prompt_template
  ]

  @type t :: %__MODULE__{
          tracker: map(),
          polling: map(),
          workspace: map(),
          hooks: map(),
          agent: map(),
          codex: map(),
          runner: map(),
          recording: map(),
          workflow_path: Path.t() | nil,
          prompt_template: binary()
        }

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_polling_interval_ms 30_000
  @default_hooks_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_codex_command "codex app-server"
  @default_turn_timeout_ms 3_600_000
  @default_read_timeout_ms 5_000
  @default_stall_timeout_ms 300_000
  @default_recording_width 132
  @default_recording_height 50

  @doc """
  Builds a typed config struct from a parsed workflow.

  `workflow` is the map returned by `Raxol.Symphony.Workflow.parse/1` or
  `Raxol.Symphony.Workflow.load/1`. `workflow_path` is used to resolve
  relative paths (e.g., a relative `workspace.root`).
  """
  @spec from_workflow(%{config: map(), prompt_template: binary()}, Path.t() | nil) :: t()
  def from_workflow(%{config: raw, prompt_template: prompt}, workflow_path \\ nil) do
    %__MODULE__{
      tracker: tracker(raw),
      polling: polling(raw),
      workspace: workspace(raw, workflow_path),
      hooks: hooks(raw),
      agent: agent(raw),
      codex: codex(raw),
      runner: runner(raw),
      recording: recording(raw),
      workflow_path: workflow_path,
      prompt_template: prompt
    }
  end

  @doc """
  Loads, parses, and validates a workflow file in one step.

  Returns `{:ok, config}` if valid, otherwise `{:error, reason}`.
  """
  @spec load_and_validate(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_and_validate(path) do
    with {:ok, workflow} <- Raxol.Symphony.Workflow.load(path),
         config <- from_workflow(workflow, Path.expand(path)),
         :ok <- Schema.validate(config) do
      {:ok, config}
    end
  end

  # -- Section builders -------------------------------------------------------

  defp tracker(raw) do
    section = Map.get(raw, :tracker, %{})
    kind = Map.get(section, :kind)

    %{
      kind: kind,
      endpoint: resolve_value(Map.get(section, :endpoint, default_endpoint(kind))),
      api_key: resolve_value(Map.get(section, :api_key, default_api_key_env(kind))),
      project_slug: resolve_value(Map.get(section, :project_slug)),
      active_states: Map.get(section, :active_states, @default_active_states),
      terminal_states: Map.get(section, :terminal_states, @default_terminal_states)
    }
  end

  defp default_endpoint("linear"), do: @default_linear_endpoint
  defp default_endpoint(_), do: nil

  # Per SPEC: canonical env var for tracker.kind == "linear" is LINEAR_API_KEY.
  # If api_key is unset, we still try to resolve from that env so users do not
  # have to write `api_key: $LINEAR_API_KEY` themselves.
  defp default_api_key_env("linear"), do: "$LINEAR_API_KEY"
  defp default_api_key_env("github"), do: "$GITHUB_TOKEN"
  defp default_api_key_env(_), do: nil

  defp polling(raw) do
    section = Map.get(raw, :polling, %{})

    %{
      interval_ms: Map.get(section, :interval_ms, @default_polling_interval_ms)
    }
  end

  defp workspace(raw, workflow_path) do
    section = Map.get(raw, :workspace, %{})
    raw_root = Map.get(section, :root, default_workspace_root())

    %{
      root: normalize_workspace_root(resolve_value(raw_root), workflow_path)
    }
  end

  defp default_workspace_root do
    Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  defp hooks(raw) do
    section = Map.get(raw, :hooks, %{})

    %{
      after_create: Map.get(section, :after_create),
      before_run: Map.get(section, :before_run),
      after_run: Map.get(section, :after_run),
      before_remove: Map.get(section, :before_remove),
      timeout_ms: Map.get(section, :timeout_ms, @default_hooks_timeout_ms)
    }
  end

  defp agent(raw) do
    section = Map.get(raw, :agent, %{})

    %{
      max_concurrent_agents:
        Map.get(section, :max_concurrent_agents, @default_max_concurrent_agents),
      max_turns: Map.get(section, :max_turns, @default_max_turns),
      max_retry_backoff_ms:
        Map.get(section, :max_retry_backoff_ms, @default_max_retry_backoff_ms),
      max_concurrent_agents_by_state:
        normalize_state_map(Map.get(section, :max_concurrent_agents_by_state, %{}))
    }
  end

  defp codex(raw) do
    section = Map.get(raw, :codex, %{})

    %{
      command: Map.get(section, :command, @default_codex_command),
      approval_policy: Map.get(section, :approval_policy),
      thread_sandbox: Map.get(section, :thread_sandbox),
      turn_sandbox_policy: Map.get(section, :turn_sandbox_policy),
      turn_timeout_ms: Map.get(section, :turn_timeout_ms, @default_turn_timeout_ms),
      read_timeout_ms: Map.get(section, :read_timeout_ms, @default_read_timeout_ms),
      stall_timeout_ms: Map.get(section, :stall_timeout_ms, @default_stall_timeout_ms)
    }
  end

  # Raxol extension: lets WORKFLOW.md select between the raxol_agent runner
  # (default) and the Codex app-server runner, without forking the SPEC.
  defp runner(raw) do
    section = Map.get(raw, :runner, %{})
    kind = Map.get(section, :kind, "raxol_agent")

    %{
      kind: kind,
      agent: Map.get(section, :agent, %{})
    }
  end

  # Raxol extension: per-run asciicast capture. When `enabled: true`, the
  # orchestrator writes `<workspace>/.raxol_symphony/run-<attempt>.cast`
  # for each dispatched run.
  defp recording(raw) do
    section = Map.get(raw, :recording, %{})

    %{
      enabled: Map.get(section, :enabled, false),
      width: Map.get(section, :width, @default_recording_width),
      height: Map.get(section, :height, @default_recording_height)
    }
  end

  # -- Value resolution -------------------------------------------------------

  @doc """
  Resolves `$VAR_NAME` indirection from environment variables.

  Returns `nil` for an unset env var (treated as missing per SPEC). Non-string
  and non-`$VAR` values pass through unchanged.
  """
  @spec resolve_value(term()) :: term()
  def resolve_value(nil), do: nil

  def resolve_value("$" <> var_name) when byte_size(var_name) > 0 do
    case System.get_env(var_name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  def resolve_value(value), do: value

  defp normalize_workspace_root(nil, _workflow_path), do: nil

  defp normalize_workspace_root(root, workflow_path) when is_binary(root) do
    expanded = expand_home(root)

    cond do
      Path.type(expanded) == :absolute ->
        Path.expand(expanded)

      workflow_path != nil ->
        workflow_path
        |> Path.dirname()
        |> Path.join(expanded)
        |> Path.expand()

      true ->
        Path.expand(expanded)
    end
  end

  defp expand_home("~/" <> rest) do
    Path.join(System.user_home!(), rest)
  end

  defp expand_home("~"), do: System.user_home!()
  defp expand_home(other), do: other

  defp normalize_state_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {normalize_state_key(k), v}
    end)
    |> Enum.filter(fn {_, v} -> is_integer(v) and v > 0 end)
    |> Map.new()
  end

  defp normalize_state_map(_), do: %{}

  defp normalize_state_key(k) when is_atom(k), do: k |> Atom.to_string() |> String.downcase()
  defp normalize_state_key(k) when is_binary(k), do: String.downcase(k)
  defp normalize_state_key(k), do: k
end
