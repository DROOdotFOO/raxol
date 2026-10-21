defmodule Raxol.Recording.RecorderTest do
  use ExUnit.Case, async: false

  alias Raxol.Recording.Recorder

  setup do
    on_exit(fn ->
      try do
        Recorder.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # The registered recorder receives every frame and keystroke any live Raxol
  # session in the VM produces (`Rendering.Backends`, `DispatcherHooks`), so a
  # session another test left running adds events to it. Tests that count
  # events use an unregistered recorder only they can reach; the registration
  # behaviour itself is covered by the start_link/active?/stop tests.
  defp start_unregistered(opts \\ []) do
    GenServer.start_link(Recorder, opts)
  end

  describe "start_link/1" do
    test "starts and registers the recorder" do
      {:ok, pid} = Recorder.start_link(title: "Test")
      assert Process.alive?(pid)
      assert Process.whereis(Raxol.Recording.Recorder) == pid
    end
  end

  describe "active?/0" do
    test "returns false when no recorder is running" do
      refute Recorder.active?()
    end

    test "returns true when recorder is running" do
      {:ok, _pid} = Recorder.start_link()
      assert Recorder.active?()
    end
  end

  describe "record_output/2" do
    test "accumulates output events" do
      {:ok, pid} = start_unregistered()

      Recorder.record_output(pid, "frame 1")
      Recorder.record_output(pid, "frame 2")
      Recorder.record_output(pid, "frame 3")

      session = Recorder.get_session(pid)
      assert length(session.events) == 3

      texts = Enum.map(session.events, fn {_t, _type, data} -> data end)
      assert texts == ["frame 1", "frame 2", "frame 3"]
    end

    test "events have increasing timestamps" do
      {:ok, pid} = start_unregistered()

      Recorder.record_output(pid, "a")
      Process.sleep(10)
      Recorder.record_output(pid, "b")

      session = Recorder.get_session(pid)
      [{t1, _, _}, {t2, _, _}] = session.events
      assert t2 > t1
    end

    test "events are tagged as output" do
      {:ok, pid} = start_unregistered()

      Recorder.record_output(pid, "test")

      session = Recorder.get_session(pid)
      [{_, type, _}] = session.events
      assert type == :output
    end
  end

  describe "record_input/2" do
    test "accumulates input events" do
      {:ok, pid} = start_unregistered()

      Recorder.record_input(pid, "a")
      Recorder.record_input(pid, "b")

      session = Recorder.get_session(pid)
      assert length(session.events) == 2

      types = Enum.map(session.events, fn {_t, type, _data} -> type end)
      assert types == [:input, :input]
    end

    test "interleaves with output events in order" do
      {:ok, pid} = start_unregistered()

      Recorder.record_output(pid, "frame 1")
      Process.sleep(1)
      Recorder.record_input(pid, "key")
      Process.sleep(1)
      Recorder.record_output(pid, "frame 2")

      session = Recorder.get_session(pid)
      types = Enum.map(session.events, fn {_t, type, _data} -> type end)
      assert types == [:output, :input, :output]
    end
  end

  describe "stop/1" do
    test "returns completed session with ended_at" do
      {:ok, pid} = start_unregistered(title: "Stop Test")
      Recorder.record_output(pid, "data")

      session = Recorder.stop(pid)
      assert session.ended_at != nil
      assert session.title == "Stop Test"
      assert length(session.events) == 1
    end

    test "unregisters the recorder" do
      {:ok, pid} = Recorder.start_link()
      ref = Process.monitor(pid)
      Recorder.stop()
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute Recorder.active?()
    end
  end

  describe "auto_save" do
    @tag :tmp_dir
    test "writes file on stop", %{tmp_dir: dir} do
      path = Path.join(dir, "auto.cast")
      {:ok, _pid} = Recorder.start_link(auto_save: path)
      Recorder.record_output("hello")

      Recorder.stop()

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "hello"
    end

    @tag :tmp_dir
    test "flush writes partial session to disk", %{tmp_dir: dir} do
      path = Path.join(dir, "flush.cast")
      {:ok, pid} = Recorder.start_link(auto_save: path)
      Recorder.record_output("partial")

      # Trigger flush manually
      send(pid, :flush)
      # Sync with genserver to ensure flush processed
      _ = Recorder.get_session()

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "partial"
    end

    @tag :tmp_dir
    test "terminate flushes to disk", %{tmp_dir: dir} do
      path = Path.join(dir, "terminate.cast")
      {:ok, pid} = Recorder.start_link(auto_save: path)
      Recorder.record_output("crash data")

      # Unlink so :shutdown doesn't kill the test process
      Process.unlink(pid)
      GenServer.stop(pid, :shutdown)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "crash data"
    end
  end
end
