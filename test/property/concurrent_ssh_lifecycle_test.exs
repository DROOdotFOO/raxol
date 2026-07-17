defmodule Raxol.Property.ConcurrentSshLifecycleTest do
  @moduledoc """
  Regression: issue #228.

  `Raxol.Core.Runtime.Lifecycle.Initializer.start_dispatcher/5` registered the
  Dispatcher with `name: __MODULE__` for every environment except `:agent` and
  `:liveview`. The `:ssh` env was missed, so a second concurrent SSH session
  failed with `{:error, {:already_started, _}}`.

  Two regressions guard against this returning:

    1. Behavioural: starting N Dispatchers with `[name: nil]` succeeds and
       yields N distinct pids. Proves the underlying mechanism is sound.

    2. Source guard: the initializer's env list contains `:ssh`. Proves the
       wire-up that uses [name: nil] for the SSH env stays in place.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Events.Dispatcher

  defmodule TestApp do
    @moduledoc false
    def init(_), do: {:ok, %{}}
    def update(_, model), do: {model, []}
    def view(_), do: %{type: :text, content: ""}
  end

  defp dispatcher_initial_state do
    %{
      app_module: TestApp,
      model: %{},
      width: 80,
      height: 24,
      debug_mode: false,
      plugin_manager: nil,
      command_registry_table: nil,
      time_travel: nil,
      cycle_profiler: nil
    }
  end

  defp start_unnamed do
    {:ok, pid} =
      Dispatcher.start_link(self(), dispatcher_initial_state(), name: nil)

    Process.unlink(pid)
    pid
  end

  defp stop_all(pids) do
    refs = Enum.map(pids, fn pid -> {pid, Process.monitor(pid)} end)
    Enum.each(pids, &Process.exit(&1, :shutdown))

    Enum.each(refs, fn {_pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        500 -> :ok
      end
    end)
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  describe "concurrent dispatchers (regression for #228)" do
    test "four dispatchers with [name: nil] start with distinct pids" do
      pids = for _ <- 1..4, do: start_unnamed()

      assert length(pids) == 4

      assert length(Enum.uniq(pids)) == 4,
             "all dispatcher pids must be distinct"

      assert Enum.all?(pids, &Process.alive?/1)

      drain_mailbox()
      stop_all(pids)
    end
  end

  describe "source guard for #228" do
    @initializer_path Path.join([
                        __DIR__,
                        "../..",
                        "lib/raxol/core/runtime/lifecycle/initializer.ex"
                      ])

    test "Initializer dispatcher_opts list includes :ssh" do
      source = File.read!(@initializer_path)

      # Membership, not the exact list literal: other multi-instance
      # profiles (:harness, ...) may join the [name: nil] list; the guarded
      # invariant is only that :ssh never leaves it.
      assert source =~ ~r/environment in \[[^\]]*:ssh[^\]]*\]/,
             "initializer.ex must keep :ssh in the Dispatcher [name: nil] list. " <>
               "Without it, concurrent :ssh Lifecycles collide on the registered " <>
               "Dispatcher name (regression of #228)."
    end
  end
end
