defmodule Raxol.Agent.Harness.SessionInbox do
  @moduledoc """
  The session runtime for the live harness's tool-execution path — the
  process that consumes the routed `{:harness_command, action}` messages
  `Raxol.Agent.Command.route/2` delivers to a session's `:pid`, and turns a
  `:prompt` into a real tool-executing turn.

  Before this, the demo drove `Contract.pump/3` over a bare
  `Raxol.Agent.Stream.run/2` in an anonymous `Task` with no `:pid`, so the
  routed `interrupt`/`approval_decision` commands reached nothing. This
  GenServer is that missing consumer: put its pid on the session handle
  (`%{session_id: id, pid: inbox}`) and the harness's keyboard commands
  drive the turn.

  ## What it owns

    * **Turns.** `{:start_turn, _, %{text: prompt}}` spawns a `Task` that
      builds a `Raxol.Agent.Harness.ToolExecutor` stream and drains it
      through `Raxol.Agent.Contract.pump/3`. One turn at a time — a submit
      arriving mid-turn is queued and runs on the next boundary.
    * **Approvals (the parked request).** The executor loop, before a
      consequential tool, calls `await_permission/3` here — a `GenServer.call`
      that PARKS (`{:noreply}`, stashing the caller's `from` keyed by
      `request_id`), exactly as an ACP session parks a
      `session/request_permission`. The keyboard answer arrives as
      `{:approval_decision, _, %{request_id, option_id}}`; the inbox maps the
      chosen option to allow/deny and `GenServer.reply`s the parked caller,
      unblocking the tool. Fail-closed: if the turn dies with an approval
      still parked, the parked caller is already gone (linked), so nothing
      leaks.
    * **Interrupt (the staged kill).** `{:interrupt, _, _}` runs the REAL
      `Raxol.Agent.Interrupt.interrupt/3` against the live shell tool's
      `%{port, os_pid}` (published by `run_shell` via the injected
      `:shell_tool_ref_sink`), emitting its durable stage events
      (`:interrupt_signaled` … `:turn_canceled`) on the same
      `SessionStreamer` the surface is subscribed to, then kills the turn
      task. A tool-less interrupt (mid-approval, between rounds) still
      cancels the turn honestly.

  ## `--yolo`

  `gate?: false` disables the approval gate: consequential tools run without
  an approval block. The embedder is responsible for the honest POST
  disclosure that gating was off — the inbox simply never parks.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Harness.ToolExecutor
  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.SessionStreamer

  @type option :: %{option_id: String.t(), kind: atom()}

  @doc """
  Start the inbox for `session_id`.

  Options:
    * `:session_id` (required)
    * `:actions` — Action modules exposed as tools (default `[]`)
    * `:backend` / `:backend_opts` — AI backend selection
    * `:system_prompt` — resolved system prompt text
    * `:gate?` — approval gate on (default `true`); `false` is `--yolo`
    * `:max_iterations` — tool-loop guard
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       session_id: Keyword.fetch!(opts, :session_id),
       actions: Keyword.get(opts, :actions, []),
       backend: Keyword.get(opts, :backend, Raxol.Agent.Backend.Mock),
       backend_opts: Keyword.get(opts, :backend_opts, []),
       system_prompt: Keyword.get(opts, :system_prompt),
       gate?: Keyword.get(opts, :gate?, true),
       max_iterations: Keyword.get(opts, :max_iterations, 10),
       # Optional embedder pid notified `{:harness_turn_done, session_id}` on
       # each turn boundary, so a driver script can keep a completion-driven
       # queue / one-shot linger without subscribing to the event stream.
       notify: Keyword.get(opts, :notify),
       turn: nil,
       queue: [],
       pending: %{},
       tool_ref: nil
     }}
  end

  # -- the approval seam (called BY the executor loop) -----------------------

  @doc """
  Await a keyboard decision for a parked consequential tool. Blocks the
  caller (the executor loop) until `{:approval_decision, ...}` arrives.
  Returns `{:allow, option_id}` or `{:deny, option_id, reason}`.
  """
  @spec await_permission(pid(), String.t(), map()) :: ToolExecutor.decision()
  def await_permission(inbox, request_id, meta) do
    GenServer.call(inbox, {:await_permission, request_id, meta}, :infinity)
  end

  # -- turn lifecycle --------------------------------------------------------

  @impl true
  def handle_info({:harness_command, {:start_turn, _sid, payload}}, state) do
    text = Map.get(payload, :text) || Map.get(payload, "text")
    {:noreply, maybe_start_turn(state, text)}
  end

  def handle_info(
        {:harness_command, {:approval_decision, _sid, payload}},
        state
      ) do
    {:noreply, resolve_decision(state, payload)}
  end

  def handle_info({:harness_command, {:interrupt, _sid, payload}}, state) do
    {:noreply, do_interrupt(state, payload)}
  end

  # A turn Task finished (pump drained). Clear it and start the next queued
  # prompt, if any.
  def handle_info({ref, _result}, %{turn: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, turn_finished(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{turn: %{ref: ref}} = state
      ) do
    {:noreply, turn_finished(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # The shell tool publishes its live port/os_pid (or nil on exit) via the
  # injected sink, so an interrupt can target exactly that process.
  @impl true
  def handle_cast({:shell_tool_ref, ref}, state) do
    {:noreply, %{state | tool_ref: ref}}
  end

  # Park the approval: stash `from` + the offered options, keyed by
  # request_id, and reply LATER from the keyboard-answer path.
  @impl true
  def handle_call({:await_permission, request_id, meta}, from, state) do
    options = Map.get(meta, :options, [])

    pending =
      Map.put(state.pending, request_id, %{from: from, options: options})

    {:noreply, %{state | pending: pending}}
  end

  # -- internals -------------------------------------------------------------

  defp maybe_start_turn(state, text) when is_binary(text) do
    if String.trim(text) == "" do
      state
    else
      case state.turn do
        nil -> start_turn(state, text)
        _running -> %{state | queue: state.queue ++ [text]}
      end
    end
  end

  defp maybe_start_turn(state, _text), do: state

  defp start_turn(state, prompt) do
    inbox = self()
    session_id = state.session_id

    await_fun = fn request_id, meta ->
      await_permission(inbox, request_id, meta)
    end

    sink = fn ref -> GenServer.cast(inbox, {:shell_tool_ref, ref}) end

    executor_opts = [
      backend: state.backend,
      backend_opts: state.backend_opts,
      actions: state.actions,
      system_prompt: state.system_prompt,
      gate?: state.gate?,
      max_iterations: state.max_iterations,
      await_decision: await_fun,
      shell_tool_ref_sink: sink
    ]

    task =
      Task.async(fn ->
        stream = ToolExecutor.stream(prompt, executor_opts)
        Contract.pump(session_id, stream, prompt: prompt)
      end)

    %{state | turn: task}
  end

  defp turn_finished(state) do
    notify(state.notify, {:harness_turn_done, state.session_id})
    dequeue(%{state | turn: nil, tool_ref: nil})
  end

  defp notify(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp notify(_pid, _msg), do: :ok

  defp dequeue(%{queue: []} = state), do: state

  defp dequeue(%{queue: [next | rest]} = state),
    do: start_turn(%{state | queue: rest}, next)

  # Map the chosen option_id to allow/deny and reply to the parked executor
  # call, releasing the tool. An answer for an unknown request_id is a
  # no-op (a stale/duplicate delivery, or one for a request already resolved
  # by the turn dying).
  defp resolve_decision(state, payload) do
    request_id = Map.get(payload, :request_id) || Map.get(payload, "request_id")
    option_id = Map.get(payload, :option_id) || Map.get(payload, "option_id")

    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        state

      {%{from: from, options: options}, pending} ->
        GenServer.reply(from, decision_for(option_id, options))
        %{state | pending: pending}
    end
  end

  # The referent, not the string: match the chosen option_id against the
  # offered options and read its `kind`. An allow-kind (`:allow_once` /
  # `:allow_always`) means run; anything else (deny, or an unrecognized
  # option) fails closed to deny.
  defp decision_for(option_id, options) do
    case Enum.find(options, fn o -> opt_id(o) == option_id end) do
      %{kind: kind} = _opt when kind in [:allow_once, :allow_always] ->
        {:allow, option_id}

      _ ->
        {:deny, option_id || "deny", :operator_denied}
    end
  end

  defp opt_id(%{option_id: id}), do: id
  defp opt_id(%{"option_id" => id}), do: id
  defp opt_id(_), do: nil

  # The staged supervised kill. Targets the live shell tool_ref when one is
  # published, otherwise a tool-less ref (mid-approval / between rounds).
  # Stages are emitted as durable contract events on the shared stream — the
  # established out-of-band pattern (the interrupt keystone test) — then the
  # turn task is killed so the turn actually ends.
  defp do_interrupt(%{turn: nil} = state, _payload), do: state

  defp do_interrupt(state, payload) do
    turn_id = Map.get(payload, :turn_id) || Map.get(payload, "turn_id")

    tool_ref =
      (state.tool_ref || %{})
      |> Map.put_new(:port, nil)
      |> Map.put_new(:os_pid, nil)
      |> Map.put(:turn_id, turn_id)

    sink = interrupt_sink(state.session_id, turn_id)

    _ =
      try do
        Interrupt.interrupt(tool_ref, sink,
          reason: :harness_interrupt,
          actor: "operator"
        )
      rescue
        error -> Logger.warning("harness interrupt raised: #{inspect(error)}")
      catch
        kind, value ->
          Logger.warning("harness interrupt threw: #{inspect({kind, value})}")
      end

    # End the turn: the staged kill stopped the OS process; killing the pump
    # task stops the loop from marching to the next round.
    case state.turn do
      %Task{pid: pid} -> Process.exit(pid, :kill)
      _ -> :ok
    end

    %{state | tool_ref: nil}
  end

  defp interrupt_sink(session_id, turn_id) do
    fn stage, stage_payload ->
      event = %Contract.Event{
        id: System.unique_integer([:positive, :monotonic]),
        session_id: session_id,
        turn_id: turn_id,
        ts: System.system_time(:microsecond),
        family: :loop,
        type: stage,
        tier: :durable,
        payload: stage_payload
      }

      SessionStreamer.emit(session_id, event)
      :ok
    end
  end
end
