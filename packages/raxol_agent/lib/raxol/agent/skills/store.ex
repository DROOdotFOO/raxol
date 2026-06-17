defmodule Raxol.Agent.Skills.Store do
  @moduledoc """
  Disk-backed index of procedural-memory skills, with usage telemetry.

  A skill is a directory on disk holding a `SKILL.md` (parsed by
  `Raxol.Agent.Skill`) plus optional supporting files. Disk is the source of
  truth; this `BaseManager` GenServer is a warm index over it. The index is
  built by scanning a managed root (writable, default `~/.raxol/skills`) and any
  read-only `external_dirs` (default `~/.agents/skills`), so an agent sees the
  user's existing skill library on day one.

  Per-skill usage telemetry (`use_count`, `view_count`, `last_used_at`, `state`,
  `pinned`) is the store's own state and is persisted to a DETS file via
  `Raxol.Core.Stores.Dets` so it survives a restart; the skills themselves are
  re-read from disk every boot, so no stale skill content can outlive its file.

  ## Tables (derived from the registered name)

    * primary `:set` `{name, %{skill, dir, source}}` -- the live skill index
    * `Usage` `:set` `{name, usage_map}` -- telemetry, mirrored to DETS

  `source` is `:managed` (under `skills_root`, writable) or `:external`
  (read-only). `skill_manage` writes only ever touch `:managed` skills.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Agent.Skill
  alias Raxol.Core.Stores.Dets

  @default_root "~/.raxol/skills"
  @default_external ["~/.agents/skills"]

  @type usage :: %{
          use_count: non_neg_integer(),
          view_count: non_neg_integer(),
          last_used_at: integer() | nil,
          state: :active | :stale | :archived,
          pinned: boolean()
        }

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Skill metadata only (the cheap level): name, category, description, state, source."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []), do: GenServer.call(server(opts), :list)

  @doc "Full parsed `%Skill{}` for `name`, or `{:error, :not_found}`."
  @spec get(String.t(), keyword()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get(name, opts \\ []), do: GenServer.call(server(opts), {:get, name})

  @doc """
  Read a skill's `SKILL.md` body (when `path` is `nil`) or one supporting file
  relative to the skill directory. Bumps the skill's view telemetry.
  """
  @spec view(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def view(name, path \\ nil, opts \\ []) do
    GenServer.call(server(opts), {:view, name, path})
  end

  @doc """
  Create (or overwrite) a managed skill from `attrs`
  (`%{name, description, category, body, created_by, version, metadata}`).
  Writes `SKILL.md` under `skills_root` and re-indexes.
  """
  @spec create(map(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    GenServer.call(server(opts), {:create, attrs})
  end

  @doc "Merge `changes` (any of `:description, :category, :version, :body, :metadata`) into a managed skill."
  @spec patch(String.t(), map(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def patch(name, changes, opts \\ []) when is_map(changes) do
    GenServer.call(server(opts), {:patch, name, changes})
  end

  @doc "Delete a managed skill (its directory) and drop it from the index."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(name, opts \\ []), do: GenServer.call(server(opts), {:delete, name})

  @doc "Record that a skill was used (increments `use_count`, sets `last_used_at`)."
  @spec record_use(String.t(), keyword()) :: :ok
  def record_use(name, opts \\ []), do: GenServer.cast(server(opts), {:record_use, name})

  @doc "Usage telemetry for a skill, or `{:error, :not_found}`."
  @spec usage(String.t(), keyword()) :: {:ok, usage()} | {:error, :not_found}
  def usage(name, opts \\ []), do: GenServer.call(server(opts), {:usage, name})

  @doc "Force a re-scan of disk into the index. Telemetry is preserved."
  @spec reload(keyword()) :: :ok
  def reload(opts \\ []), do: GenServer.call(server(opts), :reload)

  @doc "Derived ETS table names. Public for tests and tooling."
  @spec primary_table(atom()) :: atom()
  def primary_table(name) when is_atom(name), do: name
  @spec usage_table(atom()) :: atom()
  def usage_table(name) when is_atom(name), do: :"#{name}.Usage"

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    name = registered_name!()
    primary = primary_table(name)
    usage = usage_table(name)

    :ets.new(primary, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(usage, [:named_table, :public, :set, read_concurrency: true])

    dets =
      case Dets.resolve_path(opts, :raxol_agent, :skills_store_path) do
        nil -> nil
        path -> Dets.open!(:"#{name}.UsageDets", path, &replay_usage(usage, &1))
      end

    state = %{
      primary: primary,
      usage: usage,
      dets: dets,
      root: expand(opts[:skills_root] || config(:skills_root) || @default_root),
      external:
        expand_all(opts[:external_dirs] || config(:skills_external_dirs) || @default_external)
    }

    scan(state)
    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:list, _from, state) do
    skills =
      state.primary
      |> :ets.tab2list()
      |> Enum.map(fn {name, entry} -> metadata(name, entry, usage_for(state, name)) end)
      |> Enum.sort_by(& &1.name)

    {:reply, skills, state}
  end

  def handle_manager_call({:get, name}, _from, state) do
    case lookup(state, name) do
      {:ok, entry} -> {:reply, {:ok, entry.skill}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:view, name, path}, _from, state) do
    case lookup(state, name) do
      {:ok, entry} ->
        bump_view(state, name)
        {:reply, read_view(entry, path), state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_manager_call({:create, attrs}, _from, state) do
    {:reply, do_create(state, attrs), state}
  end

  def handle_manager_call({:patch, name, changes}, _from, state) do
    {:reply, do_patch(state, name, changes), state}
  end

  def handle_manager_call({:delete, name}, _from, state) do
    {:reply, do_delete(state, name), state}
  end

  def handle_manager_call({:usage, name}, _from, state) do
    case usage_for(state, name) do
      nil -> {:reply, {:error, :not_found}, state}
      usage -> {:reply, {:ok, usage}, state}
    end
  end

  def handle_manager_call(:reload, _from, state) do
    :ets.delete_all_objects(state.primary)
    scan(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Dets.close(state.dets)
    :ok
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:record_use, name}, state) do
    if member?(state, name) do
      usage = usage_for(state, name) || default_usage()
      put_usage(state, name, %{usage | use_count: usage.use_count + 1, last_used_at: now()})
    end

    {:noreply, state}
  end

  # -- disk scan + index ------------------------------------------------------

  defp scan(state) do
    managed = scan_root(state.root, :managed)
    external = Enum.flat_map(state.external, &scan_root(&1, :external))

    # Managed skills win over an external skill of the same name.
    (external ++ managed)
    |> Enum.each(fn {name, entry} ->
      :ets.insert(state.primary, {name, entry})
      ensure_usage(state, name)
    end)
  end

  defp scan_root(root, source) do
    root
    |> Path.join("**/SKILL.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Skill.from_file(file) do
        {:ok, skill} -> [{skill.name, %{skill: skill, dir: Path.dirname(file), source: source}}]
        {:error, _reason} -> []
      end
    end)
  end

  # -- create / patch / delete ------------------------------------------------

  defp do_create(state, attrs) do
    with {:ok, name} <- require_name(attrs),
         skill = build_skill(attrs),
         dir = skill_dir(state, skill),
         :ok <- write_skill(dir, skill) do
      :ets.insert(state.primary, {name, %{skill: skill, dir: dir, source: :managed}})
      ensure_usage(state, name)
      {:ok, skill}
    end
  end

  defp do_patch(state, name, changes) do
    with {:ok, entry} <- managed_entry(state, name),
         skill = apply_changes(entry.skill, changes),
         :ok <- write_skill(entry.dir, skill) do
      :ets.insert(state.primary, {name, %{entry | skill: skill}})
      {:ok, skill}
    end
  end

  defp do_delete(state, name) do
    with {:ok, entry} <- managed_entry(state, name) do
      _ = File.rm_rf(entry.dir)
      :ets.delete(state.primary, name)
      :ets.delete(state.usage, name)
      Dets.delete(state.dets, name)
      :ok
    end
  end

  defp managed_entry(state, name) do
    case lookup(state, name) do
      {:ok, %{source: :managed} = entry} -> {:ok, entry}
      {:ok, %{source: :external}} -> {:error, :read_only_skill}
      :error -> {:error, :not_found}
    end
  end

  defp build_skill(attrs) do
    %Skill{
      name: fetch(attrs, :name),
      description: fetch(attrs, :description),
      version: fetch(attrs, :version),
      category: fetch(attrs, :category),
      created_by: normalize_created_by(fetch(attrs, :created_by)),
      metadata: fetch(attrs, :metadata, %{}),
      body: fetch(attrs, :body, "")
    }
  end

  # Accept attrs with atom or string keys (the action passes atoms; a direct
  # caller may use either).
  defp fetch(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, to_string(key), default)
    end
  end

  defp apply_changes(%Skill{} = skill, changes) do
    %Skill{
      skill
      | description: Map.get(changes, :description, skill.description),
        category: Map.get(changes, :category, skill.category),
        version: Map.get(changes, :version, skill.version),
        metadata: Map.get(changes, :metadata, skill.metadata),
        body: Map.get(changes, :body, skill.body)
    }
  end

  defp write_skill(dir, skill) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "SKILL.md"), Skill.render(skill)) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp skill_dir(state, %Skill{category: nil, name: name}), do: Path.join(state.root, name)

  defp skill_dir(state, %Skill{category: category, name: name}),
    do: Path.join([state.root, category, name])

  # -- view reading -----------------------------------------------------------

  defp read_view(entry, nil), do: {:ok, entry.skill.body}

  defp read_view(entry, path) when is_binary(path) do
    if safe_relative?(path) do
      case File.read(Path.join(entry.dir, path)) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, {:read_failed, reason}}
      end
    else
      {:error, :unsafe_path}
    end
  end

  # Reject absolute paths and any `..` segment so a supporting-file read can
  # never escape the skill directory.
  defp safe_relative?(path) do
    not (Path.type(path) == :absolute or ".." in Path.split(path))
  end

  # -- usage telemetry --------------------------------------------------------

  defp default_usage do
    %{use_count: 0, view_count: 0, last_used_at: nil, state: :active, pinned: false}
  end

  defp ensure_usage(state, name) do
    unless :ets.member(state.usage, name) do
      put_usage(state, name, default_usage())
    end
  end

  defp usage_for(state, name) do
    case :ets.lookup(state.usage, name) do
      [{^name, usage}] -> usage
      [] -> nil
    end
  end

  defp put_usage(state, name, usage) do
    :ets.insert(state.usage, {name, usage})
    Dets.put(state.dets, name, usage)
    :ok
  end

  defp bump_view(state, name) do
    usage = usage_for(state, name) || default_usage()
    put_usage(state, name, %{usage | view_count: usage.view_count + 1})
  end

  defp replay_usage(usage_table, {name, usage}) do
    :ets.insert(usage_table, {name, usage})
  end

  # -- helpers ----------------------------------------------------------------

  defp metadata(name, entry, usage) do
    %{
      name: name,
      category: entry.skill.category,
      description: entry.skill.description,
      created_by: entry.skill.created_by,
      source: entry.source,
      state: (usage || default_usage()).state
    }
  end

  defp lookup(state, name) do
    case :ets.lookup(state.primary, name) do
      [{^name, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  defp member?(state, name), do: :ets.member(state.primary, name)

  defp require_name(attrs) do
    case fetch(attrs, :name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end

  defp normalize_created_by(:agent), do: :agent
  defp normalize_created_by(:user), do: :user
  defp normalize_created_by("agent"), do: :agent
  defp normalize_created_by("user"), do: :user
  defp normalize_created_by(_), do: nil

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp config(key), do: Application.get_env(:raxol_agent, key)

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)

  defp expand_all(paths), do: Enum.map(paths, &Path.expand/1)

  defp now, do: System.system_time(:second)

  defp registered_name! do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        name

      _ ->
        raise """
        Raxol.Agent.Skills.Store must be started with a registered :name so its
        ETS tables can be derived. Use Store.start_link(name: :x) or rely on the
        default (Raxol.Agent.Skills.Store).
        """
    end
  end
end
