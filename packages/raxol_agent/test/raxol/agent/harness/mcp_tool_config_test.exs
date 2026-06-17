defmodule Raxol.Agent.Harness.McpToolConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Harness.McpToolConfig

  defmodule Greet do
    use Raxol.Agent.Action,
      name: "greet",
      description: "Greet a person",
      schema: [
        input: [name: [type: :string, required: true, description: "Who to greet"]]
      ]

    @impl true
    def run(%{name: name}, _ctx), do: {:ok, %{greeting: "hi #{name}"}}
  end

  describe "tool_definitions/1" do
    test "derives MCP tool defs from Action modules" do
      assert [%{"name" => "greet", "description" => "Greet a person", "inputSchema" => schema}] =
               McpToolConfig.tool_definitions([Greet])

      assert schema["type"] == "object"
      assert Map.has_key?(schema["properties"], "name")
    end
  end

  describe "config/1" do
    test "builds an mcpServers map with the launcher command" do
      cfg =
        McpToolConfig.config(
          actions: [Greet],
          command: "mix",
          args: ["mcp.server"],
          server_name: "raxol"
        )

      assert %{"mcpServers" => %{"raxol" => entry}} = cfg
      assert entry["command"] == "mix"
      assert entry["args"] == ["mcp.server"]
    end

    test "injects the tools manifest path into the server env" do
      cfg = McpToolConfig.config(command: "mix", tools_file: "/tmp/tools.json")
      entry = cfg["mcpServers"]["raxol"]
      assert entry["env"][McpToolConfig.tools_env_var()] == "/tmp/tools.json"
    end

    test "omits env when there is none" do
      cfg = McpToolConfig.config(command: "mix")
      refute Map.has_key?(cfg["mcpServers"]["raxol"], "env")
    end
  end

  describe "write/1" do
    @tag :tmp_dir
    test "writes config + tools manifest and wires the manifest path", %{tmp_dir: dir} do
      assert {:ok, config_path} =
               McpToolConfig.write(
                 actions: [Greet],
                 command: "mix",
                 args: ["mcp.server"],
                 dir: dir
               )

      assert File.exists?(config_path)
      config = config_path |> File.read!() |> Jason.decode!()
      entry = config["mcpServers"]["raxol"]

      tools_file = entry["env"][McpToolConfig.tools_env_var()]
      assert File.exists?(tools_file)

      manifest = tools_file |> File.read!() |> Jason.decode!()
      assert [%{"name" => "greet"}] = manifest["tools"]
    end
  end
end
