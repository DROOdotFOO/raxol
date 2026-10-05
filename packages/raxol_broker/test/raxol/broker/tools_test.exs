defmodule Raxol.Broker.ToolsTest do
  @moduledoc """
  The generated read-tool modules and the capture task, against the Fake
  through the real read-only session.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Raxol.Broker.CaptureTools
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Tools.{Catalog, Generator}
  alias Raxol.Broker.Tools.MarketData

  @moduletag :capture_log
  @moduletag :tmp_dir

  @package Path.expand("../../..", __DIR__)

  test "the checked-in generated modules match the capture" do
    files = Generator.render()

    on_disk =
      Path.join([@package, Generator.dir(), "*.ex"])
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, @package), File.read!(&1)})

    assert on_disk == files, "run `mix raxol.broker.gen.tools` in packages/raxol_broker"
  end

  test "a generated function validates its arguments before anything is sent" do
    fake = Fake.start(quotes: %{"AAPL" => "125"})
    client = start_supervised!({Client, Fake.client_opts(fake)})

    assert {:error, {:invalid_args, "get_equity_quotes", [{["symbols"], :required}]}} =
             MarketData.get_equity_quotes(client, %{})

    assert Fake.calls(fake) == []

    assert {:ok, %{is_error: false, content: [%{"text" => text}]}} =
             MarketData.get_equity_quotes(client, %{"symbols" => ["AAPL"]})

    assert %{"quotes" => [%{"symbol" => "AAPL"}]} = Jason.decode!(text)
  end

  test "capture_tools writes the live list the catalog and generator read", %{tmp_dir: dir} do
    extra = %{
      "name" => "get_portfolio",
      "description" => "Portfolio.",
      "inputSchema" => %{"type" => "object"},
      "annotations" => %{"readOnlyHint" => true}
    }

    fake = Fake.start(tools: [extra])
    out = Path.join(dir, "tools_list.json")

    assert {:ok, count} = CaptureTools.capture(Fake.client_opts(fake), out)

    %{"provenance" => provenance, "tools" => tools} = out |> File.read!() |> Jason.decode!()
    served = Enum.map(Fake.tools(), & &1["name"]) ++ ["get_portfolio"]
    assert Enum.map(tools, & &1["name"]) == Enum.sort(served)
    assert count == length(tools)
    assert provenance["source"] =~ "tools/list"

    captured = Enum.find(tools, &(&1["name"] == "get_portfolio"))
    assert captured == extra
    assert Catalog.classify("get_portfolio", captured) == :read
    assert Generator.family("get_portfolio") == "Account"
    assert Map.has_key?(Generator.render(tools), Path.join(Generator.dir(), "account.ex"))
  end
end
