# Journals default to ~/.raxol/sessions. Redirect them to a throwaway tmp dir
# for the whole run so a test never writes into the real home directory.
unless System.get_env("RAXOL_SESSIONS_DIR") do
  sessions_dir =
    Path.join(
      System.tmp_dir!(),
      "raxol_journal_test_sessions_#{System.unique_integer([:positive])}"
    )

  File.mkdir_p!(sessions_dir)
  System.put_env("RAXOL_SESSIONS_DIR", sessions_dir)
  System.at_exit(fn _ -> File.rm_rf(sessions_dir) end)
end

# The fault-injection harness lives under test/invariants/, outside
# elixirc_paths: load it explicitly.
Code.require_file("invariants/support/fault_journal.ex", __DIR__)

# POSIX modes, uids and the writer lock's `kill` and `ps` have no Windows form.
os_excludes =
  case :os.type() do
    {:win32, _} -> [:unix_only]
    _ -> []
  end

ExUnit.start(exclude: [:slow | os_excludes])
