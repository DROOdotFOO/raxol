defmodule Raxol.Agent.Code.McpLoaderTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.McpLoader

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "converts config servers into bundle specs (atom name, env list)", %{
    supervisor: supervisor
  } do
    parent = self()

    bundle = fn specs, opts ->
      send(parent, {:specs, specs, opts})
      %{tools: [], servers: [], failed: []}
    end

    servers = [%{name: "fs", command: "npx", args: ["-y"], env: %{"A" => "1"}}]

    assert %{connected: [], failed: [], janitor: janitor} =
             McpLoader.load(servers, bundle: bundle, supervisor: supervisor)

    assert janitor in Task.Supervisor.children(supervisor)

    assert_received {:specs, [spec], opts}
    # `:source` travels with the spec: losing it between the parse and the
    # header resolver would silently widen which specs may resolve a
    # credential reference.
    assert spec == %{
             name: :fs,
             source: :workspace,
             command: "npx",
             args: ["-y"],
             env: [{"A", "1"}]
           }

    assert is_function(Keyword.fetch!(opts, :start), 1)
    McpLoader.stop(janitor)
  end

  test "converts a remote config server into a remote bundle spec", %{supervisor: supervisor} do
    parent = self()

    bundle = fn specs, _opts ->
      send(parent, {:specs, specs})
      %{tools: [], servers: [], failed: []}
    end

    servers = [
      %{
        name: "intel",
        url: "https://mcp.example.com/v1",
        headers: [{"Authorization", "op://Employee/Intel/token"}],
        metered: true,
        prices: %{"lookup" => 150},
        concurrency: :serialized,
        source: :user
      }
    ]

    result = McpLoader.load(servers, bundle: bundle, supervisor: supervisor)

    assert_received {:specs, [spec]}

    assert spec == %{
             name: :intel,
             source: :user,
             url: "https://mcp.example.com/v1",
             headers: [{"Authorization", "op://Employee/Intel/token"}],
             metered: true,
             prices: %{"lookup" => 150},
             concurrency: :serialized
           }

    McpLoader.stop(result.janitor)
  end

  test "reports connected server names (not pids) from the bundle result", %{
    supervisor: supervisor
  } do
    bundle = fn _specs, _opts ->
      %{tools: [:tool_a], servers: [{:fs, self()}], failed: [{:ghost, :enoent}]}
    end

    assert %{tools: [:tool_a], connected: [:fs], failed: [{:ghost, :enoent}]} =
             result =
             McpLoader.load([%{name: "fs", command: "c"}],
               bundle: bundle,
               supervisor: supervisor
             )

    McpLoader.stop(result.janitor)
  end

  test "a crashing bundle fails open instead of raising", %{supervisor: supervisor} do
    result =
      McpLoader.load([%{name: "x", command: "c"}],
        bundle: fn _specs, _opts -> exit(:boom) end,
        supervisor: supervisor
      )

    assert result.tools == []
    assert result.janitor == nil
    assert [{:bundle, {:exit, :boom}}] = result.failed
  end

  test "the janitor stops its clients when the owner process dies", %{supervisor: supervisor} do
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
      client_start: client_start,
      supervisor: supervisor
    )

    assert_received {:started, client_pid}
    ref = Process.monitor(client_pid)

    # Owner dies by ANY path -> the janitor tears the client down.
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 2_000
  end

  test "stop/1 terminates the janitor's clients on demand", %{supervisor: supervisor} do
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
        client_start: client_start,
        supervisor: supervisor
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

    test "load/2 reports refusals through :failed rather than dropping them", %{
      supervisor: supervisor
    } do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      bundle = fn specs, _opts -> %{tools: [], servers: [], failed: [], specs: specs} end

      result =
        McpLoader.load(
          [%{name: "ok", command: "true"}, %{name: "not ok", command: "true"}],
          owner: owner,
          bundle: bundle,
          supervisor: supervisor
        )

      assert {"not ok", :invalid_server_name} in result.failed
      McpLoader.stop(result.janitor)
    end

    test "keeps one server per name, first listed winning" do
      servers = [
        %{name: "intel", url: "https://operator/mcp", source: :user},
        %{name: "intel", url: "https://repo-chose/mcp", source: :workspace}
      ]

      assert {[kept], [{"intel", {:duplicate_server_name, "intel"}}]} =
               McpLoader.admit(servers)

      assert kept.source == :user
    end

    test "two names that mint the SAME tool namespace are one server, not two" do
      # `-` is legal in a server name and illegal in a tool name, so both of
      # these become `mcp__intel_api__<tool>`. Admitting both put two
      # identically named functions in one tool array -- providers reject the
      # whole request, so every tool call in the session fails -- and let the
      # workspace entry shadow the operator's by spelling its name differently.
      assert Raxol.MCP.Client.tool_name(:"intel-api", "lookup") ==
               Raxol.MCP.Client.tool_name(:intel_api, "lookup")

      servers = [
        %{name: "intel_api", url: "https://operator/mcp", source: :user},
        %{name: "intel-api", url: "https://repo-chose/mcp", source: :workspace}
      ]

      assert {[kept], [{"intel-api", {:duplicate_server_name, "intel_api"}}]} =
               McpLoader.admit(servers)

      assert kept.source == :user
    end

    test "minting new atoms is bounded across loads, not just within one" do
      # The 16-server cap bounds one load; atoms are never collected and each
      # session reads a fresh `.mcp.json`, so what matters is the count across
      # every load this node ever does. Own counter and own budget here, so
      # the assertion does not depend on -- or spend -- the node's.
      counter = :atomics.new(1, [])
      budget = [atom_counter: counter, atom_budget: 1]
      fresh = "mcp_gap_r_#{System.unique_integer([:positive])}"

      assert {[_first], []} = McpLoader.admit([%{name: fresh, command: "true"}], budget)

      later = "mcp_gap_r_#{System.unique_integer([:positive])}"

      assert {[], [{^later, :atom_budget_exhausted}]} =
               McpLoader.admit([%{name: later, command: "true"}], budget)

      # A name already interned stays free: reloading the same file forever
      # costs nothing, which is what makes the budget bound an ATTACK rather
      # than an ordinary long-running host.
      assert {[_again], []} = McpLoader.admit([%{name: fresh, command: "true"}], budget)
    end
  end
end
