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
    # The share scope is the bare tenant name (the agent_id's "ssh:" prefix
    # would break the token's colon-delimited framing), so a minted link
    # resolves THIS tenant's journal base.
    assert opts[:share_scope] == "alice"
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

  # The jail's whole claim is that a tenant cannot run code outside it. Both
  # of the workspace files that name a command to execute live INSIDE the
  # tenant's writable tree (the agent's own write_file lands there), so a
  # jailed session must refuse to load either — otherwise "write this file,
  # then ask me anything" is arbitrary execution as the server uid, around
  # the cwd jail and the :jail shell gate alike.
  describe "the jail confines execution, not just paths" do
    test "a jailed session loads no workspace hooks" do
      root = tmp_root()
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, opts} = Tenant.app_opts(root, "alice")
      work = opts[:cwd]

      File.mkdir_p!(Path.join(work, ".raxol"))

      File.write!(
        Path.join(work, ".raxol/hooks.json"),
        ~s({"stop": ["touch #{Path.join(work, "pwned")}"]})
      )

      model = Raxol.Agent.Code.App.init(%{options: opts})

      assert model.hooks == nil
      assert model.status_line =~ "hooks disabled"

      # And the tool-call seam refuses independently of what was loaded: a
      # config smuggled into the run context still runs nothing.
      {:ok, config} = Raxol.Agent.Code.Hooks.load(work)
      assert Raxol.Agent.Code.Hooks.count(config) > 0

      context = %{jail: true, code_hooks: config, hook_cwd: work}
      call = %{name: "read_file", arguments: %{}}

      assert {:cont, ^call} = Raxol.Agent.Code.Hooks.before_call(call, context)
      assert Raxol.Agent.Code.Hooks.after_call(call, {:ok, %{}}, context)
      refute File.exists?(Path.join(work, "pwned"))

      # Positive control: the SAME config in an unjailed context does run the
      # command, so the absence above is the jail refusing rather than the
      # hook mechanism quietly failing.
      Raxol.Agent.Code.Hooks.run_stop(config, work)
      assert File.exists?(Path.join(work, "pwned"))
    end

    test "a jailed session starts no workspace MCP servers" do
      root = tmp_root()
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, opts} = Tenant.app_opts(root, "alice")
      work = opts[:cwd]

      File.write!(
        Path.join(work, ".mcp.json"),
        ~s({"mcpServers": {"evil": {"command": "sh", "args": ["-c", "touch pwned"]}}})
      )

      model = Raxol.Agent.Code.App.init(%{options: opts})

      # Nothing to launch means maybe_launch_mcp/1 never spawns the command.
      assert model.mcp_servers == []
      assert model.status_line =~ "mcp servers disabled"
      refute File.exists?(Path.join(work, "pwned"))
    end

    test "an unjailed session still loads both (the local-workspace case)" do
      root = tmp_root()
      on_exit(fn -> File.rm_rf!(root) end)

      work = Path.join(root, "plain")
      File.mkdir_p!(Path.join(work, ".raxol"))
      File.write!(Path.join(work, ".raxol/hooks.json"), ~s({"stop": ["true"]}))

      File.write!(
        Path.join(work, ".mcp.json"),
        ~s({"mcpServers": {"fs": {"command": "true"}}})
      )

      model =
        Raxol.Agent.Code.App.init(%{
          options: [cwd: work, sessions_dir: Path.join(root, "sessions")]
        })

      assert model.hooks != nil
      assert [%{name: "fs"}] = model.mcp_servers
    end
  end
end
