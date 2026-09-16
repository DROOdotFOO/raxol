defmodule Raxol.Core.Runtime.LogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Core.Runtime.Log

  setup do
    original_level = Logger.level()
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  describe "debug/2 with a zero-arity fun message" do
    test "folds the context into the message the fun returns" do
      Logger.configure(level: :debug)

      log = capture_log(fn -> Log.debug(fn -> "x" end, %{a: 1}) end)

      assert log =~ "x | Context: %{a: 1}"
    end

    test "does not build messages in any lazy helper when debug is disabled" do
      Logger.configure(level: :error)
      parent = self()
      original_environment = Application.get_env(:raxol, :environment)
      Application.put_env(:raxol, :environment, :test)

      on_exit(fn ->
        if original_environment do
          Application.put_env(:raxol, :environment, original_environment)
        else
          Application.delete_env(:raxol, :environment)
        end
      end)

      lazy = fn name ->
        fn ->
          send(parent, {:message_built, name})
          Atom.to_string(name)
        end
      end

      Log.debug(lazy.(:with_context), %{a: 1})
      Log.debug_with_context(lazy.(:debug_with_context), %{a: 1})
      Log.module_debug(lazy.(:module_log), %{a: 1})
      assert :timed == Log.time_debug(lazy.(:time_log), fn -> :timed end)
      Log.console(lazy.(:console), %{a: 1})

      refute_received {:message_built, _}
    end

    test "renders lazy messages through context, module, timing, and console helpers" do
      Logger.configure(level: :debug)
      original_environment = Application.get_env(:raxol, :environment)
      Application.put_env(:raxol, :environment, :test)

      on_exit(fn ->
        if original_environment do
          Application.put_env(:raxol, :environment, original_environment)
        else
          Application.delete_env(:raxol, :environment)
        end
      end)

      log =
        capture_log(fn ->
          Log.debug_with_context(fn -> "debug helper" end, %{a: 1})
          Log.module_debug(fn -> "module helper" end, %{b: 2})
          assert :timed == Log.time_debug(fn -> "timed helper" end, fn -> :timed end)
          Log.console(fn -> "console helper" end, %{c: 3})
        end)

      assert log =~ "debug helper | Context: %{a: 1}"
      assert log =~ "module helper"
      assert log =~ "timed helper ("
      assert log =~ "[CONSOLE] console helper | %{c: 3}"
    end
  end
end
