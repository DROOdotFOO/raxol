defmodule Raxol.Core.Stores.DetsTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Stores.Dets

  setup do
    dir = Path.join(System.tmp_dir!(), "core_stores_dets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "resolve_path/3" do
    test "prefers an explicit :dets_path option" do
      assert Dets.resolve_path([dets_path: "/tmp/explicit.dets"], :raxol_core, :unused) ==
               "/tmp/explicit.dets"
    end

    test "falls back to application config when no option is given" do
      key = :"dets_path_#{System.unique_integer([:positive])}"
      Application.put_env(:raxol_core, key, "/tmp/from_config.dets")
      on_exit(fn -> Application.delete_env(:raxol_core, key) end)

      assert Dets.resolve_path([], :raxol_core, key) == "/tmp/from_config.dets"
    end

    test "returns nil when neither option nor config is set" do
      key = :"absent_#{System.unique_integer([:positive])}"
      assert Dets.resolve_path([], :raxol_core, key) == nil
    end
  end

  describe "open!/3 and persistence round-trip" do
    test "replays stored records into ETS on reopen", %{dir: dir} do
      path = Path.join(dir, "store.dets")
      name = :"core_stores_dets_rt_#{System.unique_integer([:positive])}"

      handle = Dets.open!(name, path, fn _record -> :ok end)
      assert :ok = Dets.put(handle, "k1", %{v: 1})
      assert :ok = Dets.put(handle, "k2", %{v: 2})
      assert :ok = Dets.close(handle)

      collected = :ets.new(:collect, [:set, :public])
      reopened = Dets.open!(name, path, fn {k, v} -> :ets.insert(collected, {k, v}) end)

      assert :ets.lookup(collected, "k1") == [{"k1", %{v: 1}}]
      assert :ets.lookup(collected, "k2") == [{"k2", %{v: 2}}]

      Dets.close(reopened)
    end

    test "delete and clear remove records from disk", %{dir: dir} do
      path = Path.join(dir, "store.dets")
      name = :"core_stores_dets_del_#{System.unique_integer([:positive])}"

      handle = Dets.open!(name, path, fn _ -> :ok end)
      Dets.put(handle, "a", 1)
      Dets.put(handle, "b", 2)
      assert :ok = Dets.delete(handle, "a")
      Dets.close(handle)

      after_delete = :ets.new(:after_delete, [:set, :public])
      h2 = Dets.open!(name, path, fn {k, v} -> :ets.insert(after_delete, {k, v}) end)
      assert :ets.lookup(after_delete, "a") == []
      assert :ets.lookup(after_delete, "b") == [{"b", 2}]

      assert :ok = Dets.clear(h2)
      Dets.close(h2)

      after_clear = :ets.new(:after_clear, [:set, :public])
      h3 = Dets.open!(name, path, fn {k, v} -> :ets.insert(after_clear, {k, v}) end)
      assert :ets.tab2list(after_clear) == []
      Dets.close(h3)
    end

    test "creates intermediate directories for the dets file", %{dir: dir} do
      path = Path.join([dir, "nested", "deeper", "store.dets"])
      name = :"core_stores_dets_mkdir_#{System.unique_integer([:positive])}"

      handle = Dets.open!(name, path, fn _ -> :ok end)
      assert File.dir?(Path.dirname(path))
      Dets.close(handle)
    end
  end

  describe "nil handle is a no-op" do
    test "put/delete/clear/close all return :ok with no handle" do
      assert :ok = Dets.put(nil, "k", 1)
      assert :ok = Dets.delete(nil, "k")
      assert :ok = Dets.clear(nil)
      assert :ok = Dets.close(nil)
    end
  end
end
