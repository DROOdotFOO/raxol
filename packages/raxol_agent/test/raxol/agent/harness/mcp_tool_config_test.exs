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

    # POSIX permission bits; Windows reports 0o777 whatever the ACL says.
    @tag :unix_only
    test "the default directory is closed to other users, as the env may hold a key" do
      assert {:ok, config_path} =
               McpToolConfig.write(actions: [Greet], command: "mix", env: %{"K" => "v"})

      dir = Path.dirname(config_path)
      on_exit(fn -> File.rm_rf(dir) end)

      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(config_path).mode, 0o777) == 0o600
      assert Jason.decode!(File.read!(config_path))["mcpServers"]["raxol"]["env"]["K"] == "v"
    end

    @tag :tmp_dir
    test "a :dir that is a file returns an error instead of raising", %{tmp_dir: tmp} do
      file = Path.join(tmp, "not_a_dir")
      File.write!(file, "")

      assert {:error, _} = McpToolConfig.write(actions: [Greet], command: "mix", dir: file)
    end
  end

  describe "private_dir/2" do
    @describetag :unix_only
    @describetag :tmp_dir

    test "skips a planted symlink and file, never following them", %{tmp_dir: tmp} do
      attacker = Path.join(tmp, "attacker")
      File.mkdir!(attacker)
      File.ln_s!(attacker, Path.join(tmp, "taken_link"))
      File.ln_s!(Path.join(tmp, "nowhere"), Path.join(tmp, "dangling_link"))
      File.write!(Path.join(tmp, "taken_file"), "")

      assert {:ok, dir} =
               McpToolConfig.private_dir(tmp, ~w(taken_link dangling_link taken_file fresh))

      assert dir == Path.join(tmp, "fresh")
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(dir)
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
      assert File.ls!(attacker) == []
      refute File.exists?(Path.join(tmp, "nowhere"))
    end

    test "every name taken is an error, not a raise", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a"), "")
      File.ln_s!(tmp, Path.join(tmp, "b"))

      assert {:error, _} = McpToolConfig.private_dir(tmp, ~w(a b))
    end
  end
end
