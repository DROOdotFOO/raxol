defmodule Raxol.Core.Runtime.Plugins.PluginRegistryTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.PluginRegistry
  alias Raxol.Test.TestUtils

  # Fixture modules
  defmodule PluginWithCommands do
    def commands, do: [:help, :info, :version]
  end

  defmodule PluginNoCommands do
    def hello, do: :world
  end

  defmodule PluginWithCrashingCommands do
    def commands, do: raise("boom")
  end

  defmodule AnotherPluginWithCommands do
    def commands, do: [:help, :deploy]
  end

  setup do
    PluginRegistry.init()

    on_exit(fn ->
      TestUtils.clear_ets_tables([
        :raxol_plugin_registry,
        :raxol_plugin_commands
      ])
    end)

    :ok
  end

  describe "init/0" do
    test "creates ETS tables" do
      assert :ets.whereis(:raxol_plugin_registry) != :undefined
      assert :ets.whereis(:raxol_plugin_commands) != :undefined
    end

    test "is idempotent" do
      assert :ok = PluginRegistry.init()
      assert :ok = PluginRegistry.init()
      assert :ets.whereis(:raxol_plugin_registry) != :undefined
    end

    test "registration still works after a repeated init/0" do
      assert :ok = PluginRegistry.init()
      assert :ok = PluginRegistry.register(:after_reinit, PluginWithCommands)
      assert {:ok, entry} = PluginRegistry.get(:after_reinit)
      assert entry.module == PluginWithCommands
      assert :after_reinit in PluginRegistry.find_by_command(:help)
    end

    test "adopts tables owned by another process" do
      drop_tables()

      owner = spawn_table_owner()

      assert :ok = PluginRegistry.init()
      assert :ok = PluginRegistry.register(:foreign_owner, PluginWithCommands)
      assert {:ok, _entry} = PluginRegistry.get(:foreign_owner)
      assert :foreign_owner in PluginRegistry.find_by_command(:help)

      stop_and_await(owner)
    end

    # Regression: init/0 used to be check-then-act
    # (`if :ets.whereis(t) == :undefined, do: :ets.new(t, ...)`), so callers
    # racing to create the tables could all observe :undefined and then all
    # call :ets.new/2. Every loser crashed with ArgumentError "table name
    # already exists". Creation is attempted directly now, so no caller can
    # lose. The callers are released from a spin barrier rather than by
    # sequential sends so that they reach :ets.new/2 together, and several
    # rounds are run because one round only samples one interleaving.
    test "concurrent callers never crash creating the tables" do
      for _round <- 1..10 do
        drop_tables()

        parent = self()
        barrier = :atomics.new(1, [])

        callers =
          for _ <- 1..32 do
            spawn(fn ->
              send(parent, {self(), :waiting})
              await_barrier(barrier)

              result =
                try do
                  {:ok, PluginRegistry.init()}
                rescue
                  error -> {:raised, error}
                end

              send(parent, {self(), result})
              # Stay alive so the created tables outlive the assertions.
              receive do: (:stop -> :ok)
            end)
          end

        for caller <- callers, do: assert_receive({^caller, :waiting}, 5_000)
        :atomics.put(barrier, 1, 1)

        for caller <- callers do
          assert_receive {^caller, result}, 5_000
          assert result == {:ok, :ok}
        end

        assert PluginRegistry.initialized?()
        assert :ok = PluginRegistry.register(:raced, PluginWithCommands)
        assert {:ok, _entry} = PluginRegistry.get(:raced)

        Enum.each(callers, &stop_and_await/1)
      end
    end
  end

  describe "initialized?/0" do
    test "returns true after init" do
      assert PluginRegistry.initialized?()
    end
  end

  describe "register/3" do
    test "registers a plugin with id, module, and metadata" do
      assert :ok =
               PluginRegistry.register(:my_plugin, PluginNoCommands, %{
                 version: "1.0"
               })

      assert {:ok, entry} = PluginRegistry.get(:my_plugin)
      assert entry.id == :my_plugin
      assert entry.module == PluginNoCommands
      assert entry.metadata == %{version: "1.0"}
      assert %DateTime{} = entry.registered_at
    end

    test "registers with default empty metadata" do
      assert :ok = PluginRegistry.register(:bare, PluginNoCommands)
      assert {:ok, entry} = PluginRegistry.get(:bare)
      assert entry.metadata == %{}
    end

    test "normalizes string ids to atoms" do
      assert :ok = PluginRegistry.register("string_plugin", PluginNoCommands)
      assert {:ok, _entry} = PluginRegistry.get(:string_plugin)
    end

    test "returns error on duplicate registration" do
      assert :ok = PluginRegistry.register(:dup, PluginNoCommands)

      assert {:error, :already_registered} =
               PluginRegistry.register(:dup, PluginNoCommands)
    end

    test "registers commands from module's commands/0 callback" do
      assert :ok = PluginRegistry.register(:with_cmds, PluginWithCommands)
      assert [:with_cmds] = PluginRegistry.find_by_command(:help)
      assert [:with_cmds] = PluginRegistry.find_by_command(:info)
      assert [:with_cmds] = PluginRegistry.find_by_command(:version)
    end

    test "does not crash when module has no commands/0" do
      assert :ok = PluginRegistry.register(:no_cmds, PluginNoCommands)
      assert [] = PluginRegistry.find_by_command(:anything)
    end

    test "handles crashing commands/0 gracefully" do
      assert :ok =
               PluginRegistry.register(:crash_cmds, PluginWithCrashingCommands)

      assert [] = PluginRegistry.get_commands(:crash_cmds)
    end
  end

  describe "unregister/1" do
    test "removes a registered plugin" do
      PluginRegistry.register(:removable, PluginNoCommands)
      assert :ok = PluginRegistry.unregister(:removable)
      assert :error = PluginRegistry.get(:removable)
    end

    test "removes associated command mappings" do
      PluginRegistry.register(:cmd_plugin, PluginWithCommands)
      assert [:cmd_plugin] = PluginRegistry.find_by_command(:help)

      PluginRegistry.unregister(:cmd_plugin)
      assert [] = PluginRegistry.find_by_command(:help)
    end

    test "is idempotent on missing id" do
      assert :ok = PluginRegistry.unregister(:nonexistent)
    end

    test "handles string ids" do
      PluginRegistry.register(:str_unreg, PluginNoCommands)
      assert :ok = PluginRegistry.unregister("str_unreg")
      assert :error = PluginRegistry.get(:str_unreg)
    end
  end

  describe "update_metadata/2" do
    test "merges new metadata with existing" do
      PluginRegistry.register(:updatable, PluginNoCommands, %{
        version: "1.0",
        author: "me"
      })

      assert :ok =
               PluginRegistry.update_metadata(:updatable, %{
                 version: "2.0",
                 extra: true
               })

      assert {:ok, entry} = PluginRegistry.get(:updatable)
      assert entry.metadata == %{version: "2.0", author: "me", extra: true}
    end

    test "returns error for missing plugin" do
      assert {:error, :not_found} = PluginRegistry.update_metadata(:nope, %{})
    end

    test "handles string ids" do
      PluginRegistry.register(:str_update, PluginNoCommands, %{v: 1})
      assert :ok = PluginRegistry.update_metadata("str_update", %{v: 2})
      assert {:ok, entry} = PluginRegistry.get(:str_update)
      assert entry.metadata.v == 2
    end
  end

  describe "get/1" do
    test "returns {:ok, entry} for registered plugin" do
      PluginRegistry.register(:gettable, PluginNoCommands, %{x: 1})
      assert {:ok, entry} = PluginRegistry.get(:gettable)
      assert entry.id == :gettable
    end

    test "returns :error for missing plugin" do
      assert :error = PluginRegistry.get(:missing)
    end

    test "works with string ids" do
      PluginRegistry.register(:str_get, PluginNoCommands)
      assert {:ok, _} = PluginRegistry.get("str_get")
    end
  end

  describe "get_module/1" do
    test "returns module for registered plugin" do
      PluginRegistry.register(:mod_get, PluginNoCommands)
      assert PluginNoCommands = PluginRegistry.get_module(:mod_get)
    end

    test "returns nil for missing plugin" do
      assert nil == PluginRegistry.get_module(:missing_mod)
    end
  end

  describe "registered?/1" do
    test "returns true for registered plugin" do
      PluginRegistry.register(:check_reg, PluginNoCommands)
      assert PluginRegistry.registered?(:check_reg)
    end

    test "returns false for missing plugin" do
      refute PluginRegistry.registered?(:not_here)
    end

    test "works with string ids" do
      PluginRegistry.register(:str_check, PluginNoCommands)
      assert PluginRegistry.registered?("str_check")
    end
  end

  describe "list/1" do
    test "returns empty list when no plugins" do
      assert [] = PluginRegistry.list()
    end

    test "returns all registered plugins sorted by registered_at" do
      PluginRegistry.register(:first, PluginNoCommands)
      Process.sleep(1)
      PluginRegistry.register(:second, PluginWithCommands)

      entries = PluginRegistry.list()
      assert length(entries) == 2
      assert hd(entries).id == :first
      assert List.last(entries).id == :second
    end

    test "returns only ids with ids_only: true" do
      PluginRegistry.register(:a, PluginNoCommands)
      PluginRegistry.register(:b, PluginNoCommands)

      ids = PluginRegistry.list(ids_only: true)
      assert is_list(ids)
      assert :a in ids
      assert :b in ids
    end
  end

  describe "count/0" do
    test "returns 0 when empty" do
      assert 0 = PluginRegistry.count()
    end

    test "returns correct count after registration" do
      PluginRegistry.register(:c1, PluginNoCommands)
      PluginRegistry.register(:c2, PluginNoCommands)
      assert 2 = PluginRegistry.count()
    end

    test "decrements after unregister" do
      PluginRegistry.register(:c3, PluginNoCommands)
      PluginRegistry.register(:c4, PluginNoCommands)
      PluginRegistry.unregister(:c3)
      assert 1 = PluginRegistry.count()
    end
  end

  describe "find_by_command/1" do
    test "finds plugin that provides a command" do
      PluginRegistry.register(:finder, PluginWithCommands)
      assert [:finder] = PluginRegistry.find_by_command(:help)
    end

    test "returns empty list for unknown command" do
      assert [] = PluginRegistry.find_by_command(:unknown)
    end

    test "finds multiple plugins providing the same command" do
      PluginRegistry.register(:p1, PluginWithCommands)
      PluginRegistry.register(:p2, AnotherPluginWithCommands)

      providers = PluginRegistry.find_by_command(:help)
      assert :p1 in providers
      assert :p2 in providers
      assert length(providers) == 2
    end
  end

  describe "get_commands/1" do
    test "returns commands for a plugin" do
      PluginRegistry.register(:cmd_list, PluginWithCommands)
      commands = PluginRegistry.get_commands(:cmd_list)
      assert :help in commands
      assert :info in commands
      assert :version in commands
    end

    test "returns empty list for plugin with no commands" do
      PluginRegistry.register(:no_cmd_list, PluginNoCommands)
      assert [] = PluginRegistry.get_commands(:no_cmd_list)
    end

    test "returns empty list for unknown plugin" do
      assert [] = PluginRegistry.get_commands(:ghost)
    end
  end

  describe "list_commands/0" do
    test "returns all command-plugin pairs sorted by command" do
      PluginRegistry.register(:lc, PluginWithCommands)
      commands = PluginRegistry.list_commands()
      assert is_list(commands)
      assert {:help, :lc} in commands
      assert {:info, :lc} in commands
      assert {:version, :lc} in commands

      # Verify sorted
      names = Enum.map(commands, fn {cmd, _} -> cmd end)
      assert names == Enum.sort(names)
    end

    test "returns empty list when no commands" do
      assert [] = PluginRegistry.list_commands()
    end
  end

  describe "filter/1" do
    test "filters plugins by predicate" do
      PluginRegistry.register(:v1, PluginNoCommands, %{version: "1.0"})
      PluginRegistry.register(:v2, PluginNoCommands, %{version: "2.0"})
      PluginRegistry.register(:v3, PluginNoCommands, %{version: "1.0"})

      results =
        PluginRegistry.filter(fn entry -> entry.metadata[:version] == "1.0" end)

      ids = Enum.map(results, & &1.id)
      assert :v1 in ids
      assert :v3 in ids
      refute :v2 in ids
    end

    test "returns empty list when no match" do
      PluginRegistry.register(:no_match, PluginNoCommands, %{version: "1.0"})
      assert [] = PluginRegistry.filter(fn _ -> false end)
    end
  end

  describe "find_by_metadata/2" do
    test "finds plugins by metadata key-value" do
      PluginRegistry.register(:cat1, PluginNoCommands, %{category: :ui})
      PluginRegistry.register(:cat2, PluginNoCommands, %{category: :io})
      PluginRegistry.register(:cat3, PluginNoCommands, %{category: :ui})

      results = PluginRegistry.find_by_metadata(:category, :ui)
      ids = Enum.map(results, & &1.id)
      assert :cat1 in ids
      assert :cat3 in ids
      refute :cat2 in ids
    end

    test "returns empty list for no matches" do
      assert [] = PluginRegistry.find_by_metadata(:category, :nonexistent)
    end
  end

  # Removes the tables created by setup/0 (owned by this process) so that the
  # code under test has to create them.
  defp drop_tables do
    Enum.each([:raxol_plugin_registry, :raxol_plugin_commands], fn table ->
      case :ets.whereis(table) do
        :undefined -> :ok
        _tid -> :ets.delete(table)
      end
    end)
  end

  # Spawns a process that creates the registry tables and then stays alive, so
  # the tables are owned by somebody other than the test process.
  defp spawn_table_owner do
    parent = self()

    owner =
      spawn(fn ->
        PluginRegistry.init()
        send(parent, {self(), :initialized})
        receive do: (:stop -> :ok)
      end)

    assert_receive {^owner, :initialized}, 5_000
    owner
  end

  # Spin (rather than block on a message) so that every caller leaves the
  # barrier in the same scheduler slice; sequential sends stagger the wake-ups
  # enough that the first caller usually wins uncontended.
  defp await_barrier(barrier) do
    if :atomics.get(barrier, 1) == 1 do
      :ok
    else
      await_barrier(barrier)
    end
  end

  defp stop_and_await(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end
end
