defmodule Raxol.AgentClientProtocol.Connection.Ctx do
  @moduledoc """
  Per-dispatch handler context (IC-2 in both `acp-connection-design.md` and
  `acp-supervision-design.md`, v2).

  One `Ctx` is built by `Raxol.AgentClientProtocol.Connection` for every
  inbound request/notification and handed to the handler task that runs the
  matching callback OUTSIDE the Connection process. `handler_state` is
  **read-only per dispatch** (connection design §4.5): handlers are
  concurrent tasks, so there is no safe way to thread mutable state through
  them — stateful per-session logic lives in the Session layer, not here.

  `reply_ref` is present (`reference()`) for requests and `nil` for
  notifications. `rx_seq` is the inbound frame's monotone sequence stamp
  (IC-5c) — `begin_prompt` forwards it to the Session so cancel-vs-prompt
  commutes by wire order.
  """

  @enforce_keys [:conn, :role]
  defstruct conn: nil,
            role: :agent,
            caps: nil,
            handler_state: nil,
            reply_ref: nil,
            rx_seq: 0,
            session_sup: nil,
            task_sup: nil

  @type t :: %__MODULE__{
          conn: pid(),
          role: :agent | :client,
          caps: term() | nil,
          handler_state: term(),
          reply_ref: reference() | nil,
          rx_seq: non_neg_integer(),
          session_sup: pid() | nil,
          task_sup: pid() | nil
        }
end

defmodule Raxol.AgentClientProtocol.Connection do
  @moduledoc """
  ONE GenServer per peer link, either role — the correlation + dispatch brain
  of ACP. Implements `acp-connection-design.md` v2 (G2-CONVERGED) exactly;
  the shared Interface Contract (§IC-1..IC-8), byte-identical in the
  connection and supervision designs, is the source of truth for every
  cross-module seam cited below.

  The same module runs as `:agent` or `:client`; `role` only selects which
  MethodTable direction is *inbound* (`side = role`). The Connection:

    * **never blocks** — no `GenServer.call` to itself, no synchronous wait
      on tasks, no transport call that waits on peer progress (§5, IC-7);
    * **never runs handler code in its own process** — every inbound
      request/notification is dispatched to a `Task.Supervisor.async_nolink`
      task (§4);
    * **never creates an atom from wire input** — all method→atom mapping is
      `Router`/`MethodTable` compile-time clauses (§1.1, Inv-7).

  ## Correctness spine

    * Outbound: `async_request/6` is THE primitive (IC-3); `request/4` is a
      caller-parking wrapper on the same `pending_out` table. The Connection
      is the **single timeout authority** (`Process.send_after`, §2.3) — no
      caller arms a parallel timer. Every pending_out entry leaves through
      exactly one of: correlated response (§2.4), timeout (§2.3),
      `cancel_request/2` (§2.5), or `reject_all_outgoing` (§3). No fifth path.
    * Inbound: dispatch via `async_nolink`; crash ⇒ `-32603` with the id
      echoed at its exact wire type (§4.3); notification crash ⇒ log only,
      never a frame (§4.4). `$/cancel_request` and `session/cancel` are
      Connection-intercepted BEFORE `Router.decode/4` (§6, MethodTable rows
      carry the `:protocol` / `:session_control` layer tags).
    * Delegated reply (IC-4): `delegate_reply/3` + `reply/3` + `:deferred`
      let the Session own WHEN the `session/prompt` response is sent while
      keeping updates and the response on ONE FIFO lane (§4.6).
    * Response-count invariant (IC-6): at most one response frame per inbound
      id; exactly one unless the peer `$/cancel_request`'d it first (then
      zero).

  ## Deviations from the design forced by shipped dependencies

  These are reported verbatim to the orchestrator; each is the minimal
  adaptation the design's own escape hatch permits ("if a design detail
  conflicts with the shipped Router API, report it and adapt minimally"):

    1. The design's `MethodTable.result_decoder(method)` + `mod.from_map/1`
       are realized as the shipped `Router.result_marker/1` +
       `mod.from_json/1` (§2.4).
    2. `Router.decode/4` returns the raw schema-decode error tuple (not the
       design's `{:invalid_params, reason}`); any non-`:method_not_found`
       decode error is mapped to `-32602` (§4.1).
    3. The capability gate is located BEFORE decode with the correct
       `-32601`-beats-`-32602` ordering. The permissive seam is now CLOSED
       (W17-caps wave): `capability_denied?/2` delegates to the real
       `Capabilities.negotiated?/2`, which fails closed on any
       missing/`nil`/`false` capability. Closing it required one change the
       original deviation did not foresee ("only that predicate changes"):
       the `caps` SNAPSHOT is now the RECEIVER's OWN capability tree, not the
       whole `initialize` message. The agent snapshots `agent_capabilities`
       from the response it sends; the client snapshots `client_capabilities`
       from the request it sends (stashed in `own_caps` at outbound-submit
       time, committed at handshake), because the client's own caps are not
       present in the `initialize` RESPONSE it receives. See
       `Capabilities` + `MethodTable`'s ORACLE-DIVERGENCE note
       (`session/delete`/`close`/`logout` fail closed — the ported caps
       structs cannot express those gates).
    4. `transport_ref` and the monitored carrier pid are both taken from the
       handle's `:pid` field (the Transport behaviour exposes no ref
       accessor; Paired — and the future stdio reader — expose `:pid`, and
       Paired's inbound frames are tagged with that same pid, verified by
       `paired_test.exs`).
    5. Telemetry events are emitted only when `:telemetry` is loaded (it is
       not a package dependency); otherwise `Logger` carries the signal.
    6. Sibling `task_sup`/`session_sup` may be injected directly in
       `start_link/1` opts (test convenience) in addition to the design's
       `parent_sup` + `which_children` resolution in `handle_continue/2`
       (IC-8); the shared IC pins the tree shape but not the child ids, so
       resolution is by child module/type heuristic.
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.{Capabilities, Error, Router}
  alias Raxol.AgentClientProtocol.Connection.Ctx
  alias Raxol.AgentClientProtocol.Rpc.{Message, Notification, Request, RequestId, Response}
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification

  @session_registry Raxol.AgentClientProtocol.SessionRegistry

  # Inbound-request concurrency cap (flood-DoS shed, §4). `pending_in` (and its
  # co-indexed `reply_refs`/`task_index`, plus one dispatch task each) is bounded
  # by this many CONCURRENT in-flight inbound requests; a peer that streams more
  # is SHED (`-32603` server-busy, dispatch nothing) rather than growing the maps
  # or the task set without bound. Sized well under a healthy single-link request
  # concurrency but low enough that an adversarial flood cannot exhaust memory;
  # override per-connection via the `:max_inbound` start_link opt.
  @default_max_inbound 1_000

  defstruct role: :agent,
            transport_mod: nil,
            transport_state: nil,
            transport_ref: nil,
            transport_monitor: nil,
            phase: :booting,
            caps: nil,
            own_caps: nil,
            parent_sup: nil,
            session_sup: nil,
            rx_seq: 0,
            next_out_id: 1,
            pending_out: %{},
            out_tags: %{},
            pending_in: %{},
            reply_refs: %{},
            task_index: %{},
            handler: nil,
            handler_state: nil,
            task_sup: nil,
            max_in: @default_max_inbound

  @type role :: :agent | :client

  @typedoc "Outcome delivered for an accepted outbound submission (IC-3)."
  @type outcome ::
          {:ok, struct()}
          | {:ok, {:ext, map()}}
          | {:error, Error.t() | :timeout | :connection_closed | {:result_decode, term()}}

  # ===========================================================================
  # Public API — every function raises ArgumentError when conn == self()
  # (§2.1 / §5 cycle 1: no code running IN the Connection may call back into it).
  # ===========================================================================

  @doc "Start a Connection. Opts: `:role`, `:transport` `{mod, handle}`, `:handler`, `:handler_arg`, `:max_inbound` (concurrent inbound-request cap, default #{@default_max_inbound}), and either `:parent_sup` (IC-8) or direct `:task_sup`/`:session_sup`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  PRIMITIVE outbound submit (IC-3). Non-blocking: returns `:ok` once the
  frame is accepted by the transport, and later delivers **exactly one**
  `{:acp_result, tag, outcome}` to `owner` — unless `owner` consumed the
  entry first via `cancel_request/2` (then zero). Connection owns the timeout.
  """
  @spec async_request(
          pid(),
          String.t(),
          struct() | map() | nil,
          pid(),
          term(),
          pos_integer() | :infinity
        ) ::
          :ok | {:error, :not_initialized | :connection_closed | {:transport, term()}}
  def async_request(conn, method, params, owner, tag, timeout_ms)
      when is_pid(conn) and is_binary(method) and is_pid(owner) do
    reject_self!(conn)
    GenServer.call(conn, {:async_request, method, params, owner, tag, timeout_ms})
  end

  @doc """
  WRAPPER outbound request (IC-3): parks the caller on `pending_out` and
  returns the outcome. Outer `GenServer.call` timeout is `:infinity` by
  design — the protocol timeout is the Connection's internal timer, the ONE
  authority (§2.1).
  """
  @spec request(pid(), String.t(), struct() | map() | nil, pos_integer()) ::
          {:ok, struct()} | {:ok, {:ext, map()}} | {:error, term()}
  def request(conn, method, params, timeout_ms)
      when is_pid(conn) and is_binary(method) and is_integer(timeout_ms) do
    reject_self!(conn)
    GenServer.call(conn, {:request, method, params, timeout_ms}, :infinity)
  end

  @doc "Fire-and-forget notification (IC-3): a `GenServer.call` for per-sender FIFO + backpressure; touches no pending table, arms no timer."
  @spec notify(pid(), String.t(), struct() | map() | nil) :: :ok | {:error, term()}
  def notify(conn, method, params) when is_pid(conn) and is_binary(method) do
    reject_self!(conn)
    GenServer.call(conn, {:notify, method, params})
  end

  @doc "Cancel a pending `async_request` by its `{owner, tag}` (IC-3). Pops the entry, cancels its timer, best-effort `$/cancel_request`, delivers nothing. Unknown tag ⇒ `:ok`."
  @spec cancel_request(pid(), term()) :: :ok
  def cancel_request(conn, tag) when is_pid(conn) do
    reject_self!(conn)
    GenServer.call(conn, {:cancel_request, tag})
  end

  @doc "Transfer an inbound request's reply obligation to `adopter` (IC-4). MUST return before the handler returns `:deferred`. Connection monitors the adopter."
  @spec delegate_reply(pid(), reference(), pid()) :: :ok | {:error, :unknown_ref}
  def delegate_reply(conn, reply_ref, adopter)
      when is_pid(conn) and is_reference(reply_ref) and is_pid(adopter) do
    reject_self!(conn)
    GenServer.call(conn, {:delegate_reply, reply_ref, adopter})
  end

  @doc "Discharge a delegated reply obligation (IC-4). Idempotent-safe: a consumed/unknown/cancelled `reply_ref` is a suppressed no-op (`[:raxol, :acp, :dup_reply]`) and still returns `:ok`."
  @spec reply(pid(), reference(), {:ok, struct()} | {:error, Error.t()}) :: :ok
  def reply(conn, reply_ref, result_or_error)
      when is_pid(conn) and is_reference(reply_ref) do
    reject_self!(conn)
    GenServer.call(conn, {:reply, reply_ref, result_or_error})
  end

  @doc "Graceful close (§7.3): reject outgoing, kill undelegated inbound tasks, close transport, stop `:normal`."
  @spec close(pid()) :: :ok
  def close(conn) when is_pid(conn) do
    reject_self!(conn)
    GenServer.call(conn, :close)
  end

  defp reject_self!(conn) do
    if conn == self() do
      raise ArgumentError,
            "Connection API called with conn == self(): forbidden re-entrant cycle (§5)"
    end
  end

  # ===========================================================================
  # Lifecycle (§7.1) — init stores args + traps exits; ALL sibling resolution
  # and transport adoption happen in handle_continue (IC-8, avoids the
  # which_children-from-init deadlock).
  # ===========================================================================

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = Keyword.fetch!(opts, :handler)
    handler_arg = Keyword.get(opts, :handler_arg)

    case handler.init(handler_arg) do
      {:ok, handler_state} ->
        {mod, handle} = Keyword.fetch!(opts, :transport)

        state = %__MODULE__{
          role: Keyword.get(opts, :role, :agent),
          transport_mod: mod,
          transport_state: handle,
          phase: :booting,
          parent_sup: Keyword.get(opts, :parent_sup),
          session_sup: Keyword.get(opts, :session_sup),
          task_sup: Keyword.get(opts, :task_sup),
          handler: handler,
          handler_state: handler_state,
          max_in: Keyword.get(opts, :max_inbound, @default_max_inbound)
        }

        {:ok, state, {:continue, :boot}}

      {:stop, reason} ->
        {:stop, reason}

      other ->
        {:stop, {:bad_handler_init, other}}
    end
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    {task_sup, session_sup} = resolve_siblings(state)

    carrier = carrier_pid(state.transport_state)
    maybe_set_owner(state.transport_mod, state.transport_state)
    monitor = if carrier, do: Process.monitor(carrier), else: nil

    state = %{
      state
      | task_sup: task_sup,
        session_sup: session_sup,
        transport_ref: carrier,
        transport_monitor: monitor,
        phase: :uninitialized
    }

    {:noreply, state}
  end

  defp resolve_siblings(%{parent_sup: nil} = state), do: {state.task_sup, state.session_sup}

  defp resolve_siblings(%{parent_sup: sup}) do
    children = Supervisor.which_children(sup)

    task_sup =
      Enum.find_value(children, fn {_id, pid, _type, mods} ->
        if is_pid(pid) and Task.Supervisor in mods, do: pid
      end)

    session_sup =
      Enum.find_value(children, fn {_id, pid, type, mods} ->
        if is_pid(pid) and pid != self() and type == :supervisor and Task.Supervisor not in mods,
          do: pid
      end)

    {task_sup, session_sup}
  end

  defp maybe_set_owner(mod, handle) do
    if function_exported?(mod, :set_owner, 2), do: mod.set_owner(handle, self())
    :ok
  end

  defp carrier_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp carrier_pid(_handle), do: nil

  # ===========================================================================
  # Outbound (§2)
  # ===========================================================================

  @impl GenServer
  def handle_call({:request, method, params, timeout_ms}, from, state) do
    case submit_outbound(method, params, timeout_ms, {:call, from}, state) do
      {:parked, st} -> {:noreply, st}
      {:answered, answer, st} -> {:reply, answer, st}
    end
  end

  def handle_call({:async_request, method, params, owner, tag, timeout_ms}, _from, state) do
    case submit_outbound(method, params, timeout_ms, {:owner, owner, tag}, state) do
      {:parked, st} -> {:reply, :ok, st}
      {:answered, answer, st} -> {:reply, answer, st}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    cond do
      state.phase in [:booting, :closed] ->
        {:reply, {:error, :connection_closed}, state}

      state.phase != :initialized and method != "initialize" ->
        {:reply, {:error, :not_initialized}, state}

      true ->
        case to_wire(params) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:ok, wire_params} ->
            frame = wire(Notification.new(method, wire_params))

            case push_frame(state, frame) do
              {:ok, st} ->
                {:reply, :ok, st}

              {:down, reason} ->
                {:stop, :normal, {:error, {:transport, reason}}, transport_down(reason, state)}
            end
        end
    end
  end

  def handle_call({:cancel_request, tag}, {owner_pid, _}, state) do
    case Map.pop(state.out_tags, {owner_pid, tag}) do
      {nil, _} ->
        {:reply, :ok, state}

      {id, out_tags} ->
        {entry, pending_out} = Map.pop(state.pending_out, id)
        if entry && entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        best_effort_cancel_notify(id, state)
        {:reply, :ok, %{state | pending_out: pending_out, out_tags: out_tags}}
    end
  end

  # -- Delegated reply (§4.6, IC-4) --

  def handle_call({:delegate_reply, reply_ref, adopter}, _from, state) do
    case Map.get(state.reply_refs, reply_ref) do
      nil ->
        {:reply, {:error, :unknown_ref}, state}

      id ->
        mon = Process.monitor(adopter)
        entry = Map.fetch!(state.pending_in, id)
        pending_in = Map.put(state.pending_in, id, %{entry | adopter: {adopter, mon}})
        {:reply, :ok, %{state | pending_in: pending_in}}
    end
  end

  def handle_call({:reply, reply_ref, result_or_error}, _from, state) do
    case Map.pop(state.reply_refs, reply_ref) do
      {nil, _} ->
        emit_telemetry([:raxol, :acp, :dup_reply], %{reply_ref: reply_ref})
        {:reply, :ok, state}

      {id, reply_refs} ->
        {entry, pending_in} = Map.pop(state.pending_in, id)
        demonitor_adopter(entry)
        st = %{state | reply_refs: reply_refs, pending_in: pending_in}

        if entry.cancelled? do
          # IC-5a/d: the id was abandoned; emit nothing.
          {:reply, :ok, st}
        else
          case push_frame(st, response_frame(id, result_or_error)) do
            {:ok, st2} ->
              {:reply, :ok, maybe_agent_initialized(id, entry, result_or_error, st2)}

            {:down, reason} ->
              {:stop, :normal, :ok, transport_down(reason, st)}
          end
        end
    end
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, transport_down(:local_close, state)}
  end

  # Gate + mint + send (§2.2). Returns {:parked, state} (entry pended, caller
  # waits) or {:answered, answer, state} (gated or transport-refused now).
  defp submit_outbound(method, params, timeout_ms, reply_to, state) do
    cond do
      state.phase in [:booting, :closed] ->
        {:answered, {:error, :connection_closed}, state}

      state.phase != :initialized and method != "initialize" ->
        {:answered, {:error, :not_initialized}, state}

      true ->
        case to_wire(params) do
          {:error, reason} ->
            # Never sent to the wire: no id consumed, no timer armed.
            {:answered, {:error, reason}, state}

          {:ok, wire_params} ->
            state = maybe_stash_own_caps(state, method, params)
            id = state.next_out_id
            state = %{state | next_out_id: id + 1}
            frame = wire(Request.new(id, method, wire_params))

            case state.transport_mod.send_message(state.transport_state, frame) do
              {:error, reason} ->
                # Nothing pended, no timer; counter still consumed (gaps harmless, §1.2).
                {:answered, {:error, {:transport, reason}}, state}

              {:ok, ts} ->
                timer_ref = arm_timer(id, timeout_ms)

                pending = %{reply_to: reply_to, method: method, timer_ref: timer_ref}

                st = %{
                  state
                  | transport_state: ts,
                    pending_out: Map.put(state.pending_out, id, pending),
                    out_tags: add_tag(state.out_tags, reply_to, id)
                }

                {:parked, st}
            end
        end
    end
  end

  defp arm_timer(_id, :infinity), do: nil

  defp arm_timer(id, timeout_ms) when is_integer(timeout_ms) do
    Process.send_after(self(), {:outbound_timeout, id}, timeout_ms)
  end

  defp add_tag(out_tags, {:owner, pid, tag}, id), do: Map.put(out_tags, {pid, tag}, id)
  defp add_tag(out_tags, {:call, _from}, _id), do: out_tags

  defp drop_tag(out_tags, {:owner, pid, tag}), do: Map.delete(out_tags, {pid, tag})
  defp drop_tag(out_tags, {:call, _from}), do: out_tags

  # ===========================================================================
  # Timeout path (§2.3) — deliver AND delete in the same clause.
  # ===========================================================================

  @impl GenServer
  def handle_info({:outbound_timeout, id}, state) do
    case Map.pop(state.pending_out, id) do
      {nil, _} ->
        {:noreply, state}

      {%{reply_to: rt}, pending_out} ->
        deliver_outcome(rt, {:error, :timeout})
        best_effort_cancel_notify(id, state)
        {:noreply, %{state | pending_out: pending_out, out_tags: drop_tag(state.out_tags, rt)}}
    end
  end

  # -- Transport inbound (§4) --

  def handle_info({:acp_transport, ref, {:message, frame}}, state) do
    if ref == state.transport_ref do
      rx_seq = state.rx_seq + 1
      handle_message(frame, rx_seq, %{state | rx_seq: rx_seq})
    else
      Logger.debug("ACP: dropping frame from stale transport ref #{inspect(ref)}")
      {:noreply, state}
    end
  end

  def handle_info({:acp_transport, ref, {:closed, reason}}, state) do
    if ref == state.transport_ref do
      {:stop, :normal, transport_down(reason, state)}
    else
      {:noreply, state}
    end
  end

  # A torn/non-JSON inbound line, or a decoded-but-non-object top-level term
  # (incl. a JSON array), reaches the Connection via the transport's own
  # decode-failure channel (Stdio; Paired never produces this). The
  # `handle_message(frame, ...) when is_list(frame)` clause above only fires
  # for pre-decoded-term transports (Paired); over a real byte-level
  # transport a JSON array arrives here as `{:not_an_object, list}` instead,
  # so it is routed to the same -32600 batch response. Any other decode
  # failure (unparseable JSON, a non-object/non-array top-level scalar, an
  # oversized frame) is a genuine parse error (§9). Never tears the
  # connection down (Inv-15 parity).
  def handle_info({:acp_transport, ref, {:decode_error, reason, _raw_line}}, state) do
    if ref == state.transport_ref do
      handle_decode_error(reason, state)
    else
      Logger.debug("ACP: dropping decode_error from stale transport ref #{inspect(ref)}")
      {:noreply, state}
    end
  end

  # -- Task success (§4.2 / §4.4) --

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.get(state.task_index, ref) do
      {:request, id} ->
        Process.demonitor(ref, [:flush])

        handle_request_result(id, result, %{state | task_index: Map.delete(state.task_index, ref)})

      {:notification, _method} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | task_index: Map.delete(state.task_index, ref)}}

      nil ->
        {:noreply, state}
    end
  end

  # -- DOWN: transport carrier | task crash | adopter death (§4.3 / §4.7 / §3) --

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.transport_monitor ->
        {:stop, :normal, transport_down(reason, state)}

      Map.has_key?(state.task_index, ref) ->
        handle_task_down(ref, reason, state)

      true ->
        case find_adopter(state.pending_in, ref) do
          {id, entry} -> handle_adopter_down(id, entry, state)
          nil -> {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Inbound classification (§4)
  # ===========================================================================

  defp handle_message(frame, rx_seq, state) when is_list(frame) do
    # Batch (JSON array): ACP does not use batches — -32600, null id.
    _ = rx_seq
    emit_and_continue(response_frame(nil, {:error, Error.invalid_request()}), state)
  end

  defp handle_message(frame, rx_seq, state) when is_map(frame) do
    cond do
      Map.has_key?(frame, "id") and Map.has_key?(frame, "method") ->
        classify_request(frame, rx_seq, state)

      Map.has_key?(frame, "id") and
          (Map.has_key?(frame, "result") or Map.has_key?(frame, "error")) ->
        classify_response(frame, state)

      Map.has_key?(frame, "method") ->
        classify_notification(frame, rx_seq, state)

      true ->
        respond_malformed(frame, state)
    end
  end

  defp handle_message(_frame, _rx_seq, state), do: {:noreply, state}

  # A top-level JSON array is the same "batch" shape the `is_list(frame)`
  # clause of `handle_message/3` answers -32600 for; every other decode
  # failure (torn JSON, an oversized frame, a non-object/non-array scalar)
  # is a genuine -32700 parse error (§9, S5).
  @spec handle_decode_error(term(), %__MODULE__{}) ::
          {:noreply, %__MODULE__{}} | {:stop, :normal, %__MODULE__{}}
  defp handle_decode_error({:not_an_object, list}, state) when is_list(list) do
    emit_telemetry([:raxol, :acp, :invalid_request_frame], %{reason: :batch_array})
    emit_and_continue(response_frame(nil, {:error, Error.invalid_request()}), state)
  end

  defp handle_decode_error(reason, state) do
    emit_telemetry([:raxol, :acp, :parse_error], %{reason: inspect(reason)})
    emit_and_continue(response_frame(nil, {:error, Error.parse_error()}), state)
  end

  defp classify_request(frame, rx_seq, state) do
    case Request.from_json(frame) do
      {:ok, %Request{} = req} -> handle_inbound_request(req, rx_seq, state)
      {:error, _} -> respond_malformed(frame, state)
    end
  end

  # A frame classified as a response (has "id" + "result"/"error") that
  # fails to decode is DROPPED, never answered (S1): JSON-RPC 2.0 forbids
  # answering a response, and this Connection's own `next_out_id` space can
  # overlap the peer's -- echoing a synthesized -32600 error back at the
  # response's id would land in the PEER's own `pending_out` table and get
  # cross-correlated to an unrelated in-flight request of theirs. Any real
  # in-flight request we made under this id resolves by its own timeout
  # instead, per the design's row 15/16/19 precedent.
  defp classify_response(frame, state) do
    case Response.from_json(frame) do
      {:ok, resp} -> handle_inbound_response(resp, state)
      {:error, _reason} -> drop_malformed_response(frame, state)
    end
  end

  defp drop_malformed_response(frame, state) do
    id = Map.get(frame, "id")

    Logger.warning(
      "ACP: malformed response frame dropped (id #{inspect(id)}) -- never answered, " <>
        "per JSON-RPC 2.0 (a response is never itself answered)"
    )

    emit_telemetry([:raxol, :acp, :malformed_response], %{id: inspect(id)})
    {:noreply, state}
  end

  defp classify_notification(frame, rx_seq, state) do
    case Notification.from_json(frame) do
      {:ok, %Notification{} = notif} -> handle_inbound_notification(notif, rx_seq, state)
      {:error, _} -> respond_malformed(frame, state)
    end
  end

  # A malformed frame is answered -32600 with its id if wire-valid, else null;
  # the connection NEVER tears down on a malformed frame (§4, Inv-15).
  defp respond_malformed(frame, state) do
    id =
      case frame do
        %{"id" => raw} -> if RequestId.valid?(raw), do: RequestId.from_json(raw), else: nil
        _ -> nil
      end

    emit_and_continue(response_frame(id, {:error, Error.invalid_request()}), state)
  end

  # ===========================================================================
  # Inbound request (§4.1) — ordered checks, first hit wins.
  # ===========================================================================

  defp handle_inbound_request(%Request{} = req, rx_seq, state) do
    method = req.method
    id = req.id

    cond do
      # (1) handshake gate
      state.phase == :uninitialized and method != "initialize" ->
        error =
          data_error(-32_600, "Invalid request", %{
            "method" => method,
            "reason" => "initialize required"
          })

        emit_and_continue(response_frame(id, {:error, error}), state)

      state.phase == :initialized and method == "initialize" ->
        error = data_error(-32_600, "Invalid request", %{"reason" => "already initialized"})
        emit_and_continue(response_frame(id, {:error, error}), state)

      # (2) null-id request
      id == nil ->
        Logger.warning("ACP: inbound request with null id (method #{method}) rejected -32600")
        emit_and_continue(response_frame(nil, {:error, Error.invalid_request()}), state)

      # (3) duplicate in-flight id — DROP, no response (§4.1(3), Inv-14)
      Map.has_key?(state.pending_in, id) ->
        emit_telemetry([:raxol, :acp, :duplicate_inflight_id], %{id: RequestId.display(id)})
        Logger.warning("ACP: duplicate in-flight request id #{RequestId.display(id)} dropped")
        {:noreply, state}

      # (4) inbound-concurrency cap — SHED, do not dispatch (flood-DoS guard).
      # A distinct in-flight id that would push `pending_in` past `max_in` is
      # answered -32603 (server busy) and dispatched to NO task: the maps and the
      # dispatch task set never grow beyond the cap, and the Connection never
      # blocks the link. The overflow id is NOT recorded (nothing to reclaim), so
      # a later retry of the same id after the flood drains is a fresh request.
      map_size(state.pending_in) >= state.max_in ->
        emit_telemetry([:raxol, :acp, :inbound_shed], %{id: RequestId.display(id), method: method})

        Logger.warning(
          "ACP: inbound request #{method} (id #{RequestId.display(id)}) shed -32603 — " <>
            "#{state.max_in} concurrent inbound already in flight (flood guard)"
        )

        error =
          data_error(-32_603, "Server busy", %{
            "reason" => "too many concurrent inbound requests",
            "limit" => state.max_in
          })

        emit_and_continue(response_frame(id, {:error, error}), state)

      # (5) capability gate BEFORE decode — -32601 beats -32602 (§4.1)
      capability_denied?(method, state) ->
        error = data_error(-32_601, "Method not found", method)
        emit_and_continue(response_frame(id, {:error, error}), state)

      true ->
        dispatch_inbound_request(req, rx_seq, state)
    end
  end

  defp dispatch_inbound_request(%Request{id: id, method: method, params: params}, rx_seq, state) do
    case Router.decode(state.role, :request, method, params) do
      {:error, :method_not_found} ->
        error = data_error(-32_601, "Method not found", method)
        emit_and_continue(response_frame(id, {:error, error}), state)

      {:error, reason} ->
        error = data_error(-32_602, "Invalid params", inspect(reason))
        emit_and_continue(response_frame(id, {:error, error}), state)

      {:ok, dispatchable} ->
        spawn_request_task(id, method, dispatchable, rx_seq, state)
    end
  end

  defp spawn_request_task(id, method, dispatchable, rx_seq, state) do
    reply_ref = make_ref()

    ctx = %Ctx{
      conn: self(),
      role: state.role,
      caps: state.caps,
      handler_state: state.handler_state,
      reply_ref: reply_ref,
      rx_seq: rx_seq,
      session_sup: state.session_sup,
      task_sup: state.task_sup
    }

    # The `max_in` cap (§4.1(4)) sheds before we ever reach the task_sup's own
    # `max_children` backstop, so this rejection path is defence-in-depth: if the
    # shared Task.Supervisor is nonetheless saturated (e.g. a co-tenant notif
    # flood), we SHED -32603 rather than let `async_nolink` raise and take the
    # Connection down.
    case start_dispatch_task(state, fn ->
           run_dispatch(state.role, state.handler, dispatchable, ctx)
         end) do
      {:error, reason} ->
        emit_telemetry([:raxol, :acp, :inbound_shed], %{id: RequestId.display(id), method: method})

        Logger.warning(
          "ACP: inbound request #{method} (id #{RequestId.display(id)}) shed -32603 — " <>
            "dispatch task_sup saturated (#{inspect(reason)})"
        )

        error =
          data_error(-32_603, "Server busy", %{"reason" => "dispatch capacity exhausted"})

        emit_and_continue(response_frame(id, {:error, error}), state)

      {:ok, task} ->
        entry = %{
          task_ref: task.ref,
          task_pid: task.pid,
          method: method,
          cancelled?: false,
          reply_ref: reply_ref,
          adopter: nil
        }

        state = %{
          state
          | pending_in: Map.put(state.pending_in, id, entry),
            reply_refs: Map.put(state.reply_refs, reply_ref, id),
            task_index: Map.put(state.task_index, task.ref, {:request, id})
        }

        {:noreply, state}
    end
  end

  # Spawn a dispatch task on the shared per-connection Task.Supervisor without
  # ever crashing the Connection: `async_nolink` RAISES when the supervisor's
  # `max_children` is reached, so it is caught and reported as `{:error, reason}`
  # for the caller to shed/drop. On success returns `{:ok, %Task{}}`.
  @spec start_dispatch_task(%__MODULE__{}, (-> term())) :: {:ok, Task.t()} | {:error, term()}
  defp start_dispatch_task(state, fun) do
    {:ok, Task.Supervisor.async_nolink(state.task_sup, fun)}
  rescue
    e -> {:error, e}
  end

  # ===========================================================================
  # Inbound request task result (§4.2)
  # ===========================================================================

  defp handle_request_result(id, result, state) do
    case Map.get(state.pending_in, id) do
      nil ->
        # Already removed by transport-down / $/cancel_request full-clear.
        {:noreply, state}

      %{cancelled?: true} = entry ->
        # (4) cancelled: drop the result, NO frame ever for this id.
        {:noreply, drop_pending_in(state, id, entry)}

      entry ->
        finish_request_result(id, entry, result, state)
    end
  end

  defp finish_request_result(id, entry, :deferred, state) do
    # (3) :deferred is legal iff the entry was delegated (IC-4).
    if entry.adopter != nil do
      nulled = %{entry | task_ref: nil, task_pid: nil}
      {:noreply, %{state | pending_in: Map.put(state.pending_in, id, nulled)}}
    else
      Logger.error(
        "ACP: handler returned :deferred without delegate_reply (id #{RequestId.display(id)})"
      )

      state = drop_pending_in(state, id, entry)
      emit_and_continue(response_frame(id, {:error, Error.internal_error()}), state)
    end
  end

  defp finish_request_result(id, entry, result, state) do
    state = drop_pending_in(state, id, entry)

    case result_to_response(result) do
      {:ok, response} ->
        case push_frame(state, response_frame(id, response)) do
          {:ok, st} -> {:noreply, maybe_agent_initialized(id, entry, response, st)}
          {:down, reason} -> {:stop, :normal, transport_down(reason, state)}
        end

      :malformed ->
        Logger.error(
          "ACP: handler #{inspect(state.handler)} returned malformed value for #{entry.method}: #{inspect(result)}"
        )

        emit_and_continue(response_frame(id, {:error, Error.internal_error()}), state)
    end
  end

  defp result_to_response({:ok, %_{} = struct}), do: {:ok, {:ok, struct}}
  defp result_to_response({:error, %Error{} = e}), do: {:ok, {:error, e}}
  defp result_to_response(_other), do: :malformed

  # ===========================================================================
  # Inbound request task crash / adopter death (§4.3 / §4.7)
  # ===========================================================================

  defp handle_task_down(ref, reason, state) do
    {tag, task_index} = Map.pop(state.task_index, ref)
    state = %{state | task_index: task_index}

    case tag do
      {:notification, method} ->
        Logger.error("ACP: notification handler crashed (#{method}): #{inspect(reason)}")
        emit_telemetry([:raxol, :acp, :handler_crash], %{kind: :notification, method: method})
        {:noreply, state}

      {:request, id} ->
        request_task_crash(id, reason, state)
    end
  end

  defp request_task_crash(id, reason, state) do
    case Map.pop(state.pending_in, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending_in} ->
        state = %{
          state
          | pending_in: pending_in,
            reply_refs: Map.delete(state.reply_refs, entry.reply_ref)
        }

        if entry.cancelled? or reason == :normal do
          {:noreply, state}
        else
          Logger.error(
            "ACP: request handler crashed (#{entry.method}, id #{RequestId.display(id)}): #{inspect(reason)}"
          )

          emit_telemetry([:raxol, :acp, :handler_crash], %{kind: :request, method: entry.method})

          emit_and_continue(response_frame(id, {:error, Error.internal_error()}), state)
        end
    end
  end

  defp handle_adopter_down(id, entry, state) do
    state = drop_pending_in(state, id, entry)

    if entry.cancelled? do
      {:noreply, state}
    else
      Logger.error("ACP: reply adopter died for id #{RequestId.display(id)} — emitting -32603")
      emit_and_continue(response_frame(id, {:error, Error.internal_error()}), state)
    end
  end

  # ===========================================================================
  # Inbound notification (§4.4) + intercepts (§6)
  # ===========================================================================

  # $/cancel_request is protocol-layer and allowed pre-handshake (IC-5a, §7.2).
  defp handle_inbound_notification(
         %Notification{method: "$/cancel_request", params: params},
         _rx_seq,
         state
       ) do
    case CancelRequestNotification.from_json(params || %{}) do
      {:ok, %{request_id: cancel_id}} -> {:noreply, cancel_inbound(cancel_id, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  defp handle_inbound_notification(%Notification{} = notif, rx_seq, state) do
    cond do
      state.phase != :initialized ->
        Logger.debug("ACP: notification #{notif.method} dropped pre-handshake")
        {:noreply, state}

      notif.method == "session/cancel" ->
        route_session_cancel(notif.params, rx_seq, state)

      true ->
        dispatch_inbound_notification(notif, state)
    end
  end

  defp dispatch_inbound_notification(%Notification{method: method, params: params}, state) do
    case Router.decode(state.role, :notification, method, params) do
      {:error, _reason} ->
        Logger.debug("ACP: unknown/invalid notification #{method} dropped")
        emit_telemetry([:raxol, :acp, :unknown_notification], %{method: method})
        {:noreply, state}

      {:ok, dispatchable} ->
        ctx = %Ctx{
          conn: self(),
          role: state.role,
          caps: state.caps,
          handler_state: state.handler_state,
          reply_ref: nil,
          rx_seq: 0,
          session_sup: state.session_sup,
          task_sup: state.task_sup
        }

        # A notification carries no reply obligation, so an over-capacity spawn is
        # DROPPED (log + telemetry), never a wire frame — and never a raise that
        # would take the Connection down (§4.4, flood-DoS guard symmetry).
        case start_dispatch_task(state, fn ->
               run_dispatch(state.role, state.handler, dispatchable, ctx)
             end) do
          {:error, reason} ->
            Logger.warning(
              "ACP: notification #{method} dropped — dispatch task_sup saturated (#{inspect(reason)})"
            )

            emit_telemetry([:raxol, :acp, :notification_shed], %{method: method})
            {:noreply, state}

          {:ok, task} ->
            {:noreply,
             %{state | task_index: Map.put(state.task_index, task.ref, {:notification, method})}}
        end
    end
  end

  # session/cancel — Connection-routed session control, NO app dispatch (IC-5b/c).
  defp route_session_cancel(params, rx_seq, state) do
    case CancelNotification.from_json(params || %{}) do
      {:ok, %{session_id: session_id}} ->
        case lookup_session(session_id) do
          [{spid, _} | _] -> GenServer.cast(spid, {:acp_session_cancel, rx_seq})
          [] -> Logger.debug("ACP: session/cancel for unknown session #{inspect(session_id)}")
        end

        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # $/cancel_request mechanics (§6.1, IC-5a). Mark cancelled? FIRST, then act.
  defp cancel_inbound(cancel_id, state) do
    case Map.get(state.pending_in, cancel_id) do
      nil ->
        Logger.debug(
          "ACP: $/cancel_request for unknown/finished id #{RequestId.display(cancel_id)}"
        )

        state

      %{adopter: nil, task_pid: pid} = entry ->
        pending_in = Map.put(state.pending_in, cancel_id, %{entry | cancelled?: true})
        if pid, do: Task.Supervisor.terminate_child(state.task_sup, pid)
        %{state | pending_in: pending_in}

      %{adopter: {apid, _mon}, reply_ref: rref} = entry ->
        pending_in = Map.put(state.pending_in, cancel_id, %{entry | cancelled?: true})
        send(apid, {:acp_reply_cancelled, rref})
        %{state | pending_in: pending_in}
    end
  end

  # ===========================================================================
  # Correlated response arrival (§2.4)
  # ===========================================================================

  defp handle_inbound_response(resp, state) do
    id = elem(resp, 1)

    case Map.pop(state.pending_out, id) do
      {nil, _} ->
        Logger.warning("ACP: late/unknown response id #{RequestId.display(id)} dropped")
        emit_telemetry([:raxol, :acp, :late_response], %{id: RequestId.display(id)})
        {:noreply, state}

      {%{reply_to: rt, method: method, timer_ref: timer}, pending_out} ->
        if timer, do: Process.cancel_timer(timer)
        outcome = decode_response(resp, method)
        deliver_outcome(rt, outcome)

        state = %{state | pending_out: pending_out, out_tags: drop_tag(state.out_tags, rt)}
        {:noreply, maybe_client_initialized(method, outcome, state)}
    end
  end

  defp decode_response({:result, _id, raw}, method) do
    case Router.result_marker(method) do
      {:decode, mod} ->
        case mod.from_json(raw) do
          {:ok, struct} -> {:ok, struct}
          {:error, reason} -> {:error, {:result_decode, reason}}
        end

      _ext_or_unknown ->
        {:ok, {:ext, raw}}
    end
  end

  defp decode_response({:error, _id, %Error{} = err}, _method), do: {:error, err}

  # ===========================================================================
  # Handshake phase transitions (§7.2). The `caps` snapshot is the RECEIVER's
  # OWN capability tree (deviation #3, W17-caps): the agent snapshots the
  # `agent_capabilities` of the response it just sent; the client snapshots the
  # `client_capabilities` it stashed (`own_caps`) when it sent the request —
  # the client's own caps are absent from the response it receives. Written
  # exactly once here and immutable after (Inv-11).
  # ===========================================================================

  defp maybe_agent_initialized(
         _id,
         %{method: "initialize"},
         {:ok, struct},
         %{role: :agent, phase: :uninitialized} = state
       ) do
    %{state | phase: :initialized, caps: own_agent_caps(struct)}
  end

  defp maybe_agent_initialized(_id, _entry, _response, state), do: state

  defp maybe_client_initialized(
         "initialize",
         {:ok, %_{}},
         %{role: :client, phase: :uninitialized} = state
       ) do
    %{state | phase: :initialized, caps: state.own_caps}
  end

  defp maybe_client_initialized(_method, _outcome, state), do: state

  # The client's own advertised caps live in the outbound `initialize` request
  # params; stash them at submit time so the handshake commit (which only sees
  # the RESPONSE) can promote them to the `caps` snapshot.
  defp maybe_stash_own_caps(%{role: :client} = state, "initialize", params) do
    %{state | own_caps: own_client_caps(params)}
  end

  defp maybe_stash_own_caps(state, _method, _params), do: state

  defp own_agent_caps(%{agent_capabilities: caps}), do: caps
  defp own_agent_caps(_other), do: nil

  defp own_client_caps(%{client_capabilities: caps}), do: caps
  defp own_client_caps(_other), do: nil

  # ===========================================================================
  # reject_all_outgoing + inbound teardown (§3). One idempotent funnel.
  # ===========================================================================

  defp transport_down(_reason, %{phase: :closed} = state), do: state

  defp transport_down(_reason, state) do
    Enum.each(state.pending_out, fn {_id, %{reply_to: rt, timer_ref: timer}} ->
      if timer, do: Process.cancel_timer(timer)
      deliver_outcome(rt, {:error, :connection_closed})
    end)

    Enum.each(state.pending_in, fn {_id, entry} ->
      case entry.adopter do
        {_apid, mon} ->
          Process.demonitor(mon, [:flush])

        nil ->
          if entry.task_pid, do: Task.Supervisor.terminate_child(state.task_sup, entry.task_pid)
      end
    end)

    if state.transport_monitor, do: Process.demonitor(state.transport_monitor, [:flush])

    %{
      state
      | pending_out: %{},
        out_tags: %{},
        pending_in: %{},
        task_index: %{},
        reply_refs: %{},
        phase: :closed
    }
  end

  @impl GenServer
  def terminate(reason, state) do
    state = transport_down(reason, state)
    if state.transport_mod, do: state.transport_mod.close(state.transport_state)
    :ok
  end

  # ===========================================================================
  # Small shared helpers
  # ===========================================================================

  # Deliver an outcome to a parked sync caller or an async owner (§2.2).
  defp deliver_outcome({:call, from}, outcome), do: GenServer.reply(from, outcome)

  defp deliver_outcome({:owner, pid, tag}, outcome) do
    send(pid, {:acp_result, tag, outcome})
    :ok
  end

  defp demonitor_adopter(%{adopter: {_pid, mon}}), do: Process.demonitor(mon, [:flush])
  defp demonitor_adopter(_entry), do: :ok

  defp drop_pending_in(state, id, entry) do
    demonitor_adopter(entry)

    %{
      state
      | pending_in: Map.delete(state.pending_in, id),
        reply_refs: Map.delete(state.reply_refs, entry.reply_ref)
    }
  end

  defp find_adopter(pending_in, mon_ref) do
    Enum.find_value(pending_in, fn
      {id, %{adopter: {_pid, ^mon_ref}} = entry} -> {id, entry}
      _ -> nil
    end)
  end

  # Best-effort $/cancel_request for a wire id (§6.3). Send failure is swallowed.
  defp best_effort_cancel_notify(id, state) do
    frame = wire(Notification.new("$/cancel_request", %{"requestId" => RequestId.to_json(id)}))

    case state.transport_mod.send_message(state.transport_state, frame) do
      {:ok, _ts} ->
        :ok

      {:error, reason} ->
        Logger.debug("ACP: best-effort $/cancel_request failed: #{inspect(reason)}")
    end
  end

  # Build a JSON-RPC error/result response frame (wire map, id echoed exact-type).
  # A handler-returned result that fails to encode (O6) falls back to
  # `-32603` rather than raising inside the Connection -- the same "never
  # trust a handler's return value" posture `result_to_response/1`'s
  # `:malformed` clause already takes for a non-struct/non-Error return.
  defp response_frame(id, {:ok, %_{} = struct}) do
    case to_wire(struct) do
      {:ok, wire_result} -> wire(Response.result(id, wire_result))
      {:error, _reason} -> wire(Response.error(id, Error.internal_error()))
    end
  end

  defp response_frame(id, {:error, %Error{} = err}), do: wire(Response.error(id, err))

  defp data_error(code, message, data), do: Error.with_data(Error.new(code, message), data)

  defp wire(message), do: message |> Message.wrap() |> Message.to_json()

  # Flatten a struct/map to a plain string-keyed wire map so in-process
  # transports (Paired, zero-copy) hand the peer a decodable map, not a struct.
  # Total: never raises (O6) -- a non-JSON-safe `params` value (a stray pid,
  # ref, or tuple; app misuse, not a protocol violation) is reported as
  # `{:error, {:encode, reason}}` instead of raising `Jason.encode!/1` INSIDE
  # a `handle_call`, which would otherwise kill this GenServer on caller
  # misuse. `Jason.decode!/1` immediately after a successful `Jason.encode/1`
  # cannot fail (its input is always well-formed JSON we just produced).
  @spec to_wire(term()) :: {:ok, term()} | {:error, {:encode, term()}}
  defp to_wire(nil), do: {:ok, nil}

  defp to_wire(params) do
    case Jason.encode(params) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  defp push_frame(state, frame) do
    case state.transport_mod.send_message(state.transport_state, frame) do
      {:ok, ts} -> {:ok, %{state | transport_state: ts}}
      {:error, reason} -> {:down, reason}
    end
  end

  defp emit_and_continue(frame, state) do
    case push_frame(state, frame) do
      {:ok, st} -> {:noreply, st}
      {:down, reason} -> {:stop, :normal, transport_down(reason, state)}
    end
  end

  # Ext requests/notifications route to the handler's ext callbacks (Router
  # dispatch is only for table-tagged tuples); everything else is table-driven.
  defp run_dispatch(_side, handler, {:ext_request, wire, params}, ctx) do
    handler.handle_ext_request(wire, params, ctx)
  end

  defp run_dispatch(_side, handler, {:ext_notification, wire, params}, ctx) do
    handler.handle_ext_notification(wire, params, ctx)
  end

  defp run_dispatch(side, handler, dispatchable, ctx) do
    Router.dispatch(side, handler, dispatchable, ctx)
  end

  # Capability gate (§4.1 step 5): located BEFORE decode so `-32601` beats
  # `-32602`. Delegates to the real, fail-closed predicate over the receiver's
  # own negotiated caps snapshot (W17-caps — deviation #3 seam CLOSED).
  defp capability_denied?(method, state) do
    not Capabilities.negotiated?(state.caps, method)
  end

  defp lookup_session(session_id) do
    case Process.whereis(@session_registry) do
      nil -> []
      _pid -> Registry.lookup(@session_registry, {self(), session_id})
    end
  end

  defp emit_telemetry(event, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, %{count: 1}, metadata])
    end

    :ok
  end
end
