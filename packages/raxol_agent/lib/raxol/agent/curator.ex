defmodule Raxol.Agent.Curator do
  @moduledoc """
  Keeps agent-authored skills healthy: ages unused ones and bounds their growth.

  The Curator runs over the usage telemetry in `Raxol.Agent.Skills.Store`. Its
  deterministic phase moves a skill `active -> stale -> archived` as it goes
  unused, where archived skills move under `<root>/.archive/` and drop out of
  `skills_list`. It only ever touches skills whose `created_by` is `:agent`;
  user-authored, external, and pinned skills are left alone.

  Passes are gated on time and idleness: a pass runs only when at least
  `interval_hours` (default 168) have elapsed since the last one AND the agent
  has been idle for `min_idle_hours` (default 2). The first pass after start is
  deferred a full interval. The runtime reports activity with `note_activity/1`.

  Before any non-dry-run pass, a `.tar.gz` of the skills root is written to a
  backups directory (the newest `keep_backups` are retained); `rollback/1`
  restores the latest. `run/1` forces a pass on demand, and `run(dry_run: true)`
  reports the transitions it would make without touching anything.

  The model-driven consolidation of near-duplicate skills is opt-in
  (`consolidate: true`) and not yet implemented.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Skills.Store

  @seconds_per_day 86_400
  @seconds_per_hour 3_600

  @defaults %{
    stale_after_days: 30,
    archive_after_days: 90,
    interval_hours: 168,
    min_idle_hours: 2,
    keep_backups: 5,
    consolidate: false,
    tick_ms: @seconds_per_hour * 1_000
  }

  @type transition :: %{name: String.t(), from: atom(), to: atom()}

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Report that the agent did work, resetting the idle clock."
  @spec note_activity(GenServer.server()) :: :ok
  def note_activity(server \\ __MODULE__), do: GenServer.cast(server, :note_activity)

  @doc """
  Run a pass now, bypassing the interval/idle gate. Pass `dry_run: true` to get
  the transitions without applying them or writing a backup.
  """
  @spec run(GenServer.server(), keyword()) :: %{
          transitions: [transition()],
          backup: String.t() | nil
        }
  def run(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:run, Keyword.get(opts, :dry_run, false)})
  end

  @doc "The transitions a pass would make right now, without applying them."
  @spec plan(GenServer.server()) :: [transition()]
  def plan(server \\ __MODULE__), do: GenServer.call(server, :plan)

  @doc "Restore the skills root from the most recent backup. Returns the path used."
  @spec rollback(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def rollback(server \\ __MODULE__), do: GenServer.call(server, :rollback)

  @doc "Current Curator state: thresholds, last pass time, next eligible time."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    skills = Keyword.fetch!(opts, :skills)
    root = Store.root(store_opts(skills))
    now = now()

    config = Map.merge(@defaults, config_overrides(opts))

    state =
      Map.merge(config, %{
        skills: skills,
        root: root,
        backups_dir: opts[:backups_dir] || default_backups_dir(root),
        last_pass_at: nil,
        last_activity_at: now,
        next_allowed_at: now + config.interval_hours * @seconds_per_hour
      })

    schedule_tick(state.tick_ms)
    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:run, dry_run}, _from, state) do
    {:reply, do_pass(state, dry_run), state}
  end

  def handle_manager_call(:plan, _from, state) do
    {:reply, compute_transitions(state), state}
  end

  def handle_manager_call(:rollback, _from, state) do
    {:reply, do_rollback(state), state}
  end

  def handle_manager_call(:status, _from, state) do
    {:reply, Map.drop(state, [:skills]), state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(:note_activity, state) do
    {:noreply, %{state | last_activity_at: now()}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:tick, state) do
    state = if eligible?(state), do: run_gated_pass(state), else: state
    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  # -- pass orchestration -----------------------------------------------------

  defp run_gated_pass(state) do
    _ = do_pass(state, false)
    now = now()
    %{state | last_pass_at: now, next_allowed_at: now + state.interval_hours * @seconds_per_hour}
  end

  defp eligible?(state) do
    now = now()
    idle_hours = (now - state.last_activity_at) / @seconds_per_hour
    now >= state.next_allowed_at and idle_hours >= state.min_idle_hours
  end

  defp do_pass(state, dry_run) do
    transitions = compute_transitions(state)
    backup = if dry_run, do: nil, else: write_backup(state)
    unless dry_run, do: Enum.each(transitions, &apply_transition(state, &1))
    %{transitions: transitions, backup: backup}
  end

  # -- lifecycle transitions --------------------------------------------------

  defp compute_transitions(state) do
    now = now()

    state.skills
    |> store_opts()
    |> Store.telemetry()
    |> Enum.filter(&curatable?/1)
    |> Enum.flat_map(&transition_for(&1, state, now))
  end

  defp curatable?(row) do
    row.created_by == :agent and row.source == :managed and not row.pinned
  end

  defp transition_for(row, state, now) do
    idle_days = (now - reference_time(row, now)) / @seconds_per_day

    cond do
      idle_days >= state.archive_after_days and row.state != :archived ->
        [%{name: row.name, from: row.state, to: :archived}]

      idle_days >= state.stale_after_days and row.state == :active ->
        [%{name: row.name, from: :active, to: :stale}]

      true ->
        []
    end
  end

  defp reference_time(row, now), do: row.last_used_at || row.created_at || now

  defp apply_transition(state, %{name: name, to: :archived}) do
    Store.archive(name, store_opts(state.skills))
  end

  defp apply_transition(state, %{name: name, to: to}) do
    Store.set_state(name, to, store_opts(state.skills))
  end

  # -- backup / rollback ------------------------------------------------------

  defp write_backup(state) do
    File.mkdir_p!(state.backups_dir)
    path = Path.join(state.backups_dir, "skills-#{now()}.tar.gz")
    base = Path.basename(state.root)

    case :erl_tar.create(charlist(path), [{charlist(base), charlist(state.root)}], [:compressed]) do
      :ok ->
        prune_backups(state)
        path

      {:error, reason} ->
        Logger.warning("curator backup failed: #{inspect(reason)}")
        nil
    end
  end

  defp prune_backups(state) do
    state.backups_dir
    |> Path.join("skills-*.tar.gz")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.drop(state.keep_backups)
    |> Enum.each(&File.rm/1)
  end

  defp do_rollback(state) do
    case latest_backup(state) do
      nil ->
        {:error, :no_backup}

      tarball ->
        File.rm_rf!(state.root)
        cwd = Path.dirname(state.root)

        case :erl_tar.extract(charlist(tarball), [:compressed, {:cwd, charlist(cwd)}]) do
          :ok ->
            Store.reload(store_opts(state.skills))
            {:ok, tarball}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp latest_backup(state) do
    state.backups_dir
    |> Path.join("skills-*.tar.gz")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> List.first()
  end

  # -- helpers ----------------------------------------------------------------

  defp config_overrides(opts) do
    opts
    |> Keyword.take(Map.keys(@defaults))
    |> Map.new()
  end

  defp store_opts({_mod, opts}), do: opts

  defp default_backups_dir(root), do: Path.join(Path.dirname(root), ".curator_backups")

  defp schedule_tick(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp charlist(path), do: String.to_charlist(path)

  defp now, do: System.system_time(:second)
end
