defmodule Raxol.Core.Runtime.Rendering.EngineProcessComponentsTest do
  @moduledoc """
  The rendering engine runs each `process_component` node of a view in a
  process under `Raxol.DynamicSupervisor` (#1132). It used to start a new
  one on every frame and never stop any, so a view with one such node grew
  a process per frame and the component's state never outlived a frame.

  A component's `init/1` runs after its process has started, so the frame
  that starts it draws a `starting` placeholder and the component tells the
  engine when it is ready. One that exits is drawn as a placeholder and
  restarted after a run of frames that doubles with each failure in a row,
  not on the very next frame.

  Views render through headless sessions, each with its own engine, and the
  component announces to the test every process it starts in.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Core.Renderer.View
  alias Raxol.Core.Runtime.ProcessComponent
  alias Raxol.Headless

  defmodule Counter do
    @moduledoc false

    def init(%{test: test, label: label}) do
      send(test, {:started, label, self()})
      {:ok, %{label: label, count: 0, broken: false}}
    end

    def update(:increment, state), do: %{state | count: state.count + 1}
    def update(:break, state), do: %{state | broken: true}
    def update_props(props, state), do: %{state | label: props.label}

    def render(%{broken: true}, _context), do: raise("render failed")

    def render(state, _context),
      do: %{type: :text, content: "#{state.label}=#{state.count}", style: %{}}
  end

  # Like the FileListWidget example: update/2 handles its own messages only,
  # and it has no update_props/2.
  defmodule Refresher do
    @moduledoc false

    def init(%{test: test, label: label}) do
      send(test, {:initialised, label, self()})
      {:ok, %{label: label, count: 0}}
    end

    def update(:increment, state), do: %{state | count: state.count + 1}

    def render(state, _context),
      do: %{type: :text, content: "#{state.label}~#{state.count}", style: %{}}
  end

  # Its init waits until the test lets it go.
  defmodule Slow do
    @moduledoc false

    def init(%{test: test, label: label}) do
      send(test, {:started, label, self()})

      receive do
        :go -> {:ok, %{label: label}}
      end
    end

    def render(state, _context),
      do: %{type: :text, content: "#{state.label} ready", style: %{}}
  end

  # Its init always fails.
  defmodule Failing do
    @moduledoc false

    def init(%{test: test, label: label}) do
      send(test, {:started, label, self()})
      {:error, :nope}
    end

    def render(_state, _context), do: %{type: :text, content: "?", style: %{}}
  end

  defmodule ShowApp do
    @moduledoc false
    # Its model is the view it shows.
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: text("")

    @impl true
    def update({:show, view}, _shown), do: {view, []}
    def update(_message, shown), do: {shown, []}

    @impl true
    def view(shown), do: shown
  end

  setup do
    case Process.whereis(Headless) do
      nil -> start_supervised!({Headless, [name: Headless]})
      _pid -> :ok
    end

    :ok
  end

  describe "a process_component node" do
    test "runs in one supervised process however many frames are drawn" do
      before = supervised_pids()

      with_session(counter("a"), fn id ->
        for _ <- 1..5, do: frame(id)

        assert_received {:started, "a", pid}
        refute_received {:started, _, _}
        assert supervised_pids() -- before == [pid]
      end)
    end

    test "is drawn as starting until its init has run, then as its tree" do
      slow = View.process_component(Slow, %{test: self(), label: "s"})

      with_session(View.column(children: [slow, View.text("rest")]), fn id ->
        screen = frame(id)
        assert screen =~ "[pc-#{inspect(Slow)}: starting]"
        assert screen =~ "rest"
        assert_receive {:started, "s", pid}

        # Still in init: another frame neither waits on it nor starts a second.
        assert frame(id) =~ "starting"
        refute_received {:started, _, _}

        send(pid, :go)
        ready(pid)

        assert frame(id) =~ "s ready"
      end)
    end

    test "keeps its state across frames" do
      with_session(counter("a"), fn id ->
        frame(id)
        pid = started(id, "a")

        assert frame(id) =~ "a=0"
        :ok = ProcessComponent.send_update(pid, :increment)

        assert frame(id) =~ "a=1"
        assert frame(id) =~ "a=1"
      end)
    end

    test "gives same-module siblings a process each" do
      with_session(View.column(children: [counter("a"), counter("b")]), fn id ->
        frame(id)
        a = started(id, "a")
        _b = started(id, "b")

        :ok = ProcessComponent.send_update(a, :increment)
        screen = frame(id)

        assert screen =~ "a=1"
        assert screen =~ "b=0"
        refute_received {:started, _, _}
      end)
    end

    test "passes changed props to update_props/2, keeping the rest of its state" do
      with_session(counter("a"), fn id ->
        frame(id)
        pid = started(id, "a")
        :ok = ProcessComponent.send_update(pid, :increment)

        :ok = Headless.send_message(id, {:show, counter("b")})

        assert frame(id) =~ "b=1"
        refute_received {:started, _, _}
      end)
    end

    test "without update_props/2 re-initialises from changed props, in its process" do
      refresher = &View.process_component(Refresher, %{test: self(), label: &1})

      with_session(refresher.("a"), fn id ->
        frame(id)
        assert_receive {:initialised, "a", pid}
        ready(pid)
        :ok = ProcessComponent.send_update(pid, :increment)
        assert frame(id) =~ "a~1"

        :ok = Headless.send_message(id, {:show, refresher.("b")})

        screen = frame(id)
        assert screen =~ "b~0"
        refute screen =~ "crashed"
        assert_received {:initialised, "b", ^pid}
      end)
    end

    test "with an :id keeps its process when it moves in the view" do
      pinned = Map.put(counter("a"), :id, "pinned")

      with_session(View.column(children: [pinned]), fn id ->
        frame(id)
        pid = started(id, "a")
        :ok = ProcessComponent.send_update(pid, :increment)

        moved = View.column(children: [View.text("above"), pinned])
        :ok = Headless.send_message(id, {:show, moved})

        assert frame(id) =~ "a=1"
        refute_received {:started, _, _}
      end)
    end

    test "stops its process once the view no longer has it" do
      with_session(counter("a"), fn id ->
        frame(id)
        pid = started(id, "a")
        ref = Process.monitor(pid)

        :ok = Headless.send_message(id, {:show, View.text("gone")})

        assert frame(id) =~ "gone"
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)
    end

    test "stops its process when the session stops" do
      with_session(counter("a"), fn id ->
        frame(id)
        pid = started(id, "a")
        ref = Process.monitor(pid)

        :ok = Headless.stop(id)

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)
    end

    test "that crashes draws a placeholder, sits out a frame, then restarts" do
      view = View.column(children: [counter("a"), View.text("rest")])

      with_session(view, fn id ->
        frame(id)
        pid = started(id, "a")
        ref = Process.monitor(pid)
        :ok = ProcessComponent.send_update(pid, :break)

        capture_log(fn ->
          screen = frame(id)
          assert screen =~ "rest"
          assert screen =~ "[pc-#{inspect(Counter)}: crashed]"
          refute screen =~ "a="
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

          assert frame(id) =~ "crashed"
          refute_received {:started, _, _}

          assert frame(id) =~ "starting"
        end)

        restarted = started(id, "a")
        assert restarted != pid
        assert frame(id) =~ "a=0"
      end)
    end

    test "that fails in init is retried after 1, 2, 4, 8 ... frames" do
      with_session(failing("f"), fn id ->
        capture_log(fn ->
          assert start_frames(id, "f", 20) == [1, 3, 6, 11, 20]
        end)
      end)
    end

    test "that comes up again starts its backoff over" do
      with_session(counter("a"), fn id ->
        frame(id)
        pid = started(id, "a")

        capture_log(fn ->
          crash_and_restart(id, pid)
          # Had the first failure still counted, this would sit out two frames.
          restarted = started(id, "a")
          crash_and_restart(id, restarted)
          assert started(id, "a") != restarted
        end)
      end)
    end

    test "that leaves the view while sitting out its frames is forgotten" do
      with_session(failing("f"), fn id ->
        capture_log(fn ->
          # Two failures in a row: the second has it sitting out two frames.
          assert start_frames(id, "f", 4) == [1, 3]

          :ok = Headless.send_message(id, {:show, View.text("gone")})
          assert frame(id) =~ "gone"

          # Brought back, it starts at once rather than sitting out the rest.
          :ok = Headless.send_message(id, {:show, failing("f")})
          assert frame(id) =~ "starting"
          assert_receive {:started, "f", _pid}
        end)
      end)
    end
  end

  describe "two sessions of the same view" do
    test "run separate processes, and stopping one leaves the other's" do
      with_session(counter("a"), fn first ->
        frame(first)
        ours = started(first, "a")

        with_session(counter("a"), fn second ->
          frame(second)
          theirs = started(second, "a")
          assert theirs != ours

          :ok = ProcessComponent.send_update(ours, :increment)
          assert frame(first) =~ "a=1"
          assert frame(second) =~ "a=0"

          ref = Process.monitor(ours)
          :ok = Headless.stop(first)
          assert_receive {:DOWN, ^ref, :process, ^ours, _reason}

          assert frame(second) =~ "a=0"
          refute_received {:started, _, _}
        end)
      end)
    end
  end

  defp counter(label),
    do: View.process_component(Counter, %{test: self(), label: label})

  defp failing(label),
    do: View.process_component(Failing, %{test: self(), label: label})

  # The component's process once it has started, after its init and mount
  # have run: the component has sent the engine its ready message by then,
  # which is queued there ahead of the frame asked for here. The engine
  # answers the ready message by asking itself for a frame, queued behind
  # this one; so the test's next frame is the one after that, and the frame
  # counts of the tests below stand.
  defp started(id, label) do
    assert_receive {:started, ^label, pid}
    ready(pid)
    frame(id)
    pid
  end

  defp ready(pid), do: :sys.get_state(pid)

  # Breaks the component, draws its crash and the one frame it sits out, and
  # the frame that starts it afresh.
  defp crash_and_restart(id, pid) do
    ref = Process.monitor(pid)
    :ok = ProcessComponent.send_update(pid, :break)

    assert frame(id) =~ "crashed"
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert frame(id) =~ "crashed"
    assert frame(id) =~ "starting"
  end

  # Draws `frames` frames of a component whose init fails and returns the
  # numbers of the frames that started it. Each start is seen to its end
  # before the next frame, so each frame's count is settled.
  defp start_frames(id, label, frames) do
    Enum.flat_map(1..frames, fn n ->
      screen = frame(id)

      if screen =~ "starting" do
        assert_receive {:started, ^label, pid}
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        [n]
      else
        assert screen =~ "[pc-#{inspect(Failing)}: failed to start]"
        []
      end
    end)
  end

  defp with_session(view, fun) do
    id = :"engine_process_components_#{System.unique_integer([:positive])}"
    {:ok, ^id} = Headless.start(ShowApp, id: id, width: 100, height: 8)

    try do
      :ok = Headless.send_message(id, {:show, view})
      fun.(id)
    after
      Headless.stop(id)
    end
  end

  # A synchronous frame: the engine renders the current model before the
  # screenshot is taken.
  defp frame(id) do
    {:ok, screen} = Headless.screenshot(id)
    screen
  end

  defp supervised_pids do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Raxol.DynamicSupervisor),
        is_pid(pid),
        do: pid
  end
end
