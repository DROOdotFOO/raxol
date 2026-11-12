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

  ## A required journal

  With `journal_required: true` the journal is not optional and not lazy: the
  bridge opens it in `init`, private and with `require_lock: true` (see
  `Raxol.Agent.Journal.FileStore`), and stops instead of starting when it
  cannot, so a session tree whose bridge is its first child does not start
  unjournaled. The stop reasons:

    * `{:journal_locked, os_pid}` - a live BEAM holds the writer lock
      (`{:journal_locked, :lock_unavailable}` when no lock could be taken)
    * `{:journal_bound, %{field: :cwd | :title, journal: recorded, requested:
      asked}}` - `meta.json` records another `:cwd` or `:title` than the one in
      `:journal_opts`: the journal belongs to another project root or
      application and is not continued
    * `{:journal_damaged, session_id}` - its records do not replay
    * `{:journal_open_failed, reason}` - anything else `FileStore.open/2` refused

  The journal continues and the model does not: every start appends
  `agent_started` (payload `prior_offset`, the offset the journal had reached;
  `0` for a new one) as its first record, then one `turn_canceled` (payload
  `reason: "agent_restarted"`) per `turn_started` an earlier run left without
  its closing bracket, so a checkpoint is never refused as mid-turn because of
  a turn nothing is running any more. `agent_started` is a `family: :loop`
  record outside the conversational set, so it is never a journal tip.

  Such a bridge traps exits, so a supervised stop runs `terminate/2`: the
  journal is flushed and its lock released before the stop returns. If its
  Writer exits the bridge stops too, and its supervisor reopens the journal.

  ## Neutral -> contract mapping

  | neutral `type`     | tier         | contract `type`   |
  | ------------------ | ------------ | ----------------- |
  | `:command_result`   | `:ephemeral` | `:item_delta`        |
  | `:app_update`       | `:durable`   | `:item_completed`    |
  | `:turn_started`     | `:durable`   | `:turn_started`      |
  | `:turn_completed`   | `:durable`   | `:turn_completed`    |
  | `:error`            | `:durable`   | `:error`             |
  | `:turn_canceled`    | `:durable`   | `:turn_canceled`     |
  | `:approval_requested` | (tier as sent) | `:approval_requested` |
  | `:item_started`     | (tier as sent) | `:item_started`    |
  | `:woken`            | (tier as sent) | `:woken`           |

  Anything else passes through as an `:item_completed` with its tier preserved.
  `family` and `turn_id` carry through unchanged; `ts` is preserved.

  ## U11 envelope carry-through (freeze §2.1)

  `scope` / `provenance` / `actor` flow end-to-end: the neutral map's values are
  stamped onto the live `Event` (`map_event/3`) AND the journal record
  (`durable_record/1`), and `actor` is stamped from the bridge's write-generation
  context at this producer seam (modules never invent it). `provenance` is met
  against the optional write-generation provenance context under the
  taint-absorbing meet (see the `:provenance` option and `stamp_provenance/2`):
  a tainted generation force-taints every event it emits, and a module-supplied
  `:tainted` is never overwritten — the seam can add taint, never remove it. To keep grandfathered
  records byte-identical (I2), the journal record OMITS any envelope field that
  equals its frozen default — a record without the key decodes back to that
  default via the grandfather clause, so only genuinely non-default provenance /
  scope / actor / branch actually land on disk. A non-default value is never
  stranded on one path.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  defstruct [
    :session_id,
    :streamer,
    :journal,
    :actor,
    :provenance,
    journal_opts: [],
    last_offset: 0,
    branch_id: "main"
  ]

  @type t :: %__MODULE__{
          session_id: term(),
          streamer: GenServer.server(),
          journal: FileStore.t() | nil,
          actor: map() | nil,
          provenance: map() | nil,
          journal_opts: keyword(),
          last_offset: non_neg_integer(),
          branch_id: String.t()
        }

  # The frozen grandfather defaults (freeze §2.1). An event carrying exactly
  # these values persists WITHOUT the envelope-growth keys — a record without
  # them decodes back to these defaults, so a default event stays byte-identical
  # to its pre-U11 form (I2). Non-default values ARE written and carried.
  @default_scope :session
  @default_provenance %{source: :primary, trust: :trusted}
  @default_branch_id "main"

  # Types that MUST be journaled regardless of the tier as sent: the doc calls
  # `approval_requested` a durable resume-bracket — emit it ephemeral and the
  # resume point is never journaled; `woken` marks a schedule/dormancy wake that
  # must survive replay. Their tier is forced to `:durable` at the emit seam.
  @durable_required_types [:approval_requested, :woken]

  # The brackets that close a `turn_started` (the checkpoint turn-boundary
  # rule counts the same three).
  @turn_closers ~w(turn_completed turn_canceled error)

  # A bridge restarted under its supervisor can find its predecessor's Writer
  # still flushing. It is given this long to exit before the journal counts as
  # held by another process of this BEAM.
  @writer_exit_ms 1_000

  @doc """
  Start a bridge for `session_id`.

  Options:

    * `:session_id` (required) — the EmitBus/SessionStreamer/Journal session key
    * `:streamer` — SessionStreamer server (default `Raxol.Agent.SessionStreamer`)
    * `:journal` — a pre-opened `Raxol.Agent.Journal.FileStore` handle (default:
      opened lazily on the first durable event); ignored with `:journal_required`
    * `:journal_required` — `true` to open the journal in `init` and stop when
      it cannot be opened, locked and bound (see "A required journal")
    * `:journal_opts` — options forwarded to `FileStore.open/2` (e.g.
      `:base_dir`, and the `:cwd` and `:title` a required journal is bound
      to); default `[]`
    * `:actor` — the write-generation actor (`%{kind, id}`) stamped onto every
      event this bridge emits when the neutral map does not already carry one
      (freeze §2.1: actor is producer-seam stamped, modules never invent it);
      default `nil` (system emission)
    * `:provenance` — the write-generation provenance context
      (`%{source, trust}`) met against every event this bridge emits, under
      the TAINT-ABSORBING meet (freeze §2.1 taint law pt.3): a generation
      classified `trust: :tainted` (e.g. a tool-result generation from an
      untrusted source — the classification itself is U8 policy) force-taints
      every event in the generation, a module-supplied `:tainted` is never
      overwritten, and an omitted module provenance takes the generation's.
      Default `nil` — no generation classification; a module omission then
      decodes to the frozen grandfather default (`:trusted`), which is the
      frozen §2.1 shape and cannot change here
    * `:branch_id` — the speculation branch these events belong to (freeze
      §1.1); default `"main"`, which is implicit on the wire (grandfather-safe)
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

    case initial_journal(session_id, opts) do
      {:ok, journal, journal_opts, last_offset} ->
        EmitBus.subscribe(session_id)

        {:ok,
         %__MODULE__{
           session_id: session_id,
           streamer: streamer,
           journal: journal,
           actor: Keyword.get(opts, :actor),
           provenance: Keyword.get(opts, :provenance),
           journal_opts: journal_opts,
           last_offset: last_offset,
           branch_id: Keyword.get(opts, :branch_id, @default_branch_id)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp initial_journal(session_id, opts) do
    journal_opts = Keyword.get(opts, :journal_opts, [])

    if Keyword.get(opts, :journal_required, false) == true do
      # So that a stop from the supervisor closes the journal (see the moduledoc).
      Process.flag(:trap_exit, true)
      journal_opts = Keyword.merge(journal_opts, private: true, require_lock: true)

      with {:ok, journal} <- open_owned(session_id, journal_opts, 2),
           {:ok, last_offset} <- continue_journal(journal, session_id, journal_opts) do
        {:ok, journal, journal_opts, last_offset}
      end
    else
      journal = Keyword.get(opts, :journal)
      {:ok, journal, journal_opts, last_offset(journal)}
    end
  end

  # The bridge must own its Writer: a handle that joined another process's
  # Writer would lose the journal when that process closed it.
  defp open_owned(session_id, journal_opts, attempts) do
    case FileStore.open(to_string(session_id), journal_opts) do
      {:ok, %FileStore{owner?: true} = journal} ->
        {:ok, journal}

      {:ok, %FileStore{writer: writer}} when attempts > 1 ->
        await_exit(writer)
        open_owned(session_id, journal_opts, attempts - 1)

      {:ok, %FileStore{}} ->
        {:error, {:journal_locked, System.pid()}}

      {:error, {:journal_locked, _holder}} = locked ->
        locked

      {:error, reason} ->
        {:error, {:journal_open_failed, reason}}
    end
  end

  defp await_exit(writer) do
    ref = Process.monitor(writer)

    receive do
      {:DOWN, ^ref, :process, ^writer, _reason} -> :ok
    after
      @writer_exit_ms -> Process.demonitor(ref, [:flush])
    end
  end

  # Runs under the Writer's lock. A refusal closes the journal again, which
  # releases the lock.
  defp continue_journal(journal, session_id, journal_opts) do
    with :ok <- check_binding(journal, journal_opts),
         {:ok, records} <- read_all(journal, session_id),
         {:ok, offsets} <- append_reopening(journal, session_id, records) do
      {:ok, List.last(offsets)}
    else
      {:error, _reason} = refusal ->
        FileStore.close(journal)
        refusal
    end
  end

  defp check_binding(journal, journal_opts) do
    case FileStore.read_meta(journal) do
      {:ok, meta} ->
        Enum.find_value([cwd: "cwd", title: "title"], :ok, &unbound(&1, meta, journal_opts))

      {:error, reason} ->
        {:error, {:journal_open_failed, {:meta, reason}}}
    end
  end

  defp unbound({opt, key}, meta, journal_opts) do
    case {Keyword.get(journal_opts, opt), Map.get(meta, key)} do
      {nil, _recorded} -> nil
      {requested, requested} -> nil
      {requested, recorded} -> {:error, {:journal_bound, bound(opt, recorded, requested)}}
    end
  end

  defp bound(field, recorded, requested),
    do: %{field: field, journal: recorded, requested: requested}

  defp read_all(journal, session_id) do
    case FileStore.read(journal) do
      {:ok, records} -> {:ok, records}
      {:error, :damaged} -> {:error, {:journal_damaged, session_id}}
    end
  end

  defp append_reopening(journal, session_id, records) do
    started =
      lifecycle_record(session_id, :agent_started, nil, %{
        prior_offset: records |> List.last() |> record_id()
      })

    sealed =
      for turn_id <- dangling_turns(records),
          do: lifecycle_record(session_id, :turn_canceled, turn_id, %{reason: :agent_restarted})

    case FileStore.append_many(journal, [started | sealed], :infinity) do
      {:ok, offsets} -> {:ok, offsets}
      {:error, reason} -> {:error, {:journal_open_failed, {:append, reason}}}
    end
  end

  # One entry per `turn_started` whose turn id has no closing bracket after
  # it, counted per turn id: a later BEAM mints the same turn ids again.
  defp dangling_turns(records) do
    records
    |> Enum.reduce(%{}, fn record, open ->
      case {Map.get(record, "type"), Map.get(record, "turn_id")} do
        {"turn_started", turn_id} -> Map.update(open, turn_id, 1, &(&1 + 1))
        {type, turn_id} when type in @turn_closers -> close_turn(open, turn_id)
        _other -> open
      end
    end)
    |> Enum.flat_map(fn {turn_id, count} -> List.duplicate(turn_id, count) end)
  end

  defp close_turn(open, turn_id) do
    case open do
      %{^turn_id => count} when count > 0 -> Map.put(open, turn_id, count - 1)
      _not_open -> open
    end
  end

  defp lifecycle_record(session_id, type, turn_id, payload) do
    %{
      v: 0,
      session_id: session_id,
      turn_id: turn_id,
      ts: System.system_time(:microsecond),
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  # Durable-required resume-brackets: force `:durable` no matter the tier as
  # sent, then take the shared durable path. This clause precedes the tier-based
  # ones so an `approval_requested`/`woken` emitted ephemeral still lands in the
  # journal (its resume point would otherwise be lost).
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:emit_bus, session_id, %{type: type} = neutral},
        %__MODULE__{session_id: session_id} = state
      )
      when type in @durable_required_types do
    handle_durable(session_id, Map.put(neutral, :tier, :durable), state)
  end

  # Durable tier: the journal owns the id. Append first, take the offset, emit.
  # The journal is the hard gate: if the append fails, the durable event is NOT
  # published (no fabricated id, `last_offset` untouched) — a loud ephemeral
  # `:error` event goes out instead. See the moduledoc.
  def handle_manager_info(
        {:emit_bus, session_id, %{tier: :durable} = neutral},
        %__MODULE__{session_id: session_id} = state
      ) do
    handle_durable(session_id, neutral, state)
  end

  # Ephemeral tier: never journaled. Id carries the last durable offset. The
  # write-generation actor is stamped here too so live ephemeral events (deltas)
  # carry the same actor as the durable events they refine.
  def handle_manager_info(
        {:emit_bus, session_id, neutral},
        %__MODULE__{session_id: session_id} = state
      ) do
    event =
      map_event(stamp_generation(neutral, state), state.last_offset, session_id)

    SessionStreamer.emit(session_id, event, state.streamer)
    {:noreply, state}
  end

  # Reaches a bridge that traps exits, i.e. one with a required journal.
  def handle_manager_info(
        {:EXIT, writer, reason},
        %__MODULE__{journal: %FileStore{writer: writer}} = state
      ) do
    {:stop, {:journal_writer_down, reason}, %{state | journal: nil}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # Shared durable path (append-before-publish). Sanitize once and reuse for
  # both the journal record and the live event so the live tail and the replayed
  # record are byte-identical, not just id-equal. Stamp the write-generation
  # actor here (producer seam). On append failure the event is dropped from the
  # live tail and a loud ephemeral `:error` signal goes out instead.
  defp handle_durable(session_id, neutral, state) do
    safe =
      neutral
      |> Map.put(:payload, sanitized_payload(neutral))
      |> stamp_generation(state)

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
  neutral map's (they are the same in practice). The U11 envelope fields
  (`scope`/`provenance`/`actor`) are carried through from the neutral map,
  falling back to the frozen grandfather defaults so a producer that stamps
  nothing still yields a well-formed default envelope (freeze §2.1).
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
      payload: Map.get(neutral, :payload, %{}),
      scope: Map.get(neutral, :scope, @default_scope),
      provenance: Map.get(neutral, :provenance, @default_provenance),
      actor: Map.get(neutral, :actor),
      # The live path carries branch_id so it agrees with the durable record
      # (the durable + live envelopes must never diverge on a field, §1.1).
      branch_id: Map.get(neutral, :branch_id, @default_branch_id)
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
            {:error, drop_dead_journal(state, detail), :journal_append_failed, detail}
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
  #
  # The U11 envelope-growth fields (scope / provenance / actor / branch_id) are
  # written ONLY when they are non-default: a record that carries exactly the
  # frozen defaults omits them and decodes back to those defaults via the
  # grandfather clause, so a default event's on-disk bytes are byte-identical to
  # its pre-U11 form (I2 preserved). A non-default value is always persisted —
  # never stranded on the live path while missing from the journal.
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
    |> put_when_non_default(:scope, Map.get(neutral, :scope), @default_scope)
    |> put_when_non_default(
      :provenance,
      Map.get(neutral, :provenance),
      @default_provenance
    )
    |> put_actor(Map.get(neutral, :actor))
    |> put_when_non_default(
      :branch_id,
      Map.get(neutral, :branch_id),
      @default_branch_id
    )
  end

  # Add `key` only when the carried value is present and differs from the frozen
  # default — the grandfather-symmetric write (absent on disk ⇒ default on read).
  defp put_when_non_default(record, _key, nil, _default), do: record

  defp put_when_non_default(record, _key, value, default) when value == default,
    do: record

  defp put_when_non_default(record, key, value, _default),
    do: Map.put(record, key, value)

  # actor is `%{kind, id} | nil`; a nil actor is the system default (absent on
  # disk), any present actor is persisted verbatim.
  defp put_actor(record, nil), do: record
  defp put_actor(record, actor), do: Map.put(record, :actor, actor)

  # Stamp the write-generation actor + branch id onto a neutral map at the
  # producer seam (freeze §2.1: "EmitBridge stamps actor from the command/attach
  # context ... Individual modules never invent it"). The bridge value WINS
  # unconditionally (`Map.put`, not `Map.put_new`): a neutral map that already
  # carries an `:actor` — a module inventing its own — must NOT bypass the
  # producer-seam stamp, or a nullable-everywhere field becomes inconsistent
  # garbage and the trust lattice's actor attribution is spoofable. The branch id
  # is forced the same way so every event in one generation shares exactly one
  # branch_id (the tip predicate is branch-aware; a per-event branch would strand
  # events across branches).
  defp stamp_generation(neutral, state) do
    neutral
    |> Map.put(:actor, state.actor)
    |> Map.put(:branch_id, state.branch_id)
    |> stamp_provenance(state.provenance)
  end

  # Provenance at the producer seam. Unlike actor/branch_id this is NOT a
  # blind `Map.put`: taint is one-way (§2.1 taint law pt.3, "no laundering"),
  # so the stamp is the TAINT-ABSORBING MEET of the module-supplied value and
  # the write-generation context — the bridge can only ADD taint, never remove
  # it. An unconditional overwrite here would itself be a laundering machine
  # (a module honestly stamping `:tainted` overwritten by a `:trusted`
  # generation default). With no generation context the module value flows
  # unchanged and the read side's fail-closed decode governs.
  defp stamp_provenance(neutral, nil), do: neutral

  defp stamp_provenance(neutral, gen_prov) do
    Map.update(neutral, :provenance, gen_prov, &meet_provenance(&1, gen_prov))
  end

  # A wrong-shaped (non-map) module provenance fails CLOSED — replacing it
  # with the generation value could launder garbage into an explicit
  # `:trusted`; mirroring `Meta.decode_provenance/1`'s wrong-shape arm keeps
  # the write side and read side agreeing.
  defp meet_provenance(module_prov, _gen_prov) when not is_map(module_prov),
    do: %{source: :primary, trust: :tainted}

  # Module already tainted: never overwritten (no upgrade path exists in v1).
  defp meet_provenance(%{trust: :tainted} = module_prov, _gen_prov),
    do: module_prov

  # Generation classified tainted: force-taint, keep the module's source.
  defp meet_provenance(module_prov, %{trust: :tainted}),
    do: Map.put(module_prov, :trust, :tainted)

  defp meet_provenance(module_prov, _gen_prov), do: module_prov

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
  defp contract_type(:turn_canceled, _tier), do: :turn_canceled
  # Frozen-but-not-landed loop vocabulary (freeze §1.1 / storage-foundations):
  # these bracket events pass through with their own type instead of collapsing
  # to :item_completed. `approval_requested` is a durable bracket (a resume-point
  # cannot be a bare item), `item_started` opens an item the later
  # `item_completed` closes, `woken` marks a `schedule`/dormancy wake.
  defp contract_type(:approval_requested, _tier), do: :approval_requested
  defp contract_type(:item_started, _tier), do: :item_started
  defp contract_type(:woken, _tier), do: :woken
  defp contract_type(_other, _tier), do: :item_completed
end
