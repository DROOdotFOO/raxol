# The teardown helper the end-to-end tests hang their `on_exit` on. It gets its
# own tests because the thing it replaced was an inverted assertion that passed
# only in the race where cleanup had FAILED, and the way that surfaced -- a red
# X on an unrelated PR, reported at a line inside a callback -- is expensive
# enough to be worth pinning both directions of.
defmodule Raxol.AgentClientProtocol.TeardownTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Test.Teardown

  # Unlinked, because these supervisors are the SUBJECT. Left linked, the test
  # process would take them down on the way out and every assertion below would
  # pass on the link rather than on the helper. `on_exit` reaps whatever a
  # failing test leaves behind, since nothing else now will.
  defp start_sup(children \\ []) do
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(sup)
    on_exit(fn -> Process.exit(sup, :kill) end)
    sup
  end

  defp await_death(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  describe "stop_quietly/1" do
    # The case the old `catch_exit(Supervisor.stop(...))` FAILED on: cleanup
    # worked, `Supervisor.stop` returned `:ok`, there was no exit to catch, and
    # ExUnit reported "Expected to catch exit, got nothing".
    test "returns :ok for a supervisor that is still alive" do
      sup = start_sup()

      assert Teardown.stop_quietly(sup) == :ok
      refute Process.alive?(sup)
    end

    # The case it passed on, and the reason the inversion went unnoticed: the
    # supervisors are linked to the test process, so by the time `on_exit` runs
    # they are usually already gone.
    test "returns :ok for a supervisor that is already dead" do
      sup = start_sup()
      Supervisor.stop(sup, :normal, 500)
      await_death(sup)

      assert Teardown.stop_quietly(sup) == :ok
    end

    test "returns :ok for a name that was never registered" do
      assert Teardown.stop_quietly(:no_such_supervisor_registered) == :ok
    end

    # The reason this waits on a monitor instead of enumerating exit reasons.
    # A supervisor whose child blocks in `terminate/2` makes `Supervisor.stop`
    # exit with a NESTED reason (`GenServer.stop` around `:sys.terminate`
    # around `shutdown`), and which layer arrives depends on how far the
    # shutdown had already got. The helper must be gone-or-killed either way.
    test "kills a supervisor that will not shut down inside the budget" do
      sup = start_sup([{__MODULE__.Wedged, []}])

      assert Teardown.stop_quietly(sup) == :ok
      refute Process.alive?(sup)
    end
  end

  describe "stop_all/1" do
    test "stops every supervisor and does not give up at the first dead one" do
      alive = start_sup()
      dead = start_sup()
      Supervisor.stop(dead, :normal, 500)
      await_death(dead)

      # Dead one FIRST: an implementation that let the exit escape would never
      # reach the live one, and that leak only shows up later, as an unrelated
      # test inheriting a supervisor it never started.
      assert Teardown.stop_all([dead, alive]) == :ok
      refute Process.alive?(alive)
    end

    test "accepts an empty list" do
      assert Teardown.stop_all([]) == :ok
    end
  end

  # Traps exits and never finishes terminating, so its supervisor cannot honour
  # an orderly stop. `:infinity` shutdown means the supervisor waits on it.
  defmodule Wedged do
    @moduledoc false
    use GenServer, shutdown: :infinity

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl GenServer
    def init(:ok) do
      Process.flag(:trap_exit, true)
      {:ok, :ok}
    end

    @impl GenServer
    def terminate(_reason, _state), do: Process.sleep(:infinity)
  end
end
