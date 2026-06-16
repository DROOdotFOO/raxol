defmodule Raxol.Symphony.Orchestrator.PausedSaver.Dets do
  @moduledoc """
  Disk-backed `PausedSaver` for production use. Persists paused-run
  entries to a DETS file so they survive BEAM restart.

  Opens the DETS table on first call (per orchestrator process). The
  table stays open for the BEAM's lifetime; DETS handles flushes on
  insert. Use `:dets.close/1` from a supervisor shutdown hook if
  graceful close on stop matters.

  ## Config

      %{
        path: "/var/lib/symphony/paused.dets",
        name: :symphony_paused_dets       # optional; defaults to a stable atom
      }

  The `:path` is required.
  """

  @behaviour Raxol.Symphony.Orchestrator.PausedSaver

  @default_name :raxol_symphony_paused_dets

  @impl true
  def put(config, issue_id, entry) do
    with {:ok, table} <- open(config) do
      :ok = :dets.insert(table, {issue_id, entry})
      :ok
    end
  end

  @impl true
  def delete(config, issue_id) do
    with {:ok, table} <- open(config) do
      :ok = :dets.delete(table, issue_id)
      :ok
    end
  end

  @impl true
  def load_all(config) do
    with {:ok, table} <- open(config) do
      map =
        :dets.foldl(
          fn {issue_id, entry}, acc -> Map.put(acc, issue_id, entry) end,
          %{},
          table
        )

      {:ok, map}
    end
  end

  @doc "Idempotently open the DETS table; safe to call from any process."
  @spec open(map()) :: {:ok, atom()} | {:error, term()}
  def open(%{path: path} = config) do
    name = Map.get(config, :name, @default_name)
    path_charlist = String.to_charlist(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(name, type: :set, file: path_charlist) do
      {:ok, ^name} -> {:ok, name}
      {:error, _} = err -> err
    end
  end

  def open(_config), do: {:error, :missing_path}
end
