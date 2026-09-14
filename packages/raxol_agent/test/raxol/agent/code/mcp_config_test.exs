defmodule Raxol.Agent.Code.McpConfigTest do
  # `load_user/0` reads `$RAXOL_MCP_CONFIG`, which is process-wide.
  use ExUnit.Case, async: false

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

  test "a workspace remote entry survives with its url, headers and provenance", %{dir: dir} do
    write(
      dir,
      Jason.encode!(%{
        "mcpServers" => %{
          "intel" => %{
            "url" => "https://mcp.example.com/v1",
            "headers" => %{"Authorization" => "Bearer literal", "X-Account" => "acct"}
          }
        }
      })
    )

    assert {:ok, [intel]} = McpConfig.load(dir)
    assert intel.url == "https://mcp.example.com/v1"
    assert intel.headers == [{"Authorization", "Bearer literal"}, {"X-Account", "acct"}]
    assert intel.source == :workspace
    refute Map.has_key?(intel, :command)
  end

  test "an entry with both a command and a url keeps both, preferring neither", %{dir: dir} do
    write(
      dir,
      Jason.encode!(%{
        "mcpServers" => %{"both" => %{"command" => "npx", "url" => "https://x/mcp"}}
      })
    )

    assert {:ok, [both]} = McpConfig.load(dir)
    assert both.command == "npx"
    assert both.url == "https://x/mcp"
  end

  test "an entry with neither a command nor a url is kept for refusal, not dropped", %{dir: dir} do
    write(dir, Jason.encode!(%{"mcpServers" => %{"broken" => %{"args" => ["x"]}}}))

    assert {:ok, [broken]} = McpConfig.load(dir)
    assert broken.name == "broken"
    refute Map.has_key?(broken, :command)
    refute Map.has_key?(broken, :url)
  end

  test "only positive integer prices are prices, and any price means metered", %{dir: dir} do
    write(
      dir,
      Jason.encode!(%{
        "mcpServers" => %{
          "intel" => %{
            "url" => "https://x/mcp",
            "prices" => %{"lookup" => 150, "free" => 0, "wrong" => "150", "also" => -5}
          }
        }
      })
    )

    assert {:ok, [intel]} = McpConfig.load(dir)
    assert intel.prices == %{"lookup" => 150}
    assert intel.metered == true
  end

  test "an unknown concurrency string mints no atom and no key", %{dir: dir} do
    write(
      dir,
      Jason.encode!(%{
        "mcpServers" => %{
          "a" => %{"url" => "https://x/mcp", "concurrency" => "serialized"},
          "b" => %{"url" => "https://y/mcp", "concurrency" => "no_such_policy"}
        }
      })
    )

    assert {:ok, [a, b]} = McpConfig.load(dir)
    assert a.concurrency == :serialized
    refute Map.has_key?(b, :concurrency)
  end

  test "load_user/0 reads $RAXOL_MCP_CONFIG and tags the servers :user", %{dir: dir} do
    path = Path.join(dir, "user-mcp.json")

    File.write!(
      path,
      Jason.encode!(%{"mcpServers" => %{"intel" => %{"url" => "https://x/mcp"}}})
    )

    previous = System.get_env("RAXOL_MCP_CONFIG")
    System.put_env("RAXOL_MCP_CONFIG", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("RAXOL_MCP_CONFIG", previous),
        else: System.delete_env("RAXOL_MCP_CONFIG")
    end)

    assert McpConfig.user_path() == path
    assert {:ok, [intel]} = McpConfig.load_user()
    assert intel.source == :user
  end
end
