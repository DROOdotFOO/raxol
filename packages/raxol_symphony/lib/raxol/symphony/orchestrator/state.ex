defmodule Raxol.Symphony.Orchestrator.State do
  @moduledoc """
  Orchestrator runtime state.

  Implements SPEC s4.1.8.
  """

  alias Raxol.Symphony.{Config, Issue}

  @type running_entry :: %{
          issue: Issue.t(),
          attempt: non_neg_integer() | nil,
          workspace_path: Path.t(),
          started_at: integer(),
          worker_pid: pid(),
          worker_ref: reference(),
          state: binary(),
          last_event: atom() | binary() | nil,
          last_message: binary() | nil,
          last_event_at_ms: integer() | nil,
          turn_count: non_neg_integer(),
          capture_pid: pid() | nil,
          pending_pause: {atom(), term()} | nil,
          tokens: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }

  @type retry_entry :: %{
          issue_id: binary(),
          identifier: binary(),
          attempt: pos_integer(),
          due_at_ms: integer(),
          timer_ref: reference() | nil,
          error: term() | nil
        }

  @type paused_entry :: %{
          issue: Issue.t(),
          attempt: non_neg_integer() | nil,
          workspace_path: Path.t(),
          interrupt_reason: atom(),
          resume_token: term(),
          paused_at: integer(),
          last_event: atom() | binary() | nil,
          last_message: binary() | nil,
          turn_count: non_neg_integer(),
          tokens: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }

  @type codex_totals :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          seconds_running: float()
        }

  @typedoc """
  In-flight `:graph_parallel` batch, keyed by the batch worker's task ref.

  One entry covers up to `config.workflow_parallelism` issues fanned out
  through a single parallel graph run. `results` is `nil` until the worker
  sends its `{:batch_result, run_results}` reply, then a list of
  `{issue_id, :ok | {:error, reason}}` tuples used to fan outcomes back to
  the per-issue retry paths on worker exit.
  """
  @type batch_entry :: %{
          issues: [
            %{issue: Issue.t(), attempt: non_neg_integer() | nil, workspace_path: Path.t()}
          ],
          worker_pid: pid(),
          worker_ref: reference(),
          started_at: integer(),
          results: [{binary(), :ok | {:error, term()}}] | nil
        }

  defstruct [
    :config,
    :runner_module,
    :tracker_module,
    :task_supervisor,
    :tick_timer_ref,
    :workflow_store,
    :last_preflight_error,
    :paused_saver,
    running: %{},
    batches: %{},
    claimed: MapSet.new(),
    retry_attempts: %{},
    paused: %{},
    completed: MapSet.new(),
    codex_totals: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      seconds_running: 0.0
    },
    codex_rate_limits: nil,
    listeners: MapSet.new()
  ]

  @type t :: %__MODULE__{
          config: Config.t() | nil,
          runner_module: module() | nil,
          tracker_module: module() | nil,
          task_supervisor: GenServer.server() | nil,
          tick_timer_ref: reference() | nil,
          workflow_store: GenServer.server() | nil,
          last_preflight_error: term() | nil,
          running: %{optional(binary()) => running_entry()},
          batches: %{optional(reference()) => batch_entry()},
          claimed: MapSet.t(binary()),
          retry_attempts: %{optional(binary()) => retry_entry()},
          paused: %{optional(binary()) => paused_entry()},
          paused_saver: {module(), map()} | nil,
          completed: MapSet.t(binary()),
          codex_totals: codex_totals(),
          codex_rate_limits: term() | nil,
          listeners: MapSet.t(pid())
        }

  @doc "Empty token totals."
  @spec empty_tokens() :: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  def empty_tokens, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
end
