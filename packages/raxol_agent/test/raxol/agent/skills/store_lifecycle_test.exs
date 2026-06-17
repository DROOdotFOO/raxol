defmodule Raxol.Agent.Skills.StoreLifecycleTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Skills.Store

  setup do
    base = Path.join(System.tmp_dir!(), "sklife_#{System.unique_integer([:positive])}")
    root = Path.join(base, "managed")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)

    name = :"sklife_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Store, :start_link, [[name: name, skills_root: root, external_dirs: []]]}
    })

    %{server: name, root: root}
  end

  defp create(server, name, created_by \\ :agent) do
    Store.create(%{name: name, body: "# #{name}", created_by: created_by}, server: server)
  end

  test "set_state moves a skill between lifecycle states", %{server: s} do
    create(s, "x")
    assert {:ok, %{state: :active}} = Store.usage("x", server: s)
    assert :ok = Store.set_state("x", :stale, server: s)
    assert {:ok, %{state: :stale}} = Store.usage("x", server: s)
  end

  test "pin and unpin toggle the pinned flag", %{server: s} do
    create(s, "x")
    assert :ok = Store.pin("x", server: s)
    assert {:ok, %{pinned: true}} = Store.usage("x", server: s)
    assert :ok = Store.unpin("x", server: s)
    assert {:ok, %{pinned: false}} = Store.usage("x", server: s)
  end

  test "create stamps created_at" do
    %{server: s} = start_fresh()
    create(s, "x")
    assert {:ok, %{created_at: ts}} = Store.usage("x", server: s)
    assert is_integer(ts)
  end

  test "telemetry returns a row per indexed skill", %{server: s} do
    create(s, "a", :agent)
    create(s, "b", :user)

    rows = Store.telemetry(server: s)
    assert Enum.map(rows, & &1.name) == ["a", "b"]
    a = Enum.find(rows, &(&1.name == "a"))
    assert a.created_by == :agent
    assert a.source == :managed
    assert Map.has_key?(a, :last_used_at)
    assert Map.has_key?(a, :created_at)
  end

  describe "archive" do
    test "moves the skill under .archive and drops it from the index", %{server: s, root: root} do
      create(s, "gone")
      assert :ok = Store.archive("gone", server: s)

      assert {:error, :not_found} = Store.get("gone", server: s)
      refute "gone" in Enum.map(Store.list(server: s), & &1.name)
      assert File.exists?(Path.join([root, ".archive", "gone", "SKILL.md"]))
      refute File.exists?(Path.join([root, "gone", "SKILL.md"]))
    end

    test "retains telemetry with state :archived", %{server: s} do
      create(s, "gone")
      Store.archive("gone", server: s)
      assert {:ok, %{state: :archived}} = Store.usage("gone", server: s)
    end

    test "a re-scan does not re-index archived skills", %{server: s} do
      create(s, "gone")
      Store.archive("gone", server: s)
      Store.reload(server: s)
      assert {:error, :not_found} = Store.get("gone", server: s)
    end
  end

  defp start_fresh do
    base = Path.join(System.tmp_dir!(), "skfresh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    name = :"skfresh_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Store, :start_link, [[name: name, skills_root: base, external_dirs: []]]}
    })

    %{server: name}
  end
end
