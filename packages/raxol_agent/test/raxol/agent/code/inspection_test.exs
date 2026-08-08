defmodule Raxol.Agent.Code.InspectionTest do
  # async: false — gather/2 reads provider env vars and the stored provider
  # file through Resolver.diagnostics/0.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.Inspection

  setup do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "raxol-inspection-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(cwd, ".raxol"))
    sessions_dir = Path.join(cwd, "sessions")
    File.mkdir_p!(sessions_dir)

    on_exit(fn -> File.rm_rf(cwd) end)

    %{cwd: cwd, sessions_dir: sessions_dir}
  end

  test "an empty directory gathers a complete, honest snapshot", ctx do
    snapshot = Inspection.gather(ctx.cwd, sessions_dir: ctx.sessions_dir)

    assert snapshot.cwd == ctx.cwd
    assert snapshot.project == %{}
    assert snapshot.hooks.status == :none
    assert snapshot.mcp_servers.status == :none
    assert snapshot.sessions == %{dir: ctx.sessions_dir, count: 0, latest: nil}
    # All 10 registry providers are always reported, available or not.
    assert length(snapshot.provider.providers) == 10
  end

  test "config files land in the snapshot with their real contents", ctx do
    File.write!(
      Path.join(ctx.cwd, ".raxol/config.json"),
      ~s({"provider": "anthropic", "model": "claude-sonnet-5"})
    )

    File.write!(
      Path.join(ctx.cwd, ".raxol/hooks.json"),
      ~s({"pre_tool_use": [{"match": "bash", "command": "./guard.sh"}],
          "stop": ["mix test --stale"]})
    )

    snapshot = Inspection.gather(ctx.cwd, sessions_dir: ctx.sessions_dir)

    assert snapshot.project == %{provider: :anthropic, model: "claude-sonnet-5"}
    assert snapshot.hooks.status == :ok
    assert snapshot.hooks.pre == [%{match: "bash", command: "./guard.sh"}]
    assert snapshot.hooks.stop == ["mix test --stale"]
  end

  test "mcp server env VALUES never enter the snapshot, names do", ctx do
    File.write!(
      Path.join(ctx.cwd, ".mcp.json"),
      ~s({"mcpServers": {"fs": {"command": "npx", "args": ["-y", "srv"],
          "env": {"API_TOKEN": "sekret-value"}}}})
    )

    snapshot = Inspection.gather(ctx.cwd, sessions_dir: ctx.sessions_dir)

    assert [server] = snapshot.mcp_servers.servers
    assert server.env_keys == ["API_TOKEN"]
    refute inspect(snapshot) =~ "sekret-value"
    refute Inspection.render(snapshot) =~ "sekret-value"
  end

  test "render covers every section in one readable block", ctx do
    File.write!(
      Path.join(ctx.cwd, ".raxol/config.json"),
      ~s({"provider": "mock"})
    )

    text =
      ctx.cwd
      |> Inspection.gather(sessions_dir: ctx.sessions_dir)
      |> Inspection.render()

    assert text =~ "inspecting: #{ctx.cwd}"
    assert text =~ "providers (op CLI:"
    assert text =~ "project pin (.raxol/config.json): provider=mock"
    assert text =~ "hooks (.raxol/hooks.json): none"
    assert text =~ "mcp servers (.mcp.json): none"
    assert text =~ "skills:"
    assert text =~ "sessions: #{ctx.sessions_dir} (none saved)"
  end

  test "the snapshot is JSON-encodable for --json", ctx do
    File.write!(
      Path.join(ctx.cwd, ".raxol/hooks.json"),
      ~s({"post_tool_use": [{"match": "*", "command": "mix format"}]})
    )

    json =
      ctx.cwd
      |> Inspection.gather(sessions_dir: ctx.sessions_dir)
      |> Jason.encode!()

    decoded = Jason.decode!(json)
    assert decoded["cwd"] == ctx.cwd
    assert [%{"match" => "*", "command" => "mix format"}] = decoded["hooks"]["post"]
  end

  test "a malformed hooks file is reported, never silently dropped", ctx do
    File.write!(Path.join(ctx.cwd, ".raxol/hooks.json"), "not json")

    snapshot = Inspection.gather(ctx.cwd, sessions_dir: ctx.sessions_dir)

    assert snapshot.hooks.status == :error
    assert Inspection.render(snapshot) =~ "hooks (.raxol/hooks.json): ERROR"
  end
end
