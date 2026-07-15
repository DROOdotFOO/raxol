defmodule Raxol.Agent.EmitBridge do
  @moduledoc """
  Bridges the package-neutral `Raxol.Core.Runtime.EmitBus` to the agent
  harness contract, and is the **durable-tier id authority** — the sink that
  closes the keystone.

  The Dispatcher (main `raxol` package) publishes neutral event maps at its
  model-fold sites and turn brackets but knows nothing about the agent contract
  — it must not, since `raxol` cannot depend on `raxol_agent`. This bridge lives
  on the `raxol_agent` side, where the `raxol -> raxol_agent` direction is legal.
  It:

    1. subscribes to `EmitBus` for a `session_id`,
    2. for **durable** events, appends to the session `Raxol.Agent.Journal`
       FIRST and takes the returned offset as the event id (append-before-
       publish),
    3. maps each neutral map onto a `Raxol.Agent.Contract.Event`, and
    4. re-emits it through `Raxol.Agent.SessionStreamer`,

  so any surface already subscribed to `SessionStreamer` (the `raxol -p` CLI,
  the TUI, SSE) receives Dispatcher-originated events on the same channel as
  `Raxol.Agent.Contract.pump/3` output. Producers differ; the contract does not.

  ## The id authority (kills the dual-id landmine)

  The contract says `Event.id == journal offset`. Before this unit the bridge
  stamped `Event.id` from a local per-process counter, so a durable event's live
  id and its journal offset diverged the moment the event was journaled — two
  ids for one event. Now the **journal is the single id authority**:

    * **Durable** events (`turn_started`, `item_completed`, `turn_completed`,
      `error`): `Journal.append/2` FIRST, take the returned `offset`, stamp
      `Event.id = offset`, THEN `SessionStreamer.emit`. Replaying the journal
      reproduces exactly these ids — one identity, zero divergence.
    * **Ephemeral** events (`item_delta`): never journaled. Their id carries the
      **last durable offset** so it never masquerades as a fresh offset — a
      delta refines the item at the current durable position. Real journal
      offsets start at `1`; an ephemeral event emitted before any durable
      append carries the sentinel id `0` ("pre-durable").

  The journal is opened lazily on the first durable event (or supplied up-front
  via the `:journal` option), scoped to `session_id` under `RAXOL_SESSIONS_DIR`
  / `~/.raxol/sessions`, and closed on `terminate/2`. It persists to disk and
  survives a BEAM kill.

  ## The journal is the hard gate for durable events

  When a durable append fails (journal cannot be opened, or `append/2` returns
  `{:error, reason}` — e.g. a full disk), the durable event is **dropped from
  the live tail**: it is NOT published with a fabricated id and `last_offset`
  does NOT advance. Fabricating an id here would resurrect the dual-id
  landmine — the Writer does not advance its offset on a failed append, so the
  next successful append would reuse the fabricated number and two live-tail
  events would share one id while replay reproduced only one. An un-journaled
  durable event must never look durable.

  Instead the bridge emits a loud, clearly-marked failure signal: an
  **ephemeral** `:error` contract event with payload
  `%{reason: :journal_append_failed | :journal_open_failed, original_type: t,
  detail: ...}`, plus a `Logger.error`. If the failure was a dead Writer, the
  stale handle is dropped so the next durable event lazily reopens the journal
  and resumes from the on-disk offset — ids stay collision-free.

  ## Neutral -> contract mapping

  | neutral `type`     | tier         | contract `type`   |
  | ------------------ | ------------ | ----------------- |
  | `:command_result`  | `:ephemeral` | `:item_delta`     |
  | `:app_update`      | `:durable`   | `:item_completed` |
  | `:turn_started`    | `:durable`   | `:turn_started`   |
  | `:turn_completed`  | `:durable`   | `:turn_completed` |
  | `:error`           | `:durable`   | `:error`          |

  Anything else passes through as an `:item_completed` with its tier preserved.
  `family` and `turn_id` carry through unchanged; `ts` is preserved.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  defstruct [:session_id, :streamer, :journal, journal_opts: [], last_offset: 0]

  @type t :: %__MODULE__{
          session_id: term(),
          streamer: GenServer.server(),
          journal: FileStore.t() | nil,
          journal_opts: keyword(),
          last_offset: non_neg_integer()
        }

  @doc """
  Start a bridge for `session_id`.

  Options:

    * `:session_id` (required) — the EmitBus/SessionStreamer/Journal session key
    * `:streamer` — SessionStreamer server (default `Raxol.Agent.SessionStreamer`)
    * `:journal` — a pre-opened `Raxol.Agent.Journal.FileStore` handle (default:
      opened lazily on the first durable event)
    * `:journal_opts` — options forwarded to `FileStore.open/2` on lazy open
      (e.g. `:base_dir`); default `[]`
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
    journal = Keyword.get(opts, :journal)
    journal_opts = Keyword.get(opts, :journal_opts, [])

    EmitBus.subscribe(session_id)

    {:ok,
     %__MODULE__{
       session_id: session_id,
       streamer: streamer,
       journal: journal,
       journal_opts: journal_opts,
       last_offset: last_offset(journal)
     }}
  end

  # Durable tier: the journal owns the id. Append first, take the offset, emit.
  # The journal is the hard gate: if the append fails, the durable event is NOT
  # published (no fabricated id, `last_offset` untouched) — a loud ephemeral
  # `:error` event goes out instead. See the moduledoc.
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:emit_bus, session_id, %{tier: :durable} = neutral},
        %__MODULE__{session_id: session_id} = state
      ) do
    # Sanitize once and reuse for both the journal record and the live event so
    # the live tail and the replayed record are byte-identical, not just id-equal.
    safe = Map.put(neutral, :payload, sanitized_payload(neutral))

    case append_durable(state, safe) do
      {:ok, state, offset} ->
        event = map_event(safe, offset, session_id)
        SessionStreamer.emit(session_id, event, state.streamer)
        {:noreply, %{state | last_offset: offset}}

      {:error, state, failure_reason, detail} ->
        Logger.error(
          "[EmitBridge] dropping durable event #{inspect(Map.get(safe, :type))} " <>
            "for session #{inspect(session_id)}: #{failure_reason} (#{inspect(detail)})"
        )

        SessionStreamer.emit(
          session_id,
          journal_failure_event(state, safe, failure_reason, detail),
          state.streamer
        )

        {:noreply, state}
    end
  end

  # Ephemeral tier: never journaled. Id carries the last durable offset.
  def handle_manager_info(
        {:emit_bus, session_id, neutral},
        %__MODULE__{session_id: session_id} = state
      ) do
    event = map_event(neutral, state.last_offset, session_id)
    SessionStreamer.emit(session_id, event, state.streamer)
    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %__MODULE__{journal: nil}), do: :ok

  def terminate(_reason, %__MODULE__{journal: journal}) do
    FileStore.close(journal)
    :ok
  end

  @doc """
  Map a neutral EmitBus event map to a `Raxol.Agent.Contract.Event`.

  Pure. `id` becomes the contract event's offset (the journal offset for durable
  events; the last durable offset for ephemeral ones). `session_id` overrides the
  neutral map's (they are the same in practice).
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

  # --- durable id authority --------------------------------------------------

  # Append the durable event to the journal and return the assigned offset. The
  # journal is opened lazily on first use. The journal is the HARD GATE: on
  # open/append failure no id is fabricated (the Writer did not advance its
  # offset, so a fabricated id would collide with the next successful append —
  # the dual-id landmine). The caller drops the event from the live tail and
  # emits an ephemeral `:error` signal instead.
  defp append_durable(state, neutral) do
    case ensure_journal(state) do
      {:ok, state} ->
        case FileStore.append(state.journal, durable_record(neutral)) do
          {:ok, offset} ->
            {:ok, state, offset}

          {:error, detail} ->
            {:error, drop_dead_journal(state, detail), :journal_append_failed,
             detail}
        end

      {:error, state, detail} ->
        {:error, state, :journal_open_failed, detail}
    end
  end

  defp ensure_journal(%__MODULE__{journal: nil} = state) do
    case FileStore.open(to_string(state.session_id), state.journal_opts) do
      {:ok, handle} -> {:ok, %{state | journal: handle}}
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp ensure_journal(state), do: {:ok, state}

  # A dead Writer means the handle is stale forever; drop it so the next
  # durable event lazily reopens the journal and resumes from the on-disk
  # offset. Other errors (e.g. :enospc) keep the handle — the Writer is alive
  # and a later append may succeed once the condition clears.
  defp drop_dead_journal(state, {:writer_down, _}), do: %{state | journal: nil}
  defp drop_dead_journal(state, _detail), do: state

  # The loud failure signal that replaces a durable event the journal refused:
  # ephemeral (it must never look durable — it has no offset), id pinned to the
  # unchanged last durable offset.
  defp journal_failure_event(state, neutral, failure_reason, detail) do
    %Event{
      v: 0,
      id: state.last_offset,
      session_id: state.session_id,
      turn_id: Map.get(neutral, :turn_id),
      ts: System.system_time(:microsecond),
      family: Map.get(neutral, :family, :loop),
      type: :error,
      tier: :ephemeral,
      payload: %{
        reason: failure_reason,
        original_type: contract_type(Map.get(neutral, :type), :durable),
        detail: inspect(detail)
      }
    }
  end

  # A plain, JSON-encodable map persisted to the journal. The Writer stamps
  # `"id"` (= offset) and stringifies keys; replaying reconstructs the same
  # contract-typed event. Payload is already sanitized by the caller.
  defp durable_record(neutral) do
    %{
      v: 0,
      session_id: Map.get(neutral, :session_id),
      turn_id: Map.get(neutral, :turn_id),
      ts: Map.get(neutral, :ts, System.system_time(:microsecond)),
      family: Map.get(neutral, :family, :loop),
      type: contract_type(Map.get(neutral, :type), :durable),
      tier: :durable,
      payload: Map.get(neutral, :payload, %{})
    }
  end

  defp sanitized_payload(neutral) do
    Contract.sanitize_payload(Map.get(neutral, :payload, %{}))
  end

  # Resume the ephemeral-id watermark from a supplied journal so ephemeral ids
  # keep referencing a real durable offset across a restart.
  defp last_offset(nil), do: 0

  defp last_offset(%FileStore{} = journal) do
    case FileStore.read(journal) do
      {:ok, records} -> records |> List.last() |> record_id()
      _ -> 0
    end
  end

  defp last_offset(_), do: 0

  defp record_id(%{"id" => id}) when is_integer(id), do: id
  defp record_id(_), do: 0

  # Coarse Dispatcher types -> v0 loop vocabulary.
  defp contract_type(:command_result, _tier), do: :item_delta
  defp contract_type(:app_update, _tier), do: :item_completed
  defp contract_type(:turn_started, _tier), do: :turn_started
  defp contract_type(:turn_completed, _tier), do: :turn_completed
  defp contract_type(:error, _tier), do: :error
  defp contract_type(_other, _tier), do: :item_completed
end
