defmodule Raxol.Property.ProcessIsolationTest do
  @moduledoc """
  Property tests for process crash isolation.

  Anti-pattern: using start_link to spawn child processes from a LiveView
  (or any parent that must survive child crashes). The bidirectional link
  means any child crash propagates an EXIT signal that kills the parent.

  Fix: unlink immediately after start_link, rely on Process.monitor for
  death notification.

  These tests verify the isolation invariant: for ANY crash reason,
  the parent process survives and receives the :DOWN message.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  # -- Generators --

  # Abnormal OTP exit reasons that propagate through links
  defp abnormal_reason_gen do
    one_of([
      constant(:kill),
      constant(:noproc),
      constant({:shutdown, :timeout}),
      constant({:error, :badarg}),
      constant({:error, :nxdomain}),
      map(atom(:alphanumeric), fn a -> {:exit, a} end),
      map(string(:alphanumeric, min_length: 1, max_length: 10), fn s ->
        {:raise, s}
      end)
    ])
  end

  # All exit reasons including normal/shutdown (which don't propagate)
  defp any_reason_gen do
    one_of([
      constant(:normal),
      constant(:shutdown),
      constant({:shutdown, :done}),
      abnormal_reason_gen()
    ])
  end

  # -- Helpers --

  # Starts a child using the correct pattern (start_link + unlink + monitor).
  defp start_isolated_child(crash_after_ms \\ 10) do
    {:ok, pid} =
      GenServer.start_link(__MODULE__.CrashableChild, crash_after_ms)

    Process.unlink(pid)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp crash_child(pid, reason) do
    send(pid, {:crash, reason})
  end

  defp await_down(ref, timeout \\ 500) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> {:ok, reason}
    after
      timeout -> :timeout
    end
  end

  # -- CrashableChild GenServer --

  defmodule CrashableChild do
    @moduledoc false
    use GenServer

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def handle_info({:crash, reason}, state) do
      do_crash(reason)
      {:noreply, state}
    end

    defp do_crash(:normal), do: exit(:normal)
    defp do_crash(:shutdown), do: exit(:shutdown)
    defp do_crash(:kill), do: Process.exit(self(), :kill)
    defp do_crash({:shutdown, reason}), do: exit({:shutdown, reason})
    defp do_crash({:raise, msg}), do: raise(RuntimeError, msg)
    defp do_crash({:exit, reason}), do: exit(reason)
    defp do_crash({:error, reason}), do: exit({:error, reason})
    defp do_crash(reason), do: exit(reason)
  end

  # -- Properties --

  describe "crash isolation invariant" do
    property "parent survives child crash for any exit reason" do
      check all(reason <- any_reason_gen(), max_runs: 200) do
        {pid, ref} = start_isolated_child()
        crash_child(pid, reason)

        # Wait for child to die
        assert {:ok, _} = await_down(ref),
               "child should exit for reason #{inspect(reason)}"

        # The whole point: parent is still alive
        assert Process.alive?(self()),
               "parent must survive child crash with reason #{inspect(reason)}"
      end
    end

    property ":DOWN reason matches crash reason" do
      check all(reason <- abnormal_reason_gen(), max_runs: 200) do
        {pid, ref} = start_isolated_child()
        crash_child(pid, reason)

        {:ok, down_reason} = await_down(ref)

        case reason do
          :kill ->
            assert down_reason == :killed

          {:raise, msg} ->
            # Raised exceptions become {%RuntimeError{}, stacktrace}
            assert match?({%RuntimeError{message: ^msg}, _}, down_reason)

          {:exit, r} ->
            assert down_reason == r

          {:error, r} ->
            assert down_reason == {:error, r}

          {:shutdown, r} ->
            assert down_reason == {:shutdown, r}

          other ->
            assert down_reason == other
        end
      end
    end

    @tag capture_log: true
    property "multiple concurrent child crashes don't kill parent" do
      check all(
              reasons <-
                list_of(abnormal_reason_gen(), min_length: 2, max_length: 10),
              max_runs: 100
            ) do
        children =
          Enum.map(reasons, fn _reason ->
            start_isolated_child()
          end)

        # Crash them all at once
        Enum.zip(children, reasons)
        |> Enum.each(fn {{pid, _ref}, reason} ->
          crash_child(pid, reason)
        end)

        # Wait for every child's :DOWN message. Use a generous timeout to
        # absorb scheduler jitter when up to 10 crash reports land in Logger
        # simultaneously on a loaded CI runner.
        for {_pid, ref} <- children do
          assert {:ok, _} = await_down(ref, 2_000)
        end

        # Parent alive, all children dead
        assert Process.alive?(self())

        for {pid, _ref} <- children do
          refute Process.alive?(pid)
        end
      end
    end
  end

  describe "anti-pattern detection" do
    property "linked child with abnormal exit kills parent (proves the bug)" do
      # Demonstrates that WITHOUT unlink, the parent dies.
      # We run in a spawned process to protect the test runner.
      check all(reason <- abnormal_reason_gen(), max_runs: 50) do
        test_pid = self()

        spawn(fn ->
          # This "victim" uses start_link WITHOUT unlink (the anti-pattern)
          {:ok, child} = GenServer.start_link(__MODULE__.CrashableChild, nil)
          Process.monitor(child)
          victim_pid = self()

          # Spawn a watcher to report whether victim survives
          spawn(fn ->
            ref = Process.monitor(victim_pid)

            receive do
              {:DOWN, ^ref, :process, ^victim_pid, _} ->
                send(test_pid, {:victim_status, :died})
            after
              1_000 -> send(test_pid, {:victim_status, :survived})
            end
          end)

          # Crash the child -- the link should kill us
          send(child, {:crash, reason})
          Process.sleep(500)
          send(test_pid, {:victim_status, :survived})
        end)

        result =
          receive do
            {:victim_status, status} -> status
          after
            2_000 -> :timeout
          end

        assert result == :died,
               "linked child crash (#{inspect(reason)}) must kill parent -- " <>
                 "this proves the anti-pattern is dangerous"
      end
    end
  end

  describe "source code guards" do
    @guarded_files [
      {"web/lib/raxol_playground_web/live/playground/demo_lifecycle.ex",
       "Process.unlink(pid)"},
      {"packages/raxol_agent/lib/raxol/agent/session.ex",
       "Process.unlink(lifecycle_pid)"},
      {"packages/raxol_terminal/lib/raxol/terminal/emulator/constructors.ex",
       "Process.unlink(pid)"},
      {"lib/raxol/core/runtime/subscription.ex", "Process.unlink(pid)"},
      {"packages/raxol_terminal/lib/raxol/terminal/io/io_server.ex",
       "Process.unlink(renderer)"}
    ]

    for {file, pattern} <- @guarded_files do
      test "#{Path.basename(file)} contains #{pattern}" do
        path = Path.join([__DIR__, "../..", unquote(file)])

        if File.exists?(path) do
          source = File.read!(path)

          assert source =~ unquote(pattern),
                 "#{unquote(file)} must contain #{unquote(pattern)} " <>
                   "to prevent crash propagation through process links"
        end
      end
    end
  end
end
