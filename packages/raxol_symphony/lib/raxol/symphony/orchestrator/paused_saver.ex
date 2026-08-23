defmodule Raxol.Symphony.Orchestrator.PausedSaver do
  @moduledoc """
  Behaviour for durable storage of paused-run entries.

  The orchestrator holds `state.paused` in memory. Without a Saver,
  paused runs are lost on BEAM restart. A Saver impl persists each
  entry on park, deletes it on resume / stop, and rehydrates the map
  on `init_manager/1`.

  Configure on orchestrator start with `:paused_saver`:

      Orchestrator.start_link(
        config: cfg,
        paused_saver: {Raxol.Symphony.Orchestrator.PausedSaver.Dets,
                       %{path: "/var/lib/symphony/paused.dets"}}
      )

  The default is `nil`: orchestrator runs without persistence.
  """

  alias Raxol.Symphony.Orchestrator.State

  @typedoc "Saver configuration. Implementation-specific."
  @type config :: map()

  @typedoc "Tuple form used when configuring an orchestrator."
  @type spec :: {module(), config()}

  @doc """
  Persist a paused entry under `issue_id`. Idempotent for a given
  `{issue_id, paused_at}` pair.
  """
  @callback put(config(), binary(), State.paused_entry()) :: :ok | {:error, term()}

  @doc """
  Remove the persisted entry for `issue_id`. Returns `:ok` even if the
  entry was unknown.
  """
  @callback delete(config(), binary()) :: :ok | {:error, term()}

  @doc """
  Load the full paused map. Called from `init_manager/1`. Returns an
  empty map when no persisted state exists.
  """
  @callback load_all(config()) ::
              {:ok, %{optional(binary()) => State.paused_entry()}} | {:error, term()}

  # -- Public dispatch -- avoids the orchestrator caring whether a saver
  # is configured.

  @spec put(nil | spec(), binary(), State.paused_entry()) :: :ok | {:error, term()}
  def put(nil, _issue_id, _entry), do: :ok
  def put({mod, cfg}, issue_id, entry), do: mod.put(cfg, issue_id, entry)

  @spec delete(nil | spec(), binary()) :: :ok | {:error, term()}
  def delete(nil, _issue_id), do: :ok
  def delete({mod, cfg}, issue_id), do: mod.delete(cfg, issue_id)

  @spec load_all(nil | spec()) :: %{optional(binary()) => State.paused_entry()}
  def load_all(nil), do: %{}

  def load_all({mod, cfg}) do
    case mod.load_all(cfg) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end
