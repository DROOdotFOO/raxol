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

    assert {:ok, [alpha, zeta], []} = McpConfig.load_all(dir)
    assert alpha.name == "alpha"
    assert alpha.command == "uvx"
    assert alpha.args == ["a"]
    assert alpha.env == %{"K" => "V"}
    assert zeta.name == "zeta"
  end

  test "returns :none when there is no file", %{dir: dir} do
    assert :none = McpConfig.load_all(dir)
  end

  test "a valid object with no servers is empty, not an error", %{dir: dir} do
    write(dir, Jason.encode!(%{"other" => true}))
    assert {:ok, [], []} = McpConfig.load_all(dir)
  end

  test "errors on invalid json", %{dir: dir} do
    write(dir, "{bad")
    assert {:error, :invalid_json} = McpConfig.load_all(dir)
  end

  describe "load_all/1" do
    test "reports a url server as skipped with :unsupported_transport", %{dir: dir} do
      write(
        dir,
        Jason.encode!(%{
          "mcpServers" => %{
            "remote" => %{"type" => "http", "url" => "https://mcp.example/sse"},
            "local" => %{"command" => "uvx", "args" => ["a"]}
          }
        })
      )

      assert {:ok, [%{name: "local"}], [{"remote", :unsupported_transport}]} =
               McpConfig.load_all(dir)
    end

    test "a typed http or sse entry without a url is still unsupported transport",
         %{dir: dir} do
      write(dir, Jason.encode!(%{"mcpServers" => %{"typed" => %{"type" => "sse"}}}))
      assert {:ok, [], [{"typed", :unsupported_transport}]} = McpConfig.load_all(dir)
    end

    test "each shape the bridge cannot run reports its own reason", %{dir: dir} do
      write(
        dir,
        Jason.encode!(%{
          "mcpServers" => %{
            "no-command" => %{"args" => ["x"]},
            "bad-command" => %{"command" => 42},
            "not-an-object" => "npx"
          }
        })
      )

      assert {:ok, [],
              [
                {"bad-command", :command_not_string},
                {"no-command", :no_command},
                {"not-an-object", :not_an_object}
              ]} = McpConfig.load_all(dir)
    end
  end
end
