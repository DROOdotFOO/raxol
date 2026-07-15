defmodule Raxol.Agent.Contract do
  @moduledoc """
  Harness contract v0 — the typed event contract between the agent core and
  any surface (CLI, TUI, LiveView, remote).

  This is the minimal loop-family slice of the contract in
  `docs/proposals/in-flight/harness-spec-protocol.md`: every observable step
  of an agent run becomes a `Raxol.Agent.Contract.Event` and is published
  through `Raxol.Agent.SessionStreamer`. Surfaces subscribe to the streamer
  and render; they never reach into the loop.

  (Distinct from `Raxol.Agent.Protocol`, which is agent-to-agent cockpit
  messaging — this module is the core↔surface boundary.)

  ## v0 vocabulary (family `:loop` only)

    * `:turn_started`   — a prompt was accepted; payload `%{prompt}`
    * `:item_delta`     — streaming text chunk; payload `%{chunk}`;
      the one **ephemeral** event (live render only, never for replay)
    * `:item_completed` — a finished item; payload
      `%{item_type: :message | :tool_use | :tool_result, ...}`
    * `:turn_completed` — a turn boundary; payload
      `%{usage, iteration, final}` (`final: true` closes the run)
    * `:error`          — fault; payload `%{reason}`

  The meta family (probe swarm), `steer`/`approval` commands, and the
  durable journal sink attach behind this same boundary in later steps —
  producers change, the contract does not.

  ## Producers

  The v0 producer is `pump/3`: it drains a `Raxol.Agent.Stream.run/2` or
  `Raxol.Agent.Stream.react/2` enumerable, wraps each event in the contract
  envelope, and emits it into the streamer. The Dispatcher fold-site emit
  (the keystone) is the next producer and plugs in behind the same
  `SessionStreamer` boundary without surfaces changing.
  """

  alias Raxol.Agent.SessionStreamer

  defmodule Event do
    @moduledoc """
    The contract envelope. One struct per observable step; `id` is a
    per-run monotonic sequence (the future journal offset).
    """

    @derive Jason.Encoder
    defstruct v: 0,
              id: 0,
              session_id: nil,
              turn_id: nil,
              ts: 0,
              family: :loop,
              type: nil,
              tier: :durable,
              payload: %{}

    @type t :: %__MODULE__{
            v: non_neg_integer(),
            id: non_neg_integer(),
            session_id: String.t(),
            turn_id: String.t() | nil,
            ts: integer(),
            family: :loop | :meta,
            type: atom(),
            tier: :ephemeral | :durable,
            payload: map()
          }
  end

  @doc """
  Encode an event as a JSON line (newline-terminated) for wire surfaces
  (the CLI's stderr event feed, SSE bodies). Decoding arrives with the
  command channel; v0 is emit-only.
  """
  @spec encode_line(Event.t()) :: iodata()
  def encode_line(%Event{} = event) do
    [Jason.encode!(sanitize(event)), "\n"]
  end

  @doc """
  Coerce a payload map into a JSON-encodable one.

  Same boundary sanitization `encode_line/1` applies, exposed for the durable
  journal sink: an event whose payload carries non-encodable terms (message
  tuples, structs, pids) must not crash `Jason.encode!` when appended. Anything
  Jason can't take becomes `inspect/1` text.
  """
  @spec sanitize_payload(map()) :: map()
  def sanitize_payload(payload) when is_map(payload), do: sanitize_value(payload)

  # Payloads may carry non-JSON-encodable terms (error reasons, tuples,
  # arbitrary tool results). Sanitize at the boundary rather than crash
  # the feed: anything Jason can't take becomes `inspect/1` text.
  defp sanitize(%Event{payload: payload} = event) do
    %{event | payload: sanitize_value(payload)}
  end

  defp sanitize_value(%_struct{} = struct),
    do: struct |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_value(v)} end)
  end

  defp sanitize_value(list) when is_list(list) do
    if List.improper?(list) do
      inspect(list)
    else
      Enum.map(list, &sanitize_value/1)
    end
  end

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or
              is_atom(value),
       do: value

  defp sanitize_value(other), do: inspect(other)

  defp sanitize_key(key) when is_atom(key) or is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)

  @doc """
  Drain a `Raxol.Agent.Stream` enumerable into the contract.

  Emits `turn_started` first, then maps each stream event onto the v0
  vocabulary and publishes it via `SessionStreamer.emit/2`. Returns
  `{:ok, %{content, usage}}` on completion or `{:error, reason}`.

  Blocks until the stream is done — run it in its own process (the CLI
  uses `Task.async/1`); subscribers receive events live.
  """
  @spec pump(String.t(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def pump(session_id, stream, opts \\ []) do
    prompt = Keyword.get(opts, :prompt, "")
    turn_id = "turn-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])

    emit_event(session_id, turn_id, counter, :turn_started, :durable, %{
      prompt: prompt
    })

    Enum.reduce(stream, {:error, :no_result}, fn stream_event, acc ->
      handle_stream_event(session_id, turn_id, counter, stream_event, acc)
    end)
  end

  defp handle_stream_event(session_id, turn_id, counter, event, acc) do
    case event do
      {:text_delta, chunk} ->
        emit_event(session_id, turn_id, counter, :item_delta, :ephemeral, %{
          chunk: chunk
        })

        acc

      {:tool_use, %{name: name} = tool_use} ->
        emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
          item_type: :tool_use,
          name: name,
          arguments: Map.get(tool_use, :arguments, %{}),
          call_id: Map.get(tool_use, :id)
        })

        acc

      {:tool_result, %{name: name} = tool_result} ->
        emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
          item_type: :tool_result,
          name: name,
          result: Map.get(tool_result, :result)
        })

        acc

      {:turn_complete, info} ->
        emit_event(session_id, turn_id, counter, :turn_completed, :durable, %{
          iteration: Map.get(info, :iteration, 0),
          usage: Map.get(info, :usage, %{}),
          final: false
        })

        acc

      {:done, %{content: content} = info} ->
        emit_event(session_id, turn_id, counter, :item_completed, :durable, %{
          item_type: :message,
          content: content
        })

        emit_event(session_id, turn_id, counter, :turn_completed, :durable, %{
          usage: Map.get(info, :usage, %{}),
          final: true
        })

        {:ok, %{content: content, usage: Map.get(info, :usage, %{})}}

      {:error, reason} ->
        emit_event(session_id, turn_id, counter, :error, :durable, %{
          reason: reason
        })

        {:error, reason}

      _other ->
        acc
    end
  end

  defp emit_event(session_id, turn_id, counter, type, tier, payload) do
    :counters.add(counter, 1, 1)

    event = %Event{
      id: :counters.get(counter, 1),
      session_id: session_id,
      turn_id: turn_id,
      ts: System.system_time(:microsecond),
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }

    SessionStreamer.emit(session_id, event)
  end
end
