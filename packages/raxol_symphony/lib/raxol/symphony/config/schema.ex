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

  alias Raxol.Symphony.Config

  @supported_tracker_kinds ~w(linear github memory)
  @supported_runner_kinds ~w(raxol_agent codex)

  @type error ::
          :missing_tracker_kind
          | {:unsupported_tracker_kind, binary()}
          | :missing_tracker_api_key
          | :missing_tracker_project_slug
          | :missing_codex_command
          | {:unsupported_runner_kind, binary()}
          | {:invalid_value, atom(), term()}

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
         :ok <- validate_agent(config.agent) do
      if Keyword.get(opts, :skip_runner, false) do
        :ok
      else
        validate_runner(config.runner, config.codex)
      end
    end
  end

  # -- Tracker ----------------------------------------------------------------

  defp validate_tracker(%{kind: nil}), do: {:error, :missing_tracker_kind}

  defp validate_tracker(%{kind: kind} = tracker) do
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
         :ok <- positive_integer(agent.max_turns, :max_turns) do
      positive_integer(agent.max_retry_backoff_ms, :max_retry_backoff_ms)
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

  # -- Helpers ----------------------------------------------------------------

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(value, name), do: {:error, {:invalid_value, name, value}}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
