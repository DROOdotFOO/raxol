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

  # Windows sets USERPROFILE, not HOME. The default download and backup paths
  # were built from HOME, so the server crashed in init there.
  describe "without a HOME variable" do
    setup do
      previous = System.get_env("HOME")
      System.delete_env("HOME")
      on_exit(fn -> if previous, do: System.put_env("HOME", previous) end)
    end

    test "the server still starts and answers" do
      assert :ok = State.set_update_progress(7)
      assert State.get_update_progress() == 7

      GenServer.stop(UpdaterServer)
    end

    test "default paths are rooted in the user's home directory" do
      settings = State.default_update_settings()
      home = System.user_home!()

      assert settings.download_path ==
               Path.expand(Path.join([home, ".raxol", "downloads"]))

      assert settings.backup_path ==
               Path.expand(Path.join([home, ".raxol", "backups"]))
    end
  end
end
