defmodule Raxol.Agent.Code.McpLoaderTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.McpLoader

  test "converts config servers into bundle specs (atom name, env list)" do
    parent = self()

    bundle = fn specs, opts ->
      send(parent, {:specs, specs, opts})
      %{tools: [], servers: [], failed: []}
    end

    servers = [%{name: "fs", command: "npx", args: ["-y"], env: %{"A" => "1"}}]

    assert %{connected: [], failed: [], janitor: janitor} =
             McpLoader.load(servers, bundle: bundle)

    assert_received {:specs, [spec], opts}
    assert spec == %{name: :fs, command: "npx", args: ["-y"], env: [{"A", "1"}]}
    assert is_function(Keyword.fetch!(opts, :start), 1)
    McpLoader.stop(janitor)
  end

  test "reports connected server names (not pids) from the bundle result" do
    bundle = fn _specs, _opts ->
      %{tools: [:tool_a], servers: [{:fs, self()}], failed: [{:ghost, :enoent}]}
    end

    assert %{tools: [:tool_a], connected: [:fs], failed: [{:ghost, :enoent}]} =
             result =
             McpLoader.load([%{name: "fs", command: "c"}], bundle: bundle)

    McpLoader.stop(result.janitor)
  end

  test "a crashing bundle fails open instead of raising" do
    result =
      McpLoader.load([%{name: "x", command: "c"}],
        bundle: fn _specs, _opts -> exit(:boom) end
      )

    assert result.tools == []
    assert result.janitor == nil
    assert [{:bundle, {:exit, :boom}}] = result.failed
  end

  test "the janitor stops its clients when the owner process dies" do
    parent = self()

    # A fake client is a plain process the janitor start-links and tracks.
    client_start = fn _opts ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(parent, {:started, pid})
      {:ok, pid}
    end

    # A bundle that drives the injected start fn once and returns the pid as a
    # connected server (mirrors McpBundle's success path).
    bundle = fn _specs, opts ->
      {:ok, pid} = Keyword.fetch!(opts, :start).(name: :fs)
      %{tools: [], servers: [{:fs, pid}], failed: []}
    end

    owner = spawn(fn -> Process.sleep(:infinity) end)

    McpLoader.load([%{name: "fs", command: "c"}],
      owner: owner,
      bundle: bundle,
      client_start: client_start
    )

    assert_received {:started, client_pid}
    ref = Process.monitor(client_pid)

    # Owner dies by ANY path -> the janitor tears the client down.
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 2_000
  end

  test "stop/1 terminates the janitor's clients on demand" do
    parent = self()

    client_start = fn _opts ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(parent, {:started, pid})
      {:ok, pid}
    end

    bundle = fn _specs, opts ->
      {:ok, pid} = Keyword.fetch!(opts, :start).(name: :fs)
      %{tools: [], servers: [{:fs, pid}], failed: []}
    end

    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    result =
      McpLoader.load([%{name: "fs", command: "c"}],
        owner: owner,
        bundle: bundle,
        client_start: client_start
      )

    assert_received {:started, client_pid}
    ref = Process.monitor(client_pid)

    McpLoader.stop(result.janitor)

    assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 2_000
  end

  describe "admission (a workspace file names commands and mints atoms)" do
    test "caps how many servers may load" do
      servers =
        for n <- 1..40, do: %{name: "srv#{n}", command: "true", args: [], env: %{}}

      {accepted, rejected} = McpLoader.admit(servers)

      # Every accepted server mints an atom (never collected) and spawns an OS
      # subprocess; a config file must not be able to ask for unbounded
      # amounts of either.
      assert length(accepted) == 16
      assert length(rejected) == 24
      assert Enum.all?(rejected, fn {_name, why} -> why == :server_limit_exceeded end)
    end

    test "refuses names outside the conservative charset" do
      bad = [
        String.duplicate("x", 100),
        "has space",
        "-leading-dash",
        "sl/ash",
        "",
        "unicode\u00e9"
      ]

      servers = for name <- bad, do: %{name: name, command: "true"}
      {accepted, rejected} = McpLoader.admit(servers)

      assert accepted == []
      assert length(rejected) == length(bad)
      assert Enum.all?(rejected, fn {_name, why} -> why == :invalid_server_name end)
    end

    test "accepts an ordinary config unchanged" do
      servers = [
        %{name: "filesystem", command: "npx"},
        %{name: "git_2", command: "uvx"}
      ]

      assert {^servers, []} = McpLoader.admit(servers)
    end

    test "load/2 reports refusals through :failed rather than dropping them" do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      bundle = fn specs, _opts -> %{tools: [], servers: [], failed: [], specs: specs} end

      result =
        McpLoader.load(
          [%{name: "ok", command: "true"}, %{name: "not ok", command: "true"}],
          owner: owner,
          bundle: bundle
        )

      assert {"not ok", :invalid_server_name} in result.failed
      McpLoader.stop(result.janitor)
    end
  end
end
