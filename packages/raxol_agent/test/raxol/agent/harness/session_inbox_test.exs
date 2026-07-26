defmodule Raxol.Agent.Harness.SessionInboxTest do
  @moduledoc """
  Integration spec for `Raxol.Agent.Harness.SessionInbox` — the session
  runtime that consumes the routed harness commands and runs a
  tool-executing turn. Drives it through the REAL `Raxol.Agent.SessionStreamer`
  (subscribing this process to collect the emitted contract events), so the
  keyboard→approval→execution round trip is exercised end to end.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Harness.SessionInbox
  alias Raxol.Agent.SessionStreamer

  defmodule ScriptBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, opts) do
      agent = Keyword.fetch!(opts, :script)

      step =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {:eot, []}
        end)

      case step do
        {:tool_calls, tcs} -> {:ok, %{content: "", tool_calls: tcs, usage: %{}}}
        {:content, text} -> {:ok, %{content: text, usage: %{}}}
        :eot -> {:ok, %{content: "(end)", usage: %{}}}
      end
    end

    @impl true
    def stream(_m, _o), do: {:error, :streaming_not_used}
    @impl true
    def available?, do: true
    @impl true
    def name, do: "script"
    @impl true
    def capabilities, do: [:completion, :tool_use]
  end

  setup do
    start_supervised!(SessionStreamer)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "raxol-inbox-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", tmp)

    on_exit(fn ->
      if prev,
        do: System.put_env("RAXOL_CLI_CWD", prev),
        else: System.delete_env("RAXOL_CLI_CWD")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp script(steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)
    agent
  end

  # Collect the next event of `type` off this process's SessionStreamer feed
  # within a budget, or flunk.
  defp drain_until(type, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain_until(type, deadline)
  end

  defp do_drain_until(type, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      ExUnit.Assertions.flunk("no #{type} event")
    else
      receive do
        {:session_event, _sid, %{type: ^type} = event} -> event
        {:session_event, _sid, _other} -> do_drain_until(type, deadline)
      after
        remaining -> ExUnit.Assertions.flunk("no #{type} event")
      end
    end
  end

  defp start_inbox(session_id, steps, opts) do
    {:ok, inbox} =
      SessionInbox.start_link(
        Keyword.merge(
          [
            session_id: session_id,
            backend: ScriptBackend,
            backend_opts: [script: script(steps)]
          ],
          opts
        )
      )

    inbox
  end

  test "approve: keyboard answer routes back and the edit runs, tool_result carries the diff",
       %{tmp: tmp} do
    session_id = "inbox-approve-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    path = Path.join(tmp, "code.ex")
    File.write!(path, "value = 1\n")

    inbox =
      start_inbox(
        session_id,
        [
          {:tool_calls,
           [
             %{
               "name" => "edit_file",
               "arguments" => %{
                 "path" => "code.ex",
                 "old_string" => "value = 1",
                 "new_string" => "value = 2"
               },
               "id" => "e1"
             }
           ]},
          {:content, "Done."}
        ],
        actions: Raxol.Agent.Actions.Workspace.all()
      )

    send(
      inbox,
      {:harness_command, {:start_turn, session_id, %{text: "bump it"}}}
    )

    req = drain_until(:approval_requested)
    request_id = req.payload.request_id
    assert req.payload.tool_name == "edit_file"

    # The edit has NOT happened yet — the frontier is held.
    assert File.read!(path) == "value = 1\n"

    # Simulate the keyboard answer routed through answer_permission.
    send(
      inbox,
      {:harness_command,
       {:approval_decision, session_id, %{request_id: request_id, option_id: "allow"}}}
    )

    decided = drain_until(:approval_decided)
    assert decided.payload.request_id == request_id

    tool_result = drain_until(:item_completed)
    # Find the tool_result item (may need to skip a message item).
    tool_result =
      if tool_result.payload[:item_type] == :tool_result,
        do: tool_result,
        else: find_tool_result()

    assert %{path: "code.ex", old: old, new: new} = tool_result.payload.result
    assert old =~ "value = 1"
    assert new =~ "value = 2"
    assert File.read!(path) =~ "value = 2"
  end

  test "a parked approval's pending entry is reaped when its turn dies, not left to leak",
       %{tmp: tmp} do
    session_id = "inbox-reap-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    path = Path.join(tmp, "code.ex")
    File.write!(path, "value = 1\n")

    inbox =
      start_inbox(
        session_id,
        [
          {:tool_calls,
           [
             %{
               "name" => "edit_file",
               "arguments" => %{
                 "path" => "code.ex",
                 "old_string" => "value = 1",
                 "new_string" => "value = 2"
               },
               "id" => "e1"
             }
           ]},
          {:content, "never reached"}
        ],
        actions: Raxol.Agent.Actions.Workspace.all()
      )

    send(
      inbox,
      {:harness_command, {:start_turn, session_id, %{text: "bump it"}}}
    )

    _req = drain_until(:approval_requested)

    parked_state = :sys.get_state(inbox)
    assert map_size(parked_state.pending) == 1, "the approval must be parked"

    # Kill the turn task directly (no answer ever arrives) -- the same
    # shape as a crash mid-approval, without going through the interrupt
    # path.
    %Task{pid: turn_pid} = parked_state.turn
    Process.exit(turn_pid, :kill)

    reaped_state = wait_until_turn_cleared(inbox)

    assert reaped_state.pending == %{},
           "a parked approval's pending entry leaked after its turn died"
  end

  defp wait_until_turn_cleared(inbox, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_turn_cleared(inbox, deadline)
  end

  defp do_wait_until_turn_cleared(inbox, deadline) do
    state = :sys.get_state(inbox)

    cond do
      state.turn == nil ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("turn never cleared after being killed")

      true ->
        Process.sleep(20)
        do_wait_until_turn_cleared(inbox, deadline)
    end
  end

  test "deny: no file change, honest denial", %{tmp: tmp} do
    session_id = "inbox-deny-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    path = Path.join(tmp, "code.ex")
    File.write!(path, "value = 1\n")

    inbox =
      start_inbox(
        session_id,
        [
          {:tool_calls,
           [
             %{
               "name" => "edit_file",
               "arguments" => %{
                 "path" => "code.ex",
                 "old_string" => "value = 1",
                 "new_string" => "value = 2"
               },
               "id" => "e1"
             }
           ]},
          {:content, "Won't touch it."}
        ],
        actions: Raxol.Agent.Actions.Workspace.all()
      )

    send(
      inbox,
      {:harness_command, {:start_turn, session_id, %{text: "bump it"}}}
    )

    req = drain_until(:approval_requested)

    send(
      inbox,
      {:harness_command,
       {:approval_decision, session_id, %{request_id: req.payload.request_id, option_id: "deny"}}}
    )

    _decided = drain_until(:approval_decided)
    _tr = find_tool_result()

    assert File.read!(path) == "value = 1\n"
  end

  @tag :unix_only
  test "interrupt: a running shell is staged-killed and the turn is canceled",
       %{tmp: _tmp} do
    session_id = "inbox-interrupt-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    inbox =
      start_inbox(
        session_id,
        [
          {:tool_calls,
           [
             %{
               "name" => "run_shell",
               "arguments" => %{"command" => "sleep 30"},
               "id" => "s1"
             }
           ]},
          {:content, "never reached"}
        ],
        actions: [Raxol.Agent.Actions.Shell],
        # yolo: auto-run the shell so it is live when we interrupt.
        gate?: false
      )

    send(
      inbox,
      {:harness_command, {:start_turn, session_id, %{text: "run it"}}}
    )

    # Wait for the shell to announce itself (tool_use) and be live.
    _use = drain_until(:item_completed)
    Process.sleep(150)

    send(inbox, {:harness_command, {:interrupt, session_id, %{turn_id: "t"}}})

    canceled = drain_until(:turn_canceled, 5_000)
    assert canceled.type == :turn_canceled
  end

  # Helper: pull the next item_completed that is a tool_result off the feed.
  defp find_tool_result(timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_find_tool_result(deadline)
  end

  defp do_find_tool_result(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      ExUnit.Assertions.flunk("no tool_result item")
    else
      receive do
        {:session_event, _sid, %{type: :item_completed, payload: %{item_type: :tool_result}} = e} ->
          e

        {:session_event, _sid, _other} ->
          do_find_tool_result(deadline)
      after
        remaining -> ExUnit.Assertions.flunk("no tool_result item")
      end
    end
  end
end
