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

    test "does not build the message when the level is disabled" do
      Logger.configure(level: :error)
      parent = self()

      Log.debug(
        fn ->
          send(parent, :message_built)
          "x"
        end,
        %{a: 1}
      )

      refute_received :message_built
    end
  end
end
