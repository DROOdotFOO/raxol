defmodule Raxol.Agent.AcpStreamAdapter do
  @moduledoc """
  ACP -> harness-contract event adapter: consumes decoded
  `session/update` frames from `Raxol.AgentClientProtocol.Client.subscribe/3`
  (delivered as `{:acp_session_update, session_id, update}` messages) and
  re-emits them as `Raxol.Agent.Contract.Event`s through
  `Raxol.Agent.SessionStreamer` — the same channel `Raxol.Agent.Contract.pump/3`
  and `Raxol.Agent.EmitBridge` publish on. Producers differ; the contract
  does not: any surface already subscribed to the streamer (the live-session
  driver, the CLI, SSE) renders an ACP-backed session with zero changes.

  This is a PRODUCER in the `Contract.pump/3` sense, not an id authority:
  ids are a per-adapter monotonic sequence exactly like `pump/3`'s counter
  (the EmitBridge journal-offset discipline applies only where a journal
  sink owns the ids — none does here).

  ## Mapping table (ACP frame -> contract event)

  | ACP                                             | contract `type`   | tier         |
  | ----------------------------------------------- | ----------------- | ------------ |
  | `begin_turn/2` (session/prompt accepted)         | `:turn_started`, then one `:item_completed` user echo (`item_type: :message, role: :user, content: prompt`) when the prompt is non-empty | `:durable`   |
  | `agent_message_chunk`                            | `:item_delta` (accumulated; sealed as ONE durable `:message` item at `finish_turn/2`, pump's `{:done, %{content}}` precedent — ACP's terminal response carries no content, only the chunks did) | `:ephemeral` |
  | `agent_thought_chunk` (`thought: true` payload)  | a durable `:reasoning` item lifecycle — `:item_started` (lazily, on the first non-blank thought) + ephemeral `:item_delta`s carrying the item_id, sealed as one durable `:item_completed` (`item_type: :reasoning, content`) at the reasoning→answer transition (first `agent_message_chunk`), a tool/plan boundary, or `finish_turn`. Whitespace-only thinking opens/seals nothing. | `:durable` + `:ephemeral` |
  | `tool_call` / `tool_call_update`, terminal status| `:item_completed` pair (`:tool_use` + `:tool_result`) | `:durable` |
  | `plan`                                           | `:item_completed` (`item_type: :plan`) | `:durable` |
  | `usage_update`                                   | no event of its own: the mapped usage rides the turn's closing `:turn_completed` payload (`usage:`) -- see the usage section | (folded) |
  | `finish_turn/2` `stop_reason` ∈ end_turn / max_tokens / max_turn_requests | `:turn_completed` `final: true` | `:durable` |
  | `finish_turn/2` `stop_reason: :refusal`          | `:turn_completed` `final: true, stop_reason: :refusal` (disclosed, never painted as a normal end) | `:durable` |
  | `finish_turn/2` `stop_reason: :cancelled`        | `:turn_canceled` (the canceled bracket, NOT a completed one) | `:durable` |
  | `finish_turn/2` `{:error, reason}`               | `:error`          | `:durable`   |

  A NON-terminal `tool_call` / `tool_call_update` frame is stashed (the
  invocation's name/arguments are only reliably present on the opening
  frame), never emitted: the mapping table emits tool items only at their
  terminal status, mirroring `pump/3`'s completed-items-only journal.

  ## The user echo (speaker separation's producer half)

  The transcript renders user turns as the composer sigil echoed into
  history (`❯ text` — see `Raxol.Harness.Surface`'s user-echo seal seam),
  but the echo only materializes from a `:message` item whose payload
  carries an EXACT user role marker (`Raxol.UI.Components.Harness.Block`
  normalizes exactly `"user"`/`:user`; everything else falls safe to
  `:assistant`). `Contract.pump/3` emits only `turn_started{prompt}`, so
  this adapter is the producer that lights the echo: `begin_turn/2`
  emits the durable user message item (`item_type: :message, role:
  :user, content: prompt`) immediately after `turn_started`, BEFORE any
  agent chunk can flow — one item, sealed as the user block ahead of the
  first assistant block. An empty prompt emits no echo (an empty `❯`
  line would be an unbound pixel, an echo of nothing). `user_message_chunk`
  stays unmapped for the same reason: the prompt echo already sealed at
  `begin_turn/2`, so mapping the client's own text replayed back through
  the stream would double-echo the user.

  ## Stop-reason honesty

  `finish_turn/2` never launders a stop reason:

    * `:cancelled` closes the turn with the **canceled bracket**
      (`:turn_canceled`, payload `%{reason: :cancelled}`) — the same
      terminal type `Raxol.Agent.Interrupt` emits, so the driver renders
      "turn canceled", never a successful completion.
    * `:refusal` completes the turn but the payload discloses
      `stop_reason: :refusal` and `refused: true`.
    * A stop reason OUTSIDE the ACP enum (a forged/unknown atom or any
      other term) is disclosed as `stop_reason: :unknown` with the raw
      value carried as `raw_stop_reason` text — it is never coerced into
      `:end_turn`, and no evidence refs are attached to it.

  ## Evidence refs ride `_meta`

  Every ACP struct passes unknown wire fields through its `_meta` bucket
  (`Raxol.AgentClientProtocol.Schema.WireFields.fold_meta/2`). A
  `PromptResponse` whose `_meta` carries `"refs"` as a list of
  non-negative integers gets them attached to the `:turn_completed`
  payload as `refs`. The decode is tolerant and FAIL-SAFE: an absent key,
  a non-list, or a list containing any non-integer/negative element all
  decode as **no refs** — a malformed evidence claim is never partially
  honored (`decode_refs/1`).

  ## Usage and cost (`usage_update` -> the `:turn_completed` `usage:` map)

  `usage_update` carries no event of its own: a context/cost update is
  not a transcript fact, it is a property OF the turn, so the latest
  frame's figures are held in adapter state and emitted on the turn's
  closing `:turn_completed` payload (an empty map when the peer reported
  nothing). The map speaks raxol's usage vocabulary
  (`Raxol.Agent.BenchmarkProfile.add_usage/2`, `Raxol.Agent.LlmPrices`):

    * `:input_tokens`, `:output_tokens`, `:total_tokens`,
      `:cached_read_tokens` -- from `_meta`. `Schema.UsageUpdate`'s known
      wire keys are exactly `used`/`size`/`cost`, so a peer's token split
      (`inputTokens`, `outputTokens`, `totalTokens`, `cachedReadTokens`)
      folds into `_meta` untouched and is read from there. Only
      non-negative integers are taken; a garbage count reads as absent
      (the tolerant-reading rule -- an absent figure is safer at a spend
      gate than a fabricated one).
    * `:context_tokens` / `:max_context_tokens` -- `used` and `size`.
      `used` is tokens CURRENTLY IN CONTEXT, not cumulative billed input,
      so it is context metadata and NEVER `:input_tokens`: billing it as
      input would charge the whole prompt context on every turn.
    * `:cost` -- this TURN's cost, `%{amount, currency}`.
    * `:session_cost` -- the counterparty's cumulative session figure,
      carried verbatim for display. Pricing must not read it.

  `UsageUpdate.cost` is the CUMULATIVE session cost, so `:cost` is
  computed as a delta against the cumulative anchored at the turn's
  start; see `put_cost/2` for the double-count reasoning, the
  currency-comparison rule, and why a negative delta reports no cost
  rather than a credit. Usage is turn-scoped (a turn the peer sent no
  `usage_update` for reports `%{}`, never the previous turn's figures);
  the cumulative-cost anchor is session-scoped and advances at every turn
  boundary. Recorded by ADR-0034 (the `usage: %{}` hole) and ADR-0035
  (prefer a provider's own reported cost).

  ## Unknown-variant honesty (skip, count, disclose once)

  Any update this adapter has no mapping for — the known-but-unmapped
  variants, DECLARED as `@counted_unmapped` (`user_message_chunk`,
  `available_commands_update`, `current_mode_update`,
  `config_option_update`, `session_info_update`) rather than left to fall
  through the catch-all, a `{:raw, map}` from a manual `decode_update/1`
  feed, a future variant, or outright garbage -- is SKIPPED, never crashed
  on (the tolerant-reading rule). But the skip is never silent: each kind
  is counted (`unmapped_counts/1`), and the FIRST occurrence of each kind
  emits one durable `:error` contract event with payload
  `%{reason: :unmapped_acp_update, kind: kind}` so the transcript shows an
  honest fidelity gap instead of a gapless lie. Subsequent occurrences of
  the same kind only bump the counter (bounded log emission — one marker
  per kind per adapter lifetime).

  The declaration is what separates "we know this frame and chose not to
  map it" from "we have never heard of this frame": the two degrade
  identically for a reader of the transcript, and a coder adding the
  mapping needs to know which list a kind is on.

  ## Wiring

  The adapter is passive: the embedder owns the ACP connection and the
  prompt request (`Client.prompt_stream/4` blocks its caller; a GenServer
  must not). The embedder calls `begin_turn/2` when it dispatches
  `session/prompt`, lets the subscribed updates stream through, and calls
  `finish_turn/2` with the resolved `PromptResponse` (or error).
  Subscription can be done by the embedder (passing this adapter's pid to
  `Client.subscribe/3`) or delegated via the `:subscribe` start option.

  `raxol_agent` does not depend on `raxol_agent_client_protocol`: the one
  cross-package call (`Client.subscribe/3`, only when the `:subscribe`
  option is used) is `Code.ensure_loaded?/1`-guarded and every decoded ACP
  struct is consumed through map patterns, per the repo's cross-package
  convention.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer

  @acp_client Raxol.AgentClientProtocol.Client
  @compile {:no_warn_undefined, Raxol.AgentClientProtocol.Client}

  @known_stop_reasons [:end_turn, :max_tokens, :max_turn_requests]

  # Known ACP update kinds this adapter deliberately does not map. See the
  # moduledoc's unknown-variant section for why they are declared here
  # instead of reaching the catch-all.
  @counted_unmapped [
    :user_message_chunk,
    :available_commands_update,
    :current_mode_update,
    :config_option_update,
    :session_info_update
  ]

  # The kinds this adapter DOES map, one per `apply_update/2` clause below.
  # Together with @counted_unmapped this is the set of ACP update kinds this
  # module has an opinion about; anything else reaches the catch-all and is
  # reported as unknown.
  #
  # Declared so a test can hold it against the protocol schema's own variant
  # list: `usage_update` sat in the schema, fully ported, while this adapter
  # dropped it into the unknown bucket and hard-coded `usage: %{}` on every
  # turn -- for months, silently, because nothing compared the two lists.
  # See acp_stream_adapter_coverage_test.exs.
  @mapped [
    :agent_message_chunk,
    :agent_thought_chunk,
    :tool_call,
    :tool_call_update,
    :plan,
    :usage_update
  ]

  @doc """
  Every ACP `session/update` kind this adapter handles deliberately, whether
  by mapping it to `Contract.Event`s or by counting it as known-but-unmapped.

  A kind absent from this list reaches the catch-all, so it is reported as an
  unknown variant rather than rendered.
  """
  @spec known_kinds() :: [atom()]
  def known_kinds, do: @mapped ++ @counted_unmapped

  # A peer's token split rides `_meta` (UsageUpdate's known wire keys are
  # only used/size/cost) -> raxol's usage vocabulary.
  @meta_token_keys %{
    "inputTokens" => :input_tokens,
    "outputTokens" => :output_tokens,
    "totalTokens" => :total_tokens,
    "cachedReadTokens" => :cached_read_tokens
  }

  defstruct [
    :session_id,
    :streamer,
    :turn_id,
    :reasoning_item,
    # cost_anchor: the cumulative session cost as of the previous turn
    # boundary (session-scoped). cost_reported: the cumulative figure this
    # turn's own usage_update carried, nil when the peer reported none --
    # turn-scoped, so a turn nobody reported on claims nothing rather than
    # claiming zero dollars.
    :cost_anchor,
    :cost_reported,
    seq: 0,
    reasoning_seq: 0,
    pending_tools: %{},
    unmapped: %{},
    message_buf: [],
    reasoning_buf: [],
    usage: %{},
    turn_seen: false
  ]

  @type cost :: %{amount: float(), currency: String.t()}

  @type t :: %__MODULE__{
          session_id: term(),
          streamer: GenServer.server(),
          turn_id: String.t() | nil,
          reasoning_item: String.t() | nil,
          cost_anchor: cost() | nil,
          cost_reported: cost() | nil,
          seq: non_neg_integer(),
          reasoning_seq: non_neg_integer(),
          pending_tools: %{optional(String.t()) => map()},
          unmapped: %{optional(String.t()) => pos_integer()},
          message_buf: [String.t()],
          reasoning_buf: [String.t()],
          usage: map(),
          turn_seen: boolean()
        }

  # -- client API -------------------------------------------------------------

  @doc """
  Start an adapter for one contract `session_id`.

  Options:

    * `:session_id` (required) — the contract/SessionStreamer session key
      surfaces subscribe to.
    * `:streamer` — SessionStreamer server (default
      `Raxol.Agent.SessionStreamer`).
    * `:subscribe` — `{conn, acp_session_id}`: subscribe this adapter to
      that ACP session's `session/update` deliveries via
      `Raxol.AgentClientProtocol.Client.subscribe/3`. Requires the
      `raxol_agent_client_protocol` package; when it is not loaded the
      start fails with `{:error, :acp_client_unavailable}` rather than
      silently starting an adapter that can never receive a frame.
      Omit it to feed the adapter yourself (the embedder passes this pid
      as the subscriber, or tests send the messages directly).
    * `:name` — process name (default anonymous).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Mark a prompt as accepted: emits the durable `:turn_started` bracket,
  then (for a non-empty prompt) the durable user-echo message item — see
  the moduledoc's user-echo section — and returns `{:ok, turn_id}`. Call
  it when `session/prompt` is dispatched, before any updates stream.
  """
  @spec begin_turn(GenServer.server(), String.t()) :: {:ok, String.t()}
  def begin_turn(server, prompt \\ "") when is_binary(prompt) do
    GenServer.call(server, {:begin_turn, prompt})
  end

  @doc """
  Close the current turn from a resolved `session/prompt` outcome. Accepts
  a decoded `PromptResponse` (any map with `:stop_reason`, `_meta`
  optional) or `{:error, reason}`. See the moduledoc's stop-reason honesty
  section for the exact bracket each outcome emits.
  """
  @spec finish_turn(
          GenServer.server(),
          %{stop_reason: term()} | {:error, term()}
        ) :: :ok
  def finish_turn(server, outcome) do
    GenServer.call(server, {:finish_turn, outcome})
  end

  @doc "Per-kind counts of updates skipped as unmapped (observability; see moduledoc)."
  @spec unmapped_counts(GenServer.server()) :: %{
          optional(String.t()) => pos_integer()
        }
  def unmapped_counts(server) do
    GenServer.call(server, :unmapped_counts)
  end

  # -- server -----------------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    streamer = Keyword.get(opts, :streamer, SessionStreamer)

    case maybe_subscribe(Keyword.get(opts, :subscribe)) do
      :ok ->
        {:ok, %__MODULE__{session_id: session_id, streamer: streamer}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp maybe_subscribe(nil), do: :ok

  defp maybe_subscribe({conn, acp_session_id})
       when is_pid(conn) and is_binary(acp_session_id) do
    if Code.ensure_loaded?(@acp_client) do
      @acp_client.subscribe(conn, acp_session_id, self())
    else
      {:error, :acp_client_unavailable}
    end
  end

  defp maybe_subscribe(other), do: {:error, {:invalid_subscribe_option, other}}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:begin_turn, prompt}, _from, state) do
    state = close_abandoned_turn(state)
    turn_id = "turn-#{System.unique_integer([:positive])}"

    # The turn boundary is also the usage boundary: figures are turn-scoped
    # (a turn with no usage_update must report %{}, not the previous turn's
    # numbers), while the cumulative-cost anchor carries forward so the next
    # turn's cost is a delta against everything already billed.
    state = %{
      state
      | turn_id: turn_id,
        turn_seen: true,
        pending_tools: %{},
        message_buf: [],
        reasoning_item: nil,
        reasoning_buf: [],
        reasoning_seq: 0,
        usage: %{},
        cost_anchor: state.cost_reported || state.cost_anchor,
        cost_reported: nil
    }

    state =
      state
      |> emit(:turn_started, :durable, %{prompt: prompt})
      |> emit_user_echo(prompt)

    {:reply, {:ok, turn_id}, state}
  end

  def handle_manager_call({:finish_turn, outcome}, _from, state) do
    # A pure-thinking tail (thoughts streamed, but the turn ended with no
    # answer chunk to trigger the reasoning→answer seal) still seals its
    # reasoning as a durable ∴ block — the thought happened, so it is a
    # transcript fact, on every outcome (completion, refusal, cancel,
    # error). Normally a no-op: the first answer chunk already sealed it.
    state = state |> seal_reasoning() |> close_turn(outcome)

    # The anchor advances on BOTH turn boundaries, so a closed turn's
    # dollars can never be billed again even if the embedder skips
    # begin_turn/2 on the next prompt.
    {:reply, :ok,
     %{
       state
       | turn_id: nil,
         pending_tools: %{},
         message_buf: [],
         reasoning_item: nil,
         reasoning_buf: [],
         reasoning_seq: 0,
         usage: %{},
         cost_anchor: state.cost_reported || state.cost_anchor,
         cost_reported: nil
     }}
  end

  def handle_manager_call(:unmapped_counts, _from, state) do
    {:reply, state.unmapped, state}
  end

  # A `begin_turn` while a turn is already open (the embedder dispatched a
  # second `session/prompt` before calling `finish_turn/2` on the first) used
  # to silently overwrite `turn_id`/the buffers with no closing bracket ever
  # emitted for the abandoned turn — its reasoning/message state simply
  # vanished from the transcript. Closed the same honest way a real
  # cancellation is: the `:turn_canceled` bracket (never a fabricated
  # completion), reason `:superseded` distinguishing it from an ACP-driven
  # `:cancelled`. Mirrors `close_turn(state, %{stop_reason: :cancelled})`:
  # any open reasoning seals first, but the accumulated (never-sealed)
  # assistant text is NOT sealed as a message — an abandoned turn carries no
  # trailing output, same as a canceled one. A no-op when no turn is open.
  defp close_abandoned_turn(%{turn_id: nil} = state), do: state

  defp close_abandoned_turn(state) do
    state
    |> seal_reasoning()
    |> emit(:turn_canceled, :durable, %{reason: :superseded})
  end

  # An ACP `session/update` outside any turn bracket — before the FIRST
  # `begin_turn` ever, or after a `finish_turn` reset `turn_id` to `nil` (a
  # trailing/reordered frame the transport delivered late) — has no turn to
  # attribute itself to: processing it anyway would accumulate into
  # `message_buf`/`reasoning_buf` under no owning turn, emit an ephemeral
  # event attributed to `turn_id: nil`, and then have that accumulation
  # silently wiped by the NEXT `begin_turn` with no trace. Dropped instead,
  # but ONLY once a turn has been seen at least once (`turn_seen`): the
  # acceptance suite's mapping-table tests deliberately drive raw updates
  # standalone, with no `begin_turn` at all, to test the ACP->contract
  # mapping in isolation — that pre-first-turn window stays permissive.
  defp out_of_bracket?(%{turn_id: nil, turn_seen: true}), do: true
  defp out_of_bracket?(_state), do: false

  # The user echo: ONE durable :message item — an item_started/
  # item_completed bracket with a per-turn item_id (the projection's
  # BlockBuilder groups by item_id and flags a completion without its
  # opener as an orphan; the speaker-roles fixture pins exactly this
  # paired shape) — carrying the EXACT user role marker Block normalizes
  # (see the moduledoc). Emitted inside the begin_turn call, so it always
  # precedes the first agent chunk. An empty prompt echoes nothing —
  # never an empty `❯` line.
  defp emit_user_echo(state, ""), do: state

  defp emit_user_echo(state, prompt) do
    emit_message_item(state, "#{state.turn_id}-user", %{
      item_type: :message,
      role: :user,
      content: prompt
    })
  end

  defp emit_message_item(state, item_id, payload) do
    state
    |> emit(:item_started, :durable, %{item_id: item_id, item_type: :message})
    |> emit(:item_completed, :durable, Map.put(payload, :item_id, item_id))
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:acp_session_update, _acp_session_id, update}, state) do
    if out_of_bracket?(state) do
      {:noreply, state}
    else
      {:noreply, apply_update(state, update)}
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- update mapping ----------------------------------------------------------

  # A message chunk streams as an ephemeral delta AND accumulates: the
  # durable assistant :message item is synthesized at finish_turn from
  # exactly this buffer (pump/3's {:done, %{content}} precedent — ACP has
  # no terminal content of its own, only the chunks).
  defp apply_update(state, {:agent_message_chunk, %{content: content}}) do
    text = chunk_text(content)

    # The reasoning→answer transition: the first answer chunk seals the
    # open reasoning item as its own durable ∴ block, ordered ahead of the
    # assistant message it precedes.
    %{state | message_buf: [text | state.message_buf]}
    |> seal_reasoning()
    |> emit(:item_delta, :ephemeral, %{chunk: text})
  end

  # A thought chunk gets the SAME durable item lifecycle a message does
  # (item_started opened lazily on the first non-blank thought, its own
  # turn-scoped item_id, ephemeral deltas streaming into the live tail),
  # so reasoning seals as a durable, peekable ∴ block instead of
  # evaporating from the live tail — the honesty rule: what the machine
  # thought is a first-class transcript fact once sealed. See
  # `stream_reasoning/2`.
  defp apply_update(state, {:agent_thought_chunk, %{content: content}}) do
    stream_reasoning(state, chunk_text(content))
  end

  # A tool_call frame: stash the invocation, and when its status is already
  # terminal, emit the completed pair immediately.
  defp apply_update(state, {:tool_call, %{tool_call_id: id} = tc})
       when is_binary(id) do
    stashed = stash_tool(state, id, tc)

    case Map.get(tc, :status) do
      status when status in [:completed, :failed] ->
        complete_tool(stashed, id, status)

      _pending ->
        stashed
    end
  end

  # A tool_call_update: merge the sparse fields into the stash; emit the pair
  # only when this update carries a terminal status.
  defp apply_update(state, {:tool_call_update, %{tool_call_id: id} = tcu})
       when is_binary(id) do
    fields = Map.get(tcu, :fields) || %{}
    stashed = stash_tool(state, id, fields)

    case Map.get(fields, :status) do
      status when status in [:completed, :failed] ->
        complete_tool(stashed, id, status)

      _pending ->
        stashed
    end
  end

  defp apply_update(state, {:plan, %{entries: entries}})
       when is_list(entries) do
    state
    |> seal_reasoning()
    |> emit(:item_completed, :durable, %{
      item_type: :plan,
      entries: Enum.map(entries, &plan_entry/1)
    })
  end

  # A context/cost update is a property of the turn, not a transcript
  # entry, so it emits nothing: the latest frame's figures are held and
  # ride the closing :turn_completed payload. See the moduledoc's usage
  # section and `put_cost/2` (ADR-0034's `usage: %{}` hole, ADR-0035's
  # provider-reported cost).
  defp apply_update(state, {:usage_update, usage}) when is_map(usage) do
    %{
      state
      | usage: token_usage(usage),
        cost_reported: reported_cost(usage) || state.cost_reported
    }
  end

  # Declared known-but-unmapped variants (@counted_unmapped): counted and
  # disclosed exactly like an unknown kind, but named in the module so the
  # deliberate gap is not indistinguishable from an unheard-of frame.
  defp apply_update(state, {tag, _payload}) when tag in @counted_unmapped do
    record_unmapped(state, Atom.to_string(tag))
  end

  # Everything else -- a {:raw, map} from a manual decode_update/1 feed, a
  # future variant, garbage -- is skipped, counted, and disclosed once per
  # kind. See the moduledoc's unknown-variant section.
  defp apply_update(state, other) do
    record_unmapped(state, unmapped_kind(other))
  end

  # -- tool bookkeeping ---------------------------------------------------------

  # Merge the fields of a tool_call / tool_call_update frame into the pending
  # stash. Only non-nil values overwrite: a sparse update never erases the
  # opening frame's title/raw_input.
  defp stash_tool(state, id, frame) do
    merged =
      state.pending_tools
      |> Map.get(id, %{})
      |> merge_present(frame, [:title, :kind, :raw_input, :raw_output, :content])

    %{state | pending_tools: Map.put(state.pending_tools, id, merged)}
  end

  defp merge_present(acc, frame, keys) do
    Enum.reduce(keys, acc, fn key, acc ->
      case Map.get(frame, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # Emit the terminal pair (:tool_use then :tool_result), mirroring pump/3's
  # two item_completed events so the projection's intra-turn tool merge sees
  # the same shape a Stream-driven session produces. Drop the stash entry.
  defp complete_tool(state, id, status) do
    {info, pending} = Map.pop(state.pending_tools, id, %{})
    # Think→tool with no intervening answer text: the open reasoning seals
    # as its own ∴ block ahead of the tool it reasoned toward.
    state = %{seal_reasoning(state) | pending_tools: pending}
    name = tool_name(info, id)

    state =
      emit(state, :item_completed, :durable, %{
        item_type: :tool_use,
        name: name,
        arguments: Map.get(info, :raw_input) || %{},
        call_id: id
      })

    emit(state, :item_completed, :durable, %{
      item_type: :tool_result,
      name: name,
      result: tool_result(info),
      call_id: id,
      status: status
    })
  end

  defp tool_name(%{title: title}, _id) when is_binary(title) and title != "",
    do: title

  defp tool_name(%{kind: kind}, _id) when is_atom(kind) and not is_nil(kind),
    do: kind

  defp tool_name(_info, id), do: id

  defp tool_result(%{raw_output: raw_output}) when not is_nil(raw_output),
    do: raw_output

  defp tool_result(%{content: content}) when is_list(content),
    do: inspect(content)

  defp tool_result(_info), do: nil

  defp plan_entry(%{content: content, priority: priority, status: status}),
    do: %{content: content, priority: priority, status: status}

  defp plan_entry(other), do: %{content: inspect(other)}

  # A ContentBlock union member -> the item_delta chunk string. Text flows
  # through verbatim; non-text blocks degrade to an honest placeholder
  # rather than being silently dropped or crashed on (a delta chunk must
  # be a string; a hostile/unknown content shape must never kill the
  # adapter mid-stream).
  defp chunk_text({:text, %{text: text}}) when is_binary(text), do: text
  defp chunk_text({:image, _image}), do: "[image]"
  defp chunk_text({:audio, _audio}), do: "[audio]"

  defp chunk_text({:resource_link, %{uri: uri}}) when is_binary(uri),
    do: "[resource: #{uri}]"

  defp chunk_text({:resource, _resource}), do: "[resource]"
  defp chunk_text(other), do: inspect(other)

  # -- turn closing -------------------------------------------------------------

  defp close_turn(state, {:error, reason}) do
    emit(state, :error, :durable, %{reason: reason})
  end

  # The canceled bracket carries no trailing output (`Raxol.Agent.Interrupt`'s
  # own contract: "the turn is simply canceled and :turn_canceled emitted with
  # no trailing output") — the accumulated chunk buffer is NOT sealed as a
  # message here.
  defp close_turn(state, %{stop_reason: :cancelled}) do
    emit(state, :turn_canceled, :durable, %{
      reason: :cancelled,
      stop_reason: :cancelled
    })
  end

  defp close_turn(state, %{stop_reason: :refusal} = response) do
    usage = turn_usage(state)

    state
    |> seal_assistant_message()
    |> emit(
      :turn_completed,
      :durable,
      with_refs(
        %{
          usage: usage,
          iteration: 0,
          final: true,
          stop_reason: :refusal,
          refused: true
        },
        response
      )
    )
  end

  defp close_turn(state, %{stop_reason: reason} = response)
       when reason in @known_stop_reasons do
    usage = turn_usage(state)

    state
    |> seal_assistant_message()
    |> emit(
      :turn_completed,
      :durable,
      with_refs(
        %{usage: usage, iteration: 0, final: true, stop_reason: reason},
        response
      )
    )
  end

  # A stop reason outside the ACP enum (forged wire value, garbage term):
  # disclosed, never coerced to a normal completion, never granted refs.
  # The accumulated assistant text still seals — the words WERE said; only
  # the completion claim is suspect. The usage still rides: the tokens were
  # spent and the money was owed whatever the peer claims about the ending.
  defp close_turn(state, %{stop_reason: other}) do
    usage = turn_usage(state)

    state
    |> seal_assistant_message()
    |> emit(:turn_completed, :durable, %{
      usage: usage,
      iteration: 0,
      final: true,
      stop_reason: :unknown,
      raw_stop_reason: inspect(other)
    })
  end

  defp close_turn(state, other) do
    emit(state, :error, :durable, %{
      reason: :invalid_prompt_outcome,
      detail: inspect(other)
    })
  end

  # pump/3's {:done, %{content}} precedent, adapted: the durable assistant
  # :message item is synthesized from the accumulated agent_message_chunk
  # buffer, emitted BEFORE the turn bracket so the projection folds it into
  # the closing turn. An empty buffer seals nothing.
  defp seal_assistant_message(%{message_buf: []} = state), do: state

  defp seal_assistant_message(state) do
    content = state.message_buf |> Enum.reverse() |> Enum.join()

    emit_message_item(
      %{state | message_buf: []},
      "#{state.turn_id}-assistant",
      %{
        item_type: :message,
        content: content
      }
    )
  end

  # -- usage and cost mapping ---------------------------------------------------

  defp turn_usage(state), do: put_cost(state.usage, state)

  # `Schema.UsageUpdate`'s known wire keys are exactly used/size/cost, so a
  # peer's token split arrives in `_meta` verbatim and is read from there.
  # `used` is tokens CURRENTLY IN CONTEXT, so it is context metadata and
  # never `:input_tokens`: billing a context window as input tokens would
  # charge the whole conversation again on every turn.
  defp token_usage(usage) do
    meta = meta(usage)

    @meta_token_keys
    |> Enum.reduce(%{}, fn {wire, key}, acc ->
      maybe_put_count(acc, key, Map.get(meta, wire))
    end)
    |> maybe_put_count(:context_tokens, Map.get(usage, :used))
    |> maybe_put_count(:max_context_tokens, Map.get(usage, :size))
  end

  defp meta(usage) do
    case Map.get(usage, :_meta) do
      meta when is_map(meta) -> meta
      _absent -> %{}
    end
  end

  # Tolerant reading applies to a token count as much as to a stop reason:
  # a non-integer or negative figure reads as absent, because an absent
  # count is safer at a spend gate than a fabricated one.
  defp maybe_put_count(acc, key, count)
       when is_integer(count) and count >= 0,
       do: Map.put(acc, key, count)

  defp maybe_put_count(acc, _key, _other), do: acc

  defp reported_cost(%{cost: %{amount: amount, currency: currency}})
       when is_number(amount) and is_binary(currency),
       do: %{amount: amount * 1.0, currency: currency}

  defp reported_cost(_usage), do: nil

  # `UsageUpdate.cost` is documented as the CUMULATIVE SESSION cost, so
  # emitting it verbatim as this turn's cost would bill turn 1's dollars
  # again on turn 2, and again on turn 3 -- the same double-count ADR-0034
  # records for Symphony's `merge_tokens/2`. `:cost` is therefore the delta
  # against the cumulative anchored at this turn's start, and the
  # cumulative itself rides as `:session_cost` for display only (pricing
  # reads `:cost`, never `:session_cost`). This is the deliberate
  # refinement of ADR-0035's "prefer a provider's own reported cost": the
  # preference is for the provider's figure, not for its accumulation.
  # A turn the peer sent no usage_update for reported NOTHING about its
  # cost, which is not the same claim as "it cost zero": the anchor has not
  # moved, so there is no evidence either way and no cost key is emitted.
  # Emitting a 0.0 there would let a missing frame price a real turn at
  # $0.00 through ADR-0035's provider-reported-cost path.
  defp put_cost(usage, %{cost_reported: nil}), do: usage

  defp put_cost(usage, %{cost_reported: reported, cost_anchor: anchor}) do
    usage
    |> Map.put(:session_cost, reported)
    |> put_turn_cost(turn_cost(reported, anchor))
  end

  defp put_turn_cost(usage, nil), do: usage
  defp put_turn_cost(usage, cost), do: Map.put(usage, :cost, cost)

  # Currency is never coerced (ADR-0035): a delta is only meaningful
  # between two figures in the SAME currency, so a mid-session currency
  # change reports no turn cost at all rather than subtracting euros from
  # dollars. The currency travels with the amount so a consumer can reject
  # what it cannot price.
  defp turn_cost(%{amount: amount, currency: currency}, nil),
    do: %{amount: amount, currency: currency}

  defp turn_cost(
         %{amount: amount, currency: currency},
         %{amount: anchored, currency: currency}
       ) do
    delta = amount - anchored

    # A cumulative that went DOWN is a broken counterparty figure, not a
    # refund: reporting no cost falls the turn through to the pricing table
    # instead of crediting a spend gate with money nobody returned.
    if delta < 0.0 do
      nil
    else
      %{amount: delta, currency: currency}
    end
  end

  defp turn_cost(_latest, _anchor), do: nil

  # -- reasoning item lifecycle -------------------------------------------------
  #
  # Mirrors `Raxol.Agent.Contract.pump/3`'s reasoning lifecycle so an
  # ACP-backed session produces the same wire shape (durable
  # item_started/item_completed with `item_type: :reasoning`, ephemeral
  # deltas carrying the item_id) the fixture corpus and projection already
  # speak. Interleaved reasoning (think→tool→think→answer) yields multiple
  # ∴ blocks in true order — each segment gets its own turn-scoped id.

  # Buffer the thought (prepended; restored on read), then open-or-stream.
  defp stream_reasoning(state, chunk) do
    state = %{state | reasoning_buf: [chunk | state.reasoning_buf]}
    open_or_stream_reasoning(state, chunk)
  end

  # Not yet open: open on the FIRST non-blank accumulated content — a
  # whitespace-only thought opens no item_started, so it seals no block
  # (the "empty thinking → no ∴ block" rule). The opener's delta carries
  # the full accumulated-so-far text so the live tail is whole.
  defp open_or_stream_reasoning(%{reasoning_item: nil} = state, _chunk) do
    content = state.reasoning_buf |> Enum.reverse() |> Enum.join()

    if blank?(content) do
      state
    else
      seq = state.reasoning_seq + 1
      item_id = "#{state.turn_id}-reasoning-#{seq}"

      %{state | reasoning_seq: seq, reasoning_item: item_id}
      |> emit(:item_started, :durable, %{
        item_id: item_id,
        item_type: :reasoning
      })
      |> emit(:item_delta, :ephemeral, %{
        item_id: item_id,
        chunk: content,
        thought: true
      })
    end
  end

  defp open_or_stream_reasoning(state, chunk) do
    emit(state, :item_delta, :ephemeral, %{
      item_id: state.reasoning_item,
      chunk: chunk,
      thought: true
    })
  end

  # Seals an open reasoning item as a durable ∴ block. A no-op when nothing
  # is open (blank thought never opened, or an earlier boundary already
  # sealed it); the buffer always clears so the next segment starts fresh.
  defp seal_reasoning(%{reasoning_item: nil} = state),
    do: %{state | reasoning_buf: []}

  defp seal_reasoning(state) do
    content = state.reasoning_buf |> Enum.reverse() |> Enum.join()
    item_id = state.reasoning_item

    %{state | reasoning_item: nil, reasoning_buf: []}
    |> emit(:item_completed, :durable, %{
      item_type: :reasoning,
      item_id: item_id,
      content: content
    })
  end

  defp blank?(text), do: String.trim(text) == ""

  defp with_refs(payload, response) do
    case decode_refs(response) do
      [] -> payload
      refs -> Map.put(payload, :refs, refs)
    end
  end

  @doc """
  Tolerant, fail-safe evidence-ref decode from an ACP struct's `_meta`
  bucket (see the moduledoc). Public for the hostile-frame tests.
  """
  @spec decode_refs(term()) :: [non_neg_integer()]
  def decode_refs(%{_meta: meta}) when is_map(meta),
    do: decode_ref_list(Map.get(meta, "refs"))

  def decode_refs(_other), do: []

  defp decode_ref_list(refs) when is_list(refs) do
    if Enum.all?(refs, &(is_integer(&1) and &1 >= 0)) do
      refs
    else
      []
    end
  end

  defp decode_ref_list(_other), do: []

  # -- unmapped honesty ----------------------------------------------------------

  defp record_unmapped(state, kind) do
    seen_before? = Map.has_key?(state.unmapped, kind)
    state = %{state | unmapped: Map.update(state.unmapped, kind, 1, &(&1 + 1))}

    if seen_before? do
      state
    else
      emit(state, :error, :durable, %{
        reason: :unmapped_acp_update,
        kind: kind
      })
    end
  end

  # Kind extraction without atom minting: tags are existing atoms (stringified),
  # raw wire maps carry their own discriminator string, anything else collapses
  # to one bucket.
  defp unmapped_kind({:raw, %{"sessionUpdate" => kind}}) when is_binary(kind),
    do: "raw:" <> kind

  defp unmapped_kind({tag, _payload}) when is_atom(tag), do: Atom.to_string(tag)

  defp unmapped_kind(_other), do: "unrecognized"

  # -- emit ---------------------------------------------------------------------

  defp emit(state, type, tier, payload) do
    seq = state.seq + 1

    event = %Event{
      id: seq,
      session_id: state.session_id,
      turn_id: state.turn_id,
      ts: System.system_time(:microsecond),
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }

    SessionStreamer.emit(state.session_id, event, state.streamer)
    %{state | seq: seq}
  end
end
