defmodule Raxol.Harness.LiveAssemblyTest do
  @moduledoc """
  U6-c, end to end: `Raxol.Harness.Live` boots SessionPump +
  Lifecycle(environment: :harness) running HarnessApp against a scripted
  fake lane, with frames captured through the `:io_writer` seam and the
  pump's own bytes on a StringIO device. What is pinned here is the
  WIRING, not the rendering (each has its own suite):

    * alt-screen enter lands on the device BEFORE any frame byte
      (PumpContract §7's byte law, across the whole assembly);
    * a lane event flows forwarder -> boundary -> cadence -> pump ->
      shim -> Dispatcher -> `HarnessApp.update/2` -> frame (the full
      live path the migration was for);
    * a keystroke flows pump -> shim -> Dispatcher -> the model's
      composer draft (the input half of the same loop);
    * `stop/1` leaves the alt screen as the session's LAST byte and
      stops the Lifecycle (PumpContract §8).
  """

  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Lifecycle
  alias Raxol.Harness.Live
  alias Raxol.Harness.SessionPump
  alias Raxol.UI.Rendering.PaintAuthority.ViewportAuthority

  defmodule FakeLane do
    @moduledoc false
    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(%{test: test_pid}) do
      send(test_pid, {:subscribed, self()})
      :ok
    end

    @impl true
    def submit(%{test: test_pid}, request) do
      send(test_pid, {:submit_dispatched, request})
      :ok
    end

    @impl true
    def interrupt(%{test: test_pid}, payload) do
      send(test_pid, {:interrupt_dispatched, payload})
      :ok
    end

    @impl true
    def steer(%{test: test_pid}, _request) do
      send(test_pid, :steer_dispatched)
      {:error, :no_live_turn}
    end

    @impl true
    def answer_permission(%{test: test_pid}, answer) do
      send(test_pid, {:approval_answered, answer})
      :ok
    end

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  defp message_turn_events(content) do
    [
      %{id: 1, turn_id: "t1", ts: 1_000, family: :loop, type: :turn_started,
        tier: :durable, payload: %{prompt: "hi"}},
      %{id: 2, turn_id: "t1", ts: 1_100, family: :loop, type: :item_started,
        tier: :durable, payload: %{item_id: "i1", item_type: :message}},
      %{id: 3, turn_id: "t1", ts: 1_200, family: :loop, type: :item_completed,
        tier: :durable,
        payload: %{item_id: "i1", item_type: :message, content: content}},
      %{id: 4, turn_id: "t1", ts: 1_300, family: :loop, type: :turn_completed,
        tier: :durable, payload: %{iteration: 1, usage: %{}, final: true}}
    ]
  end

  defp boot_live do
    test_pid = self()
    {:ok, device} = StringIO.open("")
    {:ok, fake_session} = Agent.start(fn -> nil end)

    writer = fn bytes ->
      send(test_pid, {:frame, IO.iodata_to_binary(bytes)})
    end

    handle =
      Live.start_link(
        lane: {FakeLane, %{session_id: "s1", pid: fake_session, test: test_pid}},
        device: device,
        io_writer: writer,
        greeting?: false,
        width: 60,
        rows: 20,
        cadence_opts: [flush_interval_ms: 0],
        tick_ms: 60_000,
        sigwinch?: false,
        notify: test_pid
      )

    assert_receive {:subscribed, forwarder}, 2_000
    {handle, device, forwarder}
  end

  # Frames arrive one per coalesced paint; the one carrying `marker` is
  # proof the fold happened first (the Engine paints the post-fold model).
  defp await_frame(marker, timeout \\ 2_000) do
    receive do
      {:frame, bytes} ->
        if bytes =~ marker do
          bytes
        else
          await_frame(marker, timeout)
        end
    after
      timeout -> flunk("no frame carrying #{inspect(marker)} within #{timeout}ms")
    end
  end

  test "boot enters the alt screen BEFORE the first frame byte" do
    {{:ok, _handle}, device, _forwarder} = boot_live()

    {_in, out} = StringIO.contents(device)
    assert String.ends_with?(out, ViewportAuthority.enter())
  end

  test "a lane event folds through the whole assembly and paints a frame" do
    {{:ok, %{lifecycle: lifecycle}}, _device, forwarder} = boot_live()

    Enum.each(
      message_turn_events("LIVE-FOLD-MARKER"),
      &send(forwarder, {:session_event, "s1", &1})
    )

    frame = await_frame("LIVE-FOLD-MARKER")
    assert is_binary(frame)

    # And the fold really happened in the app model (not only in paint):
    # the sealed turn sits in the transcript records.
    %{dispatcher: dispatcher} = Lifecycle.child_pids(lifecycle)
    {:ok, model} = GenServer.call(dispatcher, :get_model)
    assert model.transcript_records != []
  end

  test "a keystroke reaches the model's composer through the shim" do
    {{:ok, %{lifecycle: lifecycle, pump: pump}}, _device, _forwarder} = boot_live()

    send(pump, {:inline_input, Event.key("x")})

    # The frame carrying the typed character is the fold-happened proof.
    await_frame("x")

    %{dispatcher: dispatcher} = Lifecycle.child_pids(lifecycle)
    {:ok, model} = GenServer.call(dispatcher, :get_model)

    assert Raxol.UI.Components.Harness.Composer.value(model.composer) =~ "x"
  end

  test "stop/1 leaves the alt screen as the last byte and stops the lifecycle" do
    {{:ok, %{pump: pump, lifecycle: lifecycle} = handle}, device, _forwarder} =
      boot_live()

    ref = Process.monitor(lifecycle)
    Live.stop(handle)

    assert_receive {:session_pump, ^pump, :halted}, 2_000

    {_in, out} = StringIO.contents(device)
    assert String.ends_with?(out, ViewportAuthority.leave())

    assert_receive {:DOWN, ^ref, :process, ^lifecycle, _reason}, 5_000
  end

  test "a submit directive round-trips to the lane and its result folds back" do
    {{:ok, %{pump: pump}}, _device, _forwarder} = boot_live()

    # Type a draft, then submit it with Enter: update/2 mints the Lane
    # directive, the pump performs the lane call, and the result message
    # folds back through the shim.
    send(pump, {:inline_input, Event.key("h")})
    send(pump, {:inline_input, Event.key("i")})
    send(pump, {:inline_input, Event.key_event(:enter, :pressed, [])})

    assert_receive {:submit_dispatched, %{text: "hi"}}, 2_000
  end

  # -- U6-e: the ordering residual, made real --------------------------------

  # The contract's honest residual (PumpContract §2): one FIFO segment
  # remains INSIDE the Dispatcher -- a keystroke forwarded BEHIND an
  # already-forwarded batch waits one update/2 fold. The pump-seam half
  # (input enters ahead of anything pending WITH it) is the A0 falsifier
  # in pump_contract_test.exs; this is the end-to-end half over the
  # assembled stack. Construction: a :sys.suspend wedge on the Dispatcher
  # lets the exact mailbox order [batch1, key, batch2] be built
  # deterministically through the REAL pump+shim path; the time-travel
  # recorder then proves the fold order: the key folds immediately after
  # the batch that beat it and before the batch that followed it --
  # exactly one fold of waiting, never more.
  test "U6-e: a key forwarded behind an already-forwarded batch waits exactly one fold" do
    test_pid = self()
    {:ok, device} = StringIO.open("")
    {:ok, fake_session} = Agent.start(fn -> nil end)

    writer = fn bytes -> send(test_pid, {:frame, IO.iodata_to_binary(bytes)}) end

    {:ok, %{pump: pump, lifecycle: lifecycle}} =
      Live.start_link(
        lane: {FakeLane, %{session_id: "s1", pid: fake_session, test: test_pid}},
        device: device,
        io_writer: writer,
        greeting?: false,
        width: 60,
        rows: 20,
        cadence_opts: [flush_interval_ms: 0],
        tick_ms: 60_000,
        sigwinch?: false,
        time_travel: true,
        notify: test_pid
      )

    assert_receive {:subscribed, forwarder}, 2_000
    %{dispatcher: dispatcher} = Lifecycle.child_pids(lifecycle)
    Raxol.Debug.TimeTravel.clear()

    # Wedge the Dispatcher so queue construction is exact: every cast the
    # shim sends just accumulates until we choose the fold order.
    :sys.suspend(dispatcher)

    enqueue = fn send_fun, want_len ->
      send_fun.()

      # Poll the mailbox, not a sleep: the assertion is about what ARRIVED,
      # so wait until the shim's cast is provably queued.
      wait_until(
        fn ->
          {:message_queue_len, n} = Process.info(dispatcher, :message_queue_len)
          n >= want_len
        end,
        2_000,
        "dispatcher mailbox never reached length #{want_len}"
      )
    end

    # batch1 is "already forwarded" before the key exists at the pump: the
    # residual's only legal waiter.
    enqueue.(
      fn -> send(forwarder, {:session_event, "s1", turn_event(1, "t1", :turn_started)}) end,
      1
    )

    enqueue.(fn -> send(pump, {:inline_input, Event.key("z")}) end, 2)

    enqueue.(
      fn -> send(forwarder, {:session_event, "s1", turn_event(2, "t2", :turn_started)}) end,
      3
    )

    :sys.resume(dispatcher)

    # Three folds land; the recorder sees them all.
    wait_until(fn -> Raxol.Debug.TimeTravel.count() >= 3 end, 2_000, "folds not recorded")

    # The pump's stall mechanics interleave a verdict per batch (pump-side
    # data, not stream content) -- the ordering claim is about stream
    # messages, so verdicts are filtered out of the sequence.
    messages =
      for i <- 0..(Raxol.Debug.TimeTravel.count() - 1) do
        {:ok, snap} = Raxol.Debug.TimeTravel.jump_to(i)
        snap.message
      end
      |> Enum.reject(&match?({:stall_verdict, _}, &1))

    assert [
             {:batch, _},
             {:key, %{char: "z"}},
             {:batch, _}
           ] = Enum.take(messages, 3)
  end

  defp turn_event(id, turn_id, type) do
    %{
      id: id,
      turn_id: turn_id,
      ts: id * 1_000,
      family: :loop,
      type: type,
      tier: :durable,
      payload: %{}
    }
  end

  defp wait_until(predicate, timeout, error) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(predicate, deadline, error)
  end

  defp do_wait_until(predicate, deadline, error) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(error)

      true ->
        Process.sleep(5)
        do_wait_until(predicate, deadline, error)
    end
  end
end
