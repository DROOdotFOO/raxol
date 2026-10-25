defmodule Raxol.Agent.OMP.Lane do
  @moduledoc """
  One `omp --mode rpc` session (`Raxol.Agent.OMP.RPC`) as a
  `Raxol.Harness.SessionLane`, fronted by a Raxol surface for one
  authenticated person (ADR-0042, decision 7).

  `start_link/1` refuses to start without an authenticated principal
  (`Raxol.Agent.OMP.Principal`): `{:error, {:unauthenticated_principal,
  reason}}`, before OMP is spawned. The principal's pid becomes the RPC
  session's `:principal`, so every exec-tier approval goes to it as
  `{:omp_rpc_approval, rpc, ui_id, frame}` and it answers with
  `Raxol.Agent.OMP.RPC.answer/3`. An approval it does not answer within the
  RPC session's `:approval_timeout_ms`, or that is open when the principal
  exits or the session closes, is denied (see `Raxol.Agent.OMP.RPC`).

  Options: `:principal` (required; the claim `Principal.authenticate/1`
  takes), `:session_id` (required; a non-empty string), `:rpc` (the
  `Raxol.Agent.OMP.RPC.start_link/1` options, without `:subscriber` and
  `:principal`, which the lane sets), `:name`. The RPC session is linked:
  when it stops, the lane stops with it.

  ## The seam

  `session/1` returns the `Raxol.Harness.SessionLane.session()` map, which
  also carries the RPC session's pid (`:rpc`).

    * `subscribe/1`: the caller receives `{:session_event, session_id,
      event}` (a `Raxol.Agent.Contract.Event`) until it exits.
    * `prompt/2`: OMP `prompt` with the payload's `:text`; `:ok` once OMP
      admits it, or the request's error (`{:error, :not_ready}` before the
      handshake finished).
    * `interrupt/2`: OMP `abort`; the turn's end is event-observed.
    * `steer/2`: OMP `steer` with the request's `:text`, answered
      `{:ok, {:accepted, %{client_msg_id: id}}}` once OMP queued it. OMP's
      `steer` has no compare-and-swap, so `:expected_turn_id` is not
      checked (a steer meant for a turn that already ended steers the next
      one) and a repeated `:client_msg_id` is steered again, never answered
      `:duplicate`.
    * `monitor/1`: monitors the lane.

  `close/2` closes the RPC session (`Raxol.Agent.OMP.RPC.close/2`), which
  denies every open approval first.

  ## Events

  OMP's frames map onto the contract events (`Raxol.Agent.Contract`) like
  this; every event carries `provenance: %{source: :omp, trust: :tainted}`
  (it comes from a process this VM does not control), and item ids are
  OMP's own:

  | OMP frame | Contract event |
  |---|---|
  | `agent_start` | opens a turn (`turn_id` `"t<n>"`) |
  | first `message_end` with `role: "user"` in a turn | `turn_started` `%{prompt: text}` (`prompt: nil` when the run's first event is not one) |
  | `message_update` `text_delta` / `thinking_delta` | `item_started` once, then `item_delta` `%{item_id, chunk}` (ephemeral); `item_id` is `<messageId>/text` or `/thinking` |
  | `message_end` with `role: "assistant"` | `item_completed` `:reasoning` and `:message` with their `content` (a blank one is skipped) |
  | `tool_execution_start` | `item_completed` `:tool_use` `%{name}` (`item_id` = `toolCallId`) |
  | `tool_execution_end` | `item_completed` `:tool_result` `%{name, is_error}` (`<toolCallId>/result`) |
  | `turn_end` | `turn_completed` `%{iteration, final: false}` |
  | `agent_end` | `turn_completed` `%{iteration, final: true}` (`final: false` when `isTerminal` is false) |
  | `prompt_result` `status: "aborted"` | `turn_canceled` |
  | `prompt_result` `status: "error"` | `error` `%{reason: "prompt_error"}` |

  Everything else (approval frames, which go to the principal; tool
  progress; queue, compaction and retry events; `session_settled`) maps to
  nothing. Usage is not carried.
  """

  @behaviour Raxol.Harness.SessionLane

  use GenServer, restart: :temporary

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.OMP.Principal
  alias Raxol.Agent.OMP.RPC

  @provenance %{source: :omp, trust: :tainted}
  # A message's blocks in transcript order: reasoning before the answer.
  @blocks [{"thinking", :reasoning}, {"text", :message}]
  @deltas %{"thinking_delta" => {"thinking", :reasoning}, "text_delta" => {"text", :message}}

  @doc "Start a lane; see the moduledoc."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The lane's `Raxol.Harness.SessionLane.session()`, plus `:rpc`."
  @spec session(GenServer.server()) :: %{session_id: String.t(), pid: pid(), rpc: pid()}
  def session(lane), do: GenServer.call(lane, :session)

  @doc "Close the session; see `Raxol.Agent.OMP.RPC.close/2`."
  @spec close(map(), non_neg_integer()) :: :ok | {:error, term()}
  def close(%{rpc: rpc}, timeout_ms \\ 60_000), do: RPC.close(rpc, timeout_ms)

  @impl Raxol.Harness.SessionLane
  def subscribe(%{pid: lane}) do
    GenServer.call(lane, :subscribe)
  catch
    :exit, _reason -> {:error, :lane_down}
  end

  @impl Raxol.Harness.SessionLane
  def prompt(%{rpc: rpc}, payload) when is_map(payload) do
    with {:ok, text} <- text(payload),
         {:ok, _data} <- RPC.request(rpc, %{"type" => "prompt", "message" => text}),
         do: :ok
  end

  @impl Raxol.Harness.SessionLane
  def interrupt(%{rpc: rpc}, payload) when is_map(payload) do
    with {:ok, _data} <- RPC.request(rpc, %{"type" => "abort"}), do: :ok
  end

  @impl Raxol.Harness.SessionLane
  def steer(%{rpc: rpc}, request) when is_map(request) do
    with {:ok, text} <- text(request),
         {:ok, _data} <- RPC.request(rpc, %{"type" => "steer", "message" => text}) do
      {:ok, {:accepted, %{client_msg_id: field(request, :client_msg_id)}}}
    end
  end

  @impl Raxol.Harness.SessionLane
  def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
  def monitor(_session), do: nil

  defp text(payload) do
    case field(payload, :text) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _other -> {:error, {:invalid_command, :text}}
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, session_id} <- session_id(Keyword.get(opts, :session_id)),
         {:ok, principal} <- Principal.authenticate(Keyword.get(opts, :principal)),
         rpc_opts =
           Keyword.merge(Keyword.get(opts, :rpc, []),
             subscriber: self(),
             principal: principal.pid
           ),
         {:ok, rpc} <- RPC.start_link(rpc_opts) do
      {:ok,
       %{
         session_id: session_id,
         rpc: rpc,
         subscribers: %{},
         seq: 0,
         turn: 0,
         open?: false,
         iteration: 0,
         started: MapSet.new()
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp session_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp session_id(_id), do: {:error, {:invalid_option, :session_id}}

  @impl true
  def handle_call(:session, _from, state),
    do: {:reply, %{session_id: state.session_id, pid: self(), rpc: state.rpc}, state}

  def handle_call(:subscribe, {pid, _tag}, state) do
    subscribers =
      if is_map_key(state.subscribers, pid),
        do: state.subscribers,
        else: Map.put(state.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:omp_rpc, rpc, frame}, %{rpc: rpc} = state), do: {:noreply, map(state, frame)}

  def handle_info({:EXIT, rpc, reason}, %{rpc: rpc} = state),
    do: {:stop, if(reason == :normal, do: :normal, else: {:shutdown, reason}), state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  # -- OMP frames -> contract events (the moduledoc's table) --------------------

  defp map(state, %{"type" => "agent_start"}),
    do: %{state | turn: state.turn + 1, open?: false, iteration: 0, started: MapSet.new()}

  defp map(%{open?: false} = state, %{
         "type" => "message_end",
         "message" => %{"role" => "user"} = message
       }),
       do: open(state, blocks(message["content"], "text"))

  defp map(state, %{
         "type" => "message_update",
         "messageId" => message_id,
         "assistantMessageEvent" => %{"type" => kind, "delta" => delta}
       })
       when is_map_key(@deltas, kind) and is_binary(delta) do
    {block, item_type} = Map.fetch!(@deltas, kind)
    item = "#{message_id}/#{block}"

    if String.trim(delta) == "" and not MapSet.member?(state.started, item),
      do: state,
      else:
        state
        |> start(item, item_type)
        |> emit(:item_delta, :ephemeral, %{item_id: item, chunk: delta})
  end

  defp map(state, %{
         "type" => "message_end",
         "messageId" => message_id,
         "message" => %{"role" => "assistant", "content" => content}
       }) do
    Enum.reduce(@blocks, state, fn {block, item_type}, state ->
      case blocks(content, block) do
        "" -> state
        text -> complete(state, "#{message_id}/#{block}", item_type, %{content: text})
      end
    end)
  end

  defp map(state, %{"type" => "tool_execution_start", "toolCallId" => id, "toolName" => name}),
    do: complete(state, id, :tool_use, %{name: name})

  defp map(
         state,
         %{"type" => "tool_execution_end", "toolCallId" => id, "toolName" => name} = frame
       ),
       do:
         complete(state, "#{id}/result", :tool_result, %{
           name: name,
           is_error: frame["isError"] == true
         })

  defp map(state, %{"type" => "turn_end"}) do
    state
    |> emit(:turn_completed, :durable, %{iteration: state.iteration, final: false})
    |> Map.update!(:iteration, &(&1 + 1))
  end

  defp map(state, %{"type" => "agent_end"} = frame),
    do:
      emit(state, :turn_completed, :durable, %{
        iteration: state.iteration,
        final: frame["isTerminal"] != false
      })

  defp map(state, %{"type" => "prompt_result", "status" => "aborted"}),
    do: emit(state, :turn_canceled, :durable, %{})

  defp map(state, %{"type" => "prompt_result", "status" => "error"}),
    do: emit(state, :error, :durable, %{reason: "prompt_error"})

  defp map(state, _frame), do: state

  defp open(state, prompt) do
    state = %{state | open?: true}
    emit(state, :turn_started, :durable, %{prompt: if(prompt != "", do: prompt)})
  end

  defp start(state, item, item_type) do
    if MapSet.member?(state.started, item) do
      state
    else
      state = %{state | started: MapSet.put(state.started, item)}
      emit(state, :item_started, :durable, %{item_id: item, item_type: item_type})
    end
  end

  defp complete(state, item, item_type, payload) do
    state
    |> start(item, item_type)
    |> emit(:item_completed, :durable, Map.merge(payload, %{item_id: item, item_type: item_type}))
  end

  defp blocks(content, type) when is_list(content) do
    for %{"type" => ^type} = block <- content,
        text = block[type],
        is_binary(text),
        into: "",
        do: text
  end

  defp blocks(_content, _type), do: ""

  # A run's first mapped event opens its turn when no user message did.
  defp emit(%{open?: false} = state, type, tier, payload) when type != :turn_started,
    do: state |> open("") |> emit(type, tier, payload)

  defp emit(state, type, tier, payload) do
    event = %Event{
      id: state.seq + 1,
      session_id: state.session_id,
      turn_id: "t#{state.turn}",
      ts: System.system_time(:millisecond),
      type: type,
      tier: tier,
      payload: payload,
      provenance: @provenance
    }

    Enum.each(state.subscribers, fn {pid, _ref} ->
      send(pid, {:session_event, state.session_id, event})
    end)

    %{state | seq: state.seq + 1}
  end
end
