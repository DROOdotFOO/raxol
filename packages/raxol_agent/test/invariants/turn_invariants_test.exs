defmodule Raxol.Agent.Invariants.TurnInvariantsTest do
  @moduledoc """
  Tier-1 invariant I4 — turn attribution under GENERATED overlapping async
  turns (see `docs/harness/architecture.md`'s "Journal and projection"
  section for the turn-bucketing model).

  The known hole: a single-threaded sequential-turn generator never fires
  the emit-time-stamp bug, making the property vacuous. Every generated
  schedule here is async-crossing BY CONSTRUCTION (m5): each parked async
  delta is released only after at least one LATER turn has started AND
  completed, so a `state.turn_id` read at emit time would stamp nil or the
  wrong turn. The property: every event carries nil or its ORIGINATING turn's
  id — never a neighbor's.

  The dispatcher snapshots the minting turn's id into the command context
  at dispatch and the executor echoes it back as
  `{:command_result, msg, %{turn_id: ...}}`, which is what keeps this green.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Invariants.FaultJournal
  alias Raxol.Agent.Session
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  # A streaming agent: {:park, coordinator, tag} dispatches an async command
  # whose task parks until released, then emits a delta carrying `tag` — so the
  # test can correlate each delta back to the turn that minted it.
  defmodule OverlapAgent do
    use Raxol.Agent

    def init(_context), do: %{}

    def update({:agent_message, _from, {:park, coordinator, tag}}, model) do
      directive =
        Raxol.Agent.Directive.async(fn sender ->
          send(coordinator, {:parked, tag, self()})

          receive do
            :release -> sender.({:chunk, tag})
          end
        end)

      {model, [directive]}
    end

    def update(_msg, model), do: {model, []}

    def view(_model), do: text("overlap")
  end

  setup do
    FaultJournal.ensure_registry(:duplicate, EmitBus.registry_name())

    FaultJournal.ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    FaultJournal.ensure_running(
      {DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one}
    )

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!(Raxol.Agent.SessionStreamer)

    :ok
  end

  describe "I4 — turn attribution under async overlap" do
    property "every delta carries its ORIGINATING turn's id under generated async-crossing schedules" do
      check all(
              n_parking <- integer(1..3),
              n_trailing <- integer(1..3),
              shuffle_seed <- integer(0..1_000_000),
              max_runs: 10
            ) do
        session_id = "inv-turn-#{uniq()}"

        {:ok, sess} =
          Session.start_link(
            app_module: OverlapAgent,
            id: :"inv_turn_#{uniq()}",
            session_id: session_id
          )

        :ok = SessionStreamer.subscribe(session_id)

        # Phase 1 — parking turns: each mints a turn, dispatches an async
        # command, and COMPLETES while the command's delta is still pending.
        parked =
          for k <- 1..n_parking do
            tag = "park-#{k}-#{uniq()}"
            :ok = Session.send_message(agent_id(sess), {:park, self(), tag})

            started = await_type!(session_id, :turn_started)
            _completed = await_type!(session_id, :turn_completed)
            task = await_parked!(tag)

            assert is_binary(started.turn_id)
            {tag, started.turn_id, task}
          end

        # Phase 2 — trailing turns start AND complete while every parked delta
        # is still pending: the async-crossing pattern, present by
        # construction in every run (m5).
        trailing_turn_ids =
          for _ <- 1..n_trailing do
            :ok = Session.send_message(agent_id(sess), :noop)
            started = await_type!(session_id, :turn_started)
            _completed = await_type!(session_id, :turn_completed)
            started.turn_id
          end

        parked_ids = Enum.map(parked, fn {_, id, _} -> id end)

        assert Enum.uniq(parked_ids ++ trailing_turn_ids) ==
                 parked_ids ++ trailing_turn_ids

        # Phase 3 — release the parked tasks in a generated order; every late
        # delta must be stamped with its ORIGINATING turn's id — not a trailing
        # turn's, not another parked turn's, not nil.
        release_order = seeded_shuffle(parked, shuffle_seed)

        for {tag, turn_id, task} <- release_order do
          send(task, :release)
          delta = await_type!(session_id, :item_delta)

          assert delta.tier == :ephemeral

          assert delta_tag(delta) == tag,
                 "delta correlation broke — wrong chunk arrived"

          assert delta.turn_id == turn_id,
                 "delta for #{tag} (originating turn #{inspect(turn_id)}) was stamped " <>
                   "#{inspect(delta.turn_id)} — cross-turn contamination " <>
                   "(trailing turns: #{inspect(trailing_turn_ids)})"

          refute delta.turn_id in trailing_turn_ids
        end

        stop(sess)
        drain(session_id)
      end
    end

    test "every event in a mixed schedule carries nil or a known originating turn id — never a neighbor's" do
      session_id = "inv-turn-all-#{uniq()}"

      {:ok, sess} =
        Session.start_link(
          app_module: OverlapAgent,
          id: :"inv_turn_all_#{uniq()}",
          session_id: session_id
        )

      on_exit(fn -> stop(sess) end)
      :ok = SessionStreamer.subscribe(session_id)

      # Turn A parks; turn B runs to completion; A's delta lands afterwards.
      :ok = Session.send_message(agent_id(sess), {:park, self(), "a"})
      a_started = await_type!(session_id, :turn_started)
      _ = await_type!(session_id, :turn_completed)
      task = await_parked!("a")

      :ok = Session.send_message(agent_id(sess), :noop)
      b_started = await_type!(session_id, :turn_started)
      _ = await_type!(session_id, :turn_completed)

      send(task, :release)
      delta = await_type!(session_id, :item_delta)

      # A non-agent dispatcher event AFTER both turns closed must carry nil.
      send(dispatcher(sess), {:subscription, :tick})
      trailer = await_type!(session_id, :item_completed)

      known = %{a_started.turn_id => :a, b_started.turn_id => :b}

      assert delta.turn_id == a_started.turn_id
      assert Map.has_key?(known, delta.turn_id)

      assert is_nil(trailer.turn_id),
             "a post-turn trailer must carry nil, not a finished turn's id"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp await_type!(session_id, type) do
    receive do
      {:session_event, ^session_id, %Event{type: ^type} = ev} -> ev
      {:session_event, ^session_id, %Event{}} -> await_type!(session_id, type)
    after
      2_000 -> flunk("timed out waiting for #{inspect(type)}")
    end
  end

  defp await_parked!(tag) do
    receive do
      {:parked, ^tag, task} -> task
    after
      2_000 -> flunk("async task for #{tag} never parked")
    end
  end

  # The async chunk rides the command_result fold: payload %{message:
  # {:command_result, {:chunk, tag}}} (the ephemeral leg is not sanitized, so
  # the tuple survives intact).
  defp delta_tag(%Event{payload: %{message: {:command_result, {:chunk, tag}}}}),
    do: tag

  defp delta_tag(%Event{payload: payload}),
    do: flunk("unexpected delta payload: #{inspect(payload)}")

  defp seeded_shuffle(list, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    Enum.shuffle(list)
  end

  defp agent_id(sess) do
    %{id: id} = :sys.get_state(sess)
    id
  end

  defp dispatcher(sess) do
    %{lifecycle_pid: lifecycle_pid} = :sys.get_state(sess)

    %{dispatcher_pid: dispatcher_pid} =
      GenServer.call(lifecycle_pid, :get_full_state)

    dispatcher_pid
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp drain(session_id) do
    receive do
      {:session_event, ^session_id, _} -> drain(session_id)
    after
      0 -> :ok
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end
