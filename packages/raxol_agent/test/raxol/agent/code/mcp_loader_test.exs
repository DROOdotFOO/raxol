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

    assert %{failed: []} = McpLoader.load(servers, bundle: bundle)

    assert_received {:specs, [spec], opts}
    assert spec == %{name: :fs, command: "npx", args: ["-y"], env: [{"A", "1"}]}
    assert is_function(Keyword.fetch!(opts, :start), 1)
  end

  test "a crashing bundle fails open instead of raising" do
    result =
      McpLoader.load([%{name: "x", command: "c"}],
        bundle: fn _specs, _opts -> exit(:boom) end
      )

    assert result.tools == []
    assert [{:bundle, {:exit, :boom}}] = result.failed
  end
end
