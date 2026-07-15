defmodule Raxol.Agent.StreamingTurnAttributionTest do
  @moduledoc """
  Async cross-turn contamination regression (PR #547 review, finding 3).

  A streaming agent dispatches an async command in turn N whose delta lands
  AFTER turn N+1 has started and finished. The dispatcher is a single mailbox,
  so an emit-time read of `state.turn_id` would stamp the late delta with
  whatever is current — nil between turns, or a later turn's id if one is in
  flight — poisoning U6's `expected_turn_id` CAS. The fix snapshots the
  minting turn's id into the command's own context at dispatch; the executor
  echoes it back, so the delta carries its ORIGINATING turn's id.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Session
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  # A streaming agent: {:stream, coordinator} dispatches an async command
  # whose task blocks until the test releases it — so the delta can be forced
  # to land after a later turn has already run.
  defmodule StreamingAgent do
    use Raxol.Agent

    def init(_context), do: %{}

    def update({:agent_message, _from, {:stream, coordinator}}, model) do
      directive =
        Raxol.Agent.Directive.async(fn sender ->
          send(coordinator, {:async_task_started, self()})

          receive do
            :release -> sender.({:chunk, "late"})
          end
        end)

      {model, [directive]}
    end

    def update(_msg, model), do: {model, []}

    def view(_model), do: text("streaming")
  end

  setup do
    ensure_registry(:duplicate, EmitBus.registry_name())

    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!(Raxol.Agent.SessionStreamer)

    :ok
  end

  test "an async delta dispatched in turn N and landing after turn N+1 carries turn N's id" do
    session_id = "u15-stream-attr-#{uniq()}"

    {:ok, sess} =
      Session.start_link(
        app_module: StreamingAgent,
        id: :"u15_stream_attr_#{uniq()}",
        session_id: session_id
      )

    on_exit(fn -> stop(sess) end)

    :ok = SessionStreamer.subscribe(session_id)

    # Turn N: dispatches the async command, whose task parks until released.
    :ok = Session.send_message(agent_id(sess), {:stream, self()})

    assert_receive {:session_event, ^session_id, %Event{type: :turn_started} = started_n},
                   1_000

    assert_receive {:session_event, ^session_id, %Event{type: :turn_completed}},
                   1_000

    assert_receive {:async_task_started, task}, 1_000
    turn_n = started_n.turn_id
    assert is_binary(turn_n)

    # Turn N+1 starts AND completes while turn N's async result is still
    # pending — the overlap Drew's finding 3 describes.
    :ok = Session.send_message(agent_id(sess), :noop)

    assert_receive {:session_event, ^session_id, %Event{type: :turn_started} = started_n1},
                   1_000

    assert_receive {:session_event, ^session_id, %Event{type: :turn_completed}},
                   1_000

    turn_n1 = started_n1.turn_id
    refute turn_n1 == turn_n

    # Release turn N's stream. The late delta must be stamped with turn N's
    # id — not turn N+1's, not nil.
    send(task, :release)

    assert_receive {:session_event, ^session_id, %Event{type: :item_delta} = delta},
                   1_000

    assert delta.tier == :ephemeral
    assert delta.turn_id == turn_n
    refute delta.turn_id == turn_n1
  end

  # --- helpers ---------------------------------------------------------------

  defp agent_id(sess) do
    %{id: id} = :sys.get_state(sess)
    id
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp ensure_registry(keys, name) do
    case Registry.start_link(keys: keys, name: name) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_running({mod, opts}) do
    case start_child(mod, opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_child(DynamicSupervisor, opts),
    do: DynamicSupervisor.start_link(opts)

  defp start_child(mod, opts), do: mod.start_link(opts)
end
