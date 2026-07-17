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

  ## Unknown-variant honesty (skip, count, disclose once)

  Any update this adapter has no mapping for — the known-but-unmapped
  variants (`user_message_chunk`, `available_commands_update`,
  `current_mode_update`, `config_option_update`, `session_info_update`,
  `usage_update`), a `{:raw, map}` from a manual `decode_update/1` feed,
  a future 12th variant, or outright garbage — is SKIPPED, never crashed
  on (the tolerant-reading rule). But the skip is never silent: each kind
  is counted (`unmapped_counts/1`), and the FIRST occurrence of each kind
  emits one durable `:error` contract event with payload
  `%{reason: :unmapped_acp_update, kind: kind}` so the transcript shows an
  honest fidelity gap instead of a gapless lie. Subsequent occurrences of
  the same kind only bump the counter (bounded log emission — one marker
  per kind per adapter lifetime).

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

  defstruct [
    :session_id,
    :streamer,
    :turn_id,
    :reasoning_item,
    seq: 0,
    reasoning_seq: 0,
    pending_tools: %{},
    unmapped: %{},
    message_buf: [],
    reasoning_buf: []
  ]

  @type t :: %__MODULE__{
          session_id: term(),
          streamer: GenServer.server(),
          turn_id: String.t() | nil,
          reasoning_item: String.t() | nil,
          seq: non_neg_integer(),
          reasoning_seq: non_neg_integer(),
          pending_tools: %{optional(String.t()) => map()},
          unmapped: %{optional(String.t()) => pos_integer()},
          message_buf: [String.t()],
          reasoning_buf: [String.t()]
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
    turn_id = "turn-#{System.unique_integer([:positive])}"

    state = %{
      state
      | turn_id: turn_id,
        pending_tools: %{},
        message_buf: [],
        reasoning_item: nil,
        reasoning_buf: [],
        reasoning_seq: 0
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

    {:reply, :ok,
     %{
       state
       | turn_id: nil,
         pending_tools: %{},
         message_buf: [],
         reasoning_item: nil,
         reasoning_buf: [],
         reasoning_seq: 0
     }}
  end

  def handle_manager_call(:unmapped_counts, _from, state) do
    {:reply, state.unmapped, state}
  end

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
    {:noreply, apply_update(state, update)}
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

  # Everything else — known-but-unmapped variants, {:raw, map} from a manual
  # decode_update/1 feed, future variants, garbage — is skipped, counted, and
  # disclosed once per kind. See the moduledoc's unknown-variant section.
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
    state
    |> seal_assistant_message()
    |> emit(
      :turn_completed,
      :durable,
      with_refs(
        %{
          usage: %{},
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
    state
    |> seal_assistant_message()
    |> emit(
      :turn_completed,
      :durable,
      with_refs(
        %{usage: %{}, iteration: 0, final: true, stop_reason: reason},
        response
      )
    )
  end

  # A stop reason outside the ACP enum (forged wire value, garbage term):
  # disclosed, never coerced to a normal completion, never granted refs.
  # The accumulated assistant text still seals — the words WERE said; only
  # the completion claim is suspect.
  defp close_turn(state, %{stop_reason: other}) do
    state
    |> seal_assistant_message()
    |> emit(:turn_completed, :durable, %{
      usage: %{},
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
