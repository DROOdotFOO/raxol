defmodule Raxol.System.Updater.StateTest do
  # The updater state server is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.System.Updater.State
  alias Raxol.System.Updater.State.UpdaterServer

  # A server left running by an earlier test would hide an unnamed start.
  setup do
    if pid = Process.whereis(UpdaterServer), do: GenServer.stop(pid)
    :ok
  end

  describe "server naming" do
    # Only in-memory calls: starting the server reads (never writes) the
    # settings, history and stats files under ~/.raxol.
    test "the public API starts and reaches the server on first use" do
      assert :ok = State.set_update_progress(42)
      assert State.get_update_progress() == 42

      GenServer.stop(UpdaterServer)
    end
  end
end
