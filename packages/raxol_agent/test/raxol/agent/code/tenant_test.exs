defmodule Raxol.Agent.Code.TenantTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.Tenant

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "raxol-tenants-#{System.os_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"
    )
  end

  test "derives a jailed per-tenant option set, creating the workspace" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, opts} = Tenant.app_opts(root, "alice")

    expanded = Path.expand(root)
    assert opts[:cwd] == Path.join([expanded, "alice", "work"])
    assert opts[:jail] == true

    assert opts[:sessions_dir] ==
             Path.join([expanded, "alice", "code_sessions"])

    assert opts[:journal_opts] == [
             base_dir: Path.join([expanded, "alice", "sessions"])
           ]

    assert opts[:agent_id] == "ssh:alice"
    assert File.dir?(opts[:cwd])
  end

  test "two tenants never share a directory" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, a} = Tenant.app_opts(root, "alice")
    {:ok, b} = Tenant.app_opts(root, "bob")

    refute a[:cwd] == b[:cwd]
    refute a[:sessions_dir] == b[:sessions_dir]
    refute a[:agent_id] == b[:agent_id]
  end

  test "an unsafe username is refused, not mapped" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    for bad <- ["../escape", ".", "a/b", ""] do
      assert {:error, :invalid_tenant} = Tenant.app_opts(root, bad)
    end

    # Nothing was created for any of them.
    refute File.exists?(Path.expand(Path.join(root, "..")) <> "/escape")
  end
end
