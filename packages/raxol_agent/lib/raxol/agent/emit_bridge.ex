defmodule Raxol.Agent.EmitBridge do
  @moduledoc """
  Bridges the package-neutral `Raxol.Core.Runtime.EmitBus` to the agent
  harness contract.

  The Dispatcher (main `raxol` package) publishes neutral event maps at both
  model-fold sites but knows nothing about the agent contract — it must not,
  since `raxol` cannot depend on `raxol_agent`. This bridge lives on the
  `raxol_agent` side, where the `raxol -> raxol_agent` direction is legal. It:

    1. subscribes to `EmitBus` for a `session_id`,
    2. maps each neutral map onto a `Raxol.Agent.Contract.Event`, and
    3. re-emits it through `Raxol.Agent.SessionStreamer`,

  so any surface already subscribed to `SessionStreamer` (the `raxol -p` CLI,
  the TUI, SSE) receives Dispatcher-originated events on the same channel as
  `Raxol.Agent.Contract.pump/3` output. Producers differ; the contract does
  not.

  ## Neutral -> contract mapping

  | neutral `type`     | tier         | contract `type`   |
  | ------------------ | ------------ | ----------------- |
  | `:command_result`  | `:ephemeral` | `:item_delta`     |
  | `:app_update`      | `:durable`   | `:item_completed` |

  Anything else passes through as an `:item_completed` with its tier
  preserved. `family` and `tier` carry through unchanged; `id` is a per-bridge
  monotonic sequence (the future journal offset); `ts` is preserved.

  The semantic refinement of these two coarse Dispatcher types into the full
  `:turn_started` / `:turn_completed` / `:error` vocabulary happens once the
  Dispatcher carries turn boundaries — see the module's TODO.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  defstruct [:session_id, :streamer, counter: 0]

  @type t :: %__MODULE__{
          session_id: term(),
          streamer: GenServer.server(),
          counter: non_neg_integer()
        }

  @doc """
  Start a bridge for `session_id`.

  Options:

    * `:session_id` (required) — the EmitBus/SessionStreamer session key
    * `:streamer` — SessionStreamer server (default `Raxol.Agent.SessionStreamer`)
    * `:name` — process name (default anonymous)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    streamer = Keyword.get(opts, :streamer, SessionStreamer)

    EmitBus.subscribe(session_id)

    {:ok, %__MODULE__{session_id: session_id, streamer: streamer, counter: 0}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:emit_bus, session_id, neutral},
        %__MODULE__{session_id: session_id} = state
      ) do
    id = state.counter + 1
    event = map_event(neutral, id, session_id)
    SessionStreamer.emit(session_id, event, state.streamer)
    {:noreply, %{state | counter: id}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @doc """
  Map a neutral EmitBus event map to a `Raxol.Agent.Contract.Event`.

  Pure. `id` becomes the contract event's monotonic offset; `session_id`
  overrides the neutral map's (they are the same in practice).
  """
  @spec map_event(map(), non_neg_integer(), term()) :: Event.t()
  def map_event(neutral, id, session_id) when is_map(neutral) do
    tier = Map.get(neutral, :tier, :durable)

    %Event{
      v: 0,
      id: id,
      session_id: session_id,
      turn_id: Map.get(neutral, :turn_id),
      ts: Map.get(neutral, :ts, System.system_time(:microsecond)),
      family: Map.get(neutral, :family, :loop),
      type: contract_type(Map.get(neutral, :type), tier),
      tier: tier,
      payload: Map.get(neutral, :payload, %{})
    }
  end

  # Coarse Dispatcher types -> v0 loop vocabulary.
  defp contract_type(:command_result, _tier), do: :item_delta
  defp contract_type(:app_update, _tier), do: :item_completed
  defp contract_type(_other, _tier), do: :item_completed
end
