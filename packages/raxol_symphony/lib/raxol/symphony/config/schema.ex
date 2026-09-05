defmodule Raxol.Symphony.Config.Schema do
  @moduledoc """
  Validation rules for `Raxol.Symphony.Config`.

  Implements SPEC s6.3 (Dispatch Preflight Validation):

  - Workflow file can be loaded and parsed (handled by `Workflow.load/1`).
  - `tracker.kind` is present and supported.
  - `tracker.api_key` is present after `$` resolution.
  - `tracker.project_slug` is present when REQUIRED by the selected tracker
    kind.
  - `codex.command` is present and non-empty when `runner.kind == "codex"`.

  Also validates Raxol-extension fields (`runner.kind`, agent counts) so that
  obvious misconfiguration fails at startup rather than mid-dispatch.
  """

  import Raxol.Symphony.Util, only: [blank?: 1]

  alias Raxol.Symphony.Config

  @supported_tracker_kinds ~w(linear github memory)
  @supported_runner_kinds ~w(raxol_agent codex review)
  # Kinds usable as the implementer or reviewer behind a "review" runner.
  @reviewable_kinds ~w(raxol_agent raxol_agent_session codex)

  @type error ::
          :missing_tracker_kind
          | {:unsupported_tracker_kind, binary()}
          | :missing_tracker_api_key
          | :missing_tracker_project_slug
          | :missing_codex_command
          | {:unsupported_runner_kind, binary()}
          | :missing_reviewer_kind
          | :reviewer_kind_must_differ
          | {:invalid_ssh_host, term()}
          | {:invalid_value, atom(), term()}
          | {:workflow_section_not_a_map, [atom()]}

  @codex_auth_modes [:inherit, :api_key, :codex_home]

  # Front-matter paths that are read as maps. A mis-indented edit leaves a
  # scalar, a list, or (most often) nothing at all under one of these keys,
  # and reading that as a map raises BadMapError. Most raise in the `Config`
  # section builders, which escapes WorkflowStore's last-known-good fallback
  # and takes the Symphony tree down. `runner.agent` is stored raw and read by
  # the runner instead, so it raises later, once per dispatched run, with only
  # a stacktrace in a worker task to go on. Checked against the raw front
  # matter so either way the typo comes back as an error tuple at load.
  @map_sections [
    [:tracker],
    [:polling],
    [:workspace],
    [:hooks],
    [:agent],
    [:codex],
    [:codex, :auth],
    [:runner],
    [:runner, :agent],
    [:review],
    [:recording],
    [:worker]
  ]

  @doc """
  Validates a config struct. Returns `:ok` or `{:error, reason}`.

  ## Options

  - `:skip_runner` -- skip the `runner.kind`/`codex.command` check. Used by
    the orchestrator preflight when a `:runner_module` override is in place
    (test mode, custom embedding), since the workflow's declared runner is
    irrelevant in that case.
  """
  @spec validate(Config.t(), keyword()) :: :ok | {:error, error()}
  def validate(%Config{} = config, opts \\ []) do
    with :ok <- validate_tracker(config.tracker),
         :ok <- validate_polling(config.polling),
         :ok <- validate_workspace(config.workspace),
         :ok <- validate_hooks(config.hooks),
         :ok <- validate_agent(config.agent),
         :ok <- validate_review(config.review),
         :ok <- validate_worker(config.worker),
         :ok <- validate_codex_auth(config.codex) do
      if Keyword.get(opts, :skip_runner, false) do
        :ok
      else
        validate_runner(config.runner, config.codex)
      end
    end
  end

  @doc """
  Validates the shape of the raw front-matter map before it is built into a
  `Config.t()`.

  Every section that is later read as a map must be a map (or absent).
  Returns `:ok` or `{:error, {:workflow_section_not_a_map, path}}`.
  """
  @spec validate_sections(map()) :: :ok | {:error, error()}
  def validate_sections(raw) when is_map(raw) do
    Enum.reduce_while(@map_sections, :ok, fn path, :ok ->
      case fetch_section(raw, path) do
        :absent -> {:cont, :ok}
        {:ok, value} when is_map(value) -> {:cont, :ok}
        {:ok, _malformed} -> {:halt, {:error, {:workflow_section_not_a_map, path}}}
      end
    end)
  end

  defp fetch_section(map, [key]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> :absent
    end
  end

  defp fetch_section(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_section(value, rest)
      :error -> :absent
    end
  end

  # A malformed parent is reported by its own entry, which comes first.
  defp fetch_section(_not_a_map, _path), do: :absent

  # -- Tracker ----------------------------------------------------------------

  defp validate_tracker(%{kind: nil}), do: {:error, :missing_tracker_kind}

  defp validate_tracker(%{kind: kind} = tracker) do
    with :ok <- state_list(tracker.active_states, :tracker_active_states),
         :ok <- state_list(tracker.terminal_states, :tracker_terminal_states) do
      cond do
        kind not in @supported_tracker_kinds ->
          {:error, {:unsupported_tracker_kind, kind}}

        tracker.kind == "memory" ->
          :ok

        blank?(tracker.api_key) ->
          {:error, :missing_tracker_api_key}

        tracker.kind == "linear" and blank?(tracker.project_slug) ->
          {:error, :missing_tracker_project_slug}

        true ->
          :ok
      end
    end
  end

  # `Issue.active?/2` guards on a list and downcases each entry, so anything
  # else reaches the poll tick as a raise rather than a preflight error.
  defp state_list(states, name) do
    if is_list(states) and Enum.all?(states, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_value, name, states}}
    end
  end

  # -- Polling ----------------------------------------------------------------

  defp validate_polling(%{interval_ms: ms}) when is_integer(ms) and ms > 0, do: :ok

  defp validate_polling(%{interval_ms: ms}),
    do: {:error, {:invalid_value, :polling_interval_ms, ms}}

  # -- Workspace --------------------------------------------------------------

  defp validate_workspace(%{root: root}) when is_binary(root) and byte_size(root) > 0, do: :ok

  defp validate_workspace(%{root: root}),
    do: {:error, {:invalid_value, :workspace_root, root}}

  # -- Hooks ------------------------------------------------------------------

  defp validate_hooks(%{timeout_ms: ms}) when is_integer(ms) and ms > 0, do: :ok
  defp validate_hooks(%{timeout_ms: ms}), do: {:error, {:invalid_value, :hooks_timeout_ms, ms}}

  # -- Agent ------------------------------------------------------------------

  defp validate_agent(agent) do
    with :ok <- positive_integer(agent.max_concurrent_agents, :max_concurrent_agents),
         :ok <- positive_integer(agent.max_turns, :max_turns),
         :ok <- positive_integer(agent.max_retry_backoff_ms, :max_retry_backoff_ms) do
      positive_integer(agent.max_tracker_requeues, :max_tracker_requeues)
    end
  end

  # -- Runner -----------------------------------------------------------------

  defp validate_runner(%{kind: kind}, _codex) when kind not in @supported_runner_kinds do
    {:error, {:unsupported_runner_kind, kind}}
  end

  defp validate_runner(%{kind: "codex"}, %{command: command}) do
    if blank?(command), do: {:error, :missing_codex_command}, else: :ok
  end

  defp validate_runner(_runner, _codex), do: :ok

  # -- Codex auth -------------------------------------------------------------

  defp validate_codex_auth(%{auth: %{mode: mode}})
       when mode not in @codex_auth_modes do
    {:error, {:invalid_value, :codex_auth_mode, mode}}
  end

  defp validate_codex_auth(%{auth: %{mode: :api_key, api_key_env: env}})
       when not is_binary(env) or env == "" do
    {:error, {:invalid_value, :codex_auth_api_key_env, env}}
  end

  defp validate_codex_auth(%{auth: %{mode: :codex_home, codex_home: home}})
       when not is_binary(home) or home == "" do
    {:error, {:invalid_value, :codex_auth_codex_home, home}}
  end

  defp validate_codex_auth(_codex), do: :ok

  # -- Review -----------------------------------------------------------------

  defp validate_review(%{enabled: true} = review) do
    implementer = review.implementer_kind
    reviewer = review.reviewer_kind

    cond do
      blank?(reviewer) -> {:error, :missing_reviewer_kind}
      reviewer == implementer -> {:error, :reviewer_kind_must_differ}
      implementer not in @reviewable_kinds -> {:error, {:unsupported_runner_kind, implementer}}
      reviewer not in @reviewable_kinds -> {:error, {:unsupported_runner_kind, reviewer}}
      true -> :ok
    end
  end

  defp validate_review(_review), do: :ok

  # -- Worker (issue #742) ----------------------------------------------------

  defp validate_worker(%{ssh_hosts: hosts}) when is_list(hosts) do
    Enum.reduce_while(hosts, :ok, fn raw, :ok ->
      case Raxol.Symphony.Worker.HostSpec.normalize(raw) do
        {:ok, _spec} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_worker(%{ssh_hosts: hosts}),
    do: {:error, {:invalid_value, :worker_ssh_hosts, hosts}}

  defp validate_worker(_worker), do: :ok

  # -- Helpers ----------------------------------------------------------------

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(value, name), do: {:error, {:invalid_value, name, value}}
end
