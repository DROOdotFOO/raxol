defmodule Raxol.Core.Runtime.Rendering.EngineProcessComponentsTest do
  @moduledoc """
  The rendering engine runs each `process_component` node of a view in a
  process under `Raxol.DynamicSupervisor` (#1132). It used to start a new
  one on every frame and never stop any, so a view with one such node grew
  a process per frame and the component's state never outlived a frame.

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
    def update({:update_props, props}, state), do: %{state | label: props.label}

    def render(%{broken: true}, _context), do: raise("render failed")

    def render(state, _context),
      do: %{type: :text, content: "#{state.label}=#{state.count}", style: %{}}
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

    test "keeps its state across frames" do
      with_session(counter("a"), fn id ->
        assert frame(id) =~ "a=0"
        assert_received {:started, "a", pid}

        :ok = ProcessComponent.send_update(pid, :increment)

        assert frame(id) =~ "a=1"
        assert frame(id) =~ "a=1"
      end)
    end

    test "gives same-module siblings a process each" do
      with_session(View.column(children: [counter("a"), counter("b")]), fn id ->
        frame(id)
        assert_received {:started, "a", a}
        assert_received {:started, "b", _b}

        :ok = ProcessComponent.send_update(a, :increment)
        screen = frame(id)

        assert screen =~ "a=1"
        assert screen =~ "b=0"
        refute_received {:started, _, _}
      end)
    end

    test "passes changed props to its running process" do
      with_session(counter("a"), fn id ->
        frame(id)
        assert_received {:started, "a", pid}
        :ok = ProcessComponent.send_update(pid, :increment)

        :ok = Headless.send_message(id, {:show, counter("b")})

        assert frame(id) =~ "b=1"
        refute_received {:started, _, _}
      end)
    end

    test "with an :id keeps its process when it moves in the view" do
      pinned = Map.put(counter("a"), :id, "pinned")

      with_session(View.column(children: [pinned]), fn id ->
        frame(id)
        assert_received {:started, "a", pid}
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
        assert_received {:started, "a", pid}
        ref = Process.monitor(pid)

        :ok = Headless.send_message(id, {:show, View.text("gone")})

        assert frame(id) =~ "gone"
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)
    end

    test "stops its process when the session stops" do
      with_session(counter("a"), fn id ->
        frame(id)
        assert_received {:started, "a", pid}
        ref = Process.monitor(pid)

        :ok = Headless.stop(id)

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)
    end

    test "that crashes draws a placeholder, and the next frame restarts it" do
      view = View.column(children: [counter("a"), View.text("rest")])

      with_session(view, fn id ->
        frame(id)
        assert_received {:started, "a", pid}
        ref = Process.monitor(pid)
        :ok = ProcessComponent.send_update(pid, :break)

        capture_log(fn ->
          screen = frame(id)
          assert screen =~ "rest"
          assert screen =~ inspect(Counter)
          refute screen =~ "a="
        end)

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        assert frame(id) =~ "a=0"
        assert_received {:started, "a", restarted}
        assert restarted != pid
      end)
    end
  end

  describe "two sessions of the same view" do
    test "run separate processes, and stopping one leaves the other's" do
      with_session(counter("a"), fn first ->
        frame(first)
        assert_received {:started, "a", ours}

        with_session(counter("a"), fn second ->
          frame(second)
          assert_received {:started, "a", theirs}
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
