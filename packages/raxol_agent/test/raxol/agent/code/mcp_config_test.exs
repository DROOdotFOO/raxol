defmodule Raxol.Agent.Code.McpConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.McpConfig

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, content), do: File.write!(Path.join(dir, ".mcp.json"), content)

  test "parses declared servers, sorted by name", %{dir: dir} do
    write(
      dir,
      Jason.encode!(%{
        "mcpServers" => %{
          "zeta" => %{"command" => "npx", "args" => ["-y", "z"]},
          "alpha" => %{"command" => "uvx", "args" => ["a"], "env" => %{"K" => "V"}}
        }
      })
    )

    assert {:ok, [alpha, zeta]} = McpConfig.load(dir)
    assert alpha.name == "alpha"
    assert alpha.command == "uvx"
    assert alpha.args == ["a"]
    assert alpha.env == %{"K" => "V"}
    assert zeta.name == "zeta"
  end

  test "returns :none when there is no file", %{dir: dir} do
    assert :none = McpConfig.load(dir)
  end

  test "a valid object with no servers is empty, not an error", %{dir: dir} do
    write(dir, Jason.encode!(%{"other" => true}))
    assert {:ok, []} = McpConfig.load(dir)
  end

  test "errors on invalid json", %{dir: dir} do
    write(dir, "{bad")
    assert {:error, :invalid_json} = McpConfig.load(dir)
  end

  test "a server missing a command is dropped", %{dir: dir} do
    write(dir, Jason.encode!(%{"mcpServers" => %{"broken" => %{"args" => ["x"]}}}))
    assert {:ok, []} = McpConfig.load(dir)
  end
end
