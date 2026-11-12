defmodule Raxol.Broker.ToolsTest do
  @moduledoc """
  The generated read-tool modules and the capture task, against the Fake
  through the real read-only session.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Raxol.Broker.CaptureTools
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Tools
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

  test "bank and card reads are Banking's, approvals Account's, and a name two families match takes the first" do
    for {name, family} <- [
          {"get_bank_accounts", "Banking"},
          {"get_banking_transactions", "Banking"},
          {"get_credit_card_account", "Banking"},
          {"get_credit_transactions", "Banking"},
          {"get_trade_approval_setting", "Account"},
          {"get_trade_approvals", "Account"},
          {"get_accounts", "Account"},
          {"get_crypto_account_onboarding_info", "Crypto"},
          {"get_option_watchlist", "Options"},
          # `credit` alone is not a Banking term.
          {"get_credit_ratings", "MarketData"}
        ],
        do: assert(Generator.family(name) == family, name)
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

  test "technical indicators take exactly one of symbol and symbols, checked before sending" do
    tool = "get_equity_technical_indicators"
    keys = ["symbol", "symbols"]
    assert Tools.exactly_one(tool) == keys

    # The rule stands in for a schema that marks both optional. A capture
    # that drops one of them, or requires one, makes it wrong.
    schema = Catalog.schema(tool)
    assert Enum.all?(keys, &is_map_key(schema["properties"], &1))
    assert Enum.all?(keys, &(&1 not in schema["required"]))

    fake = Fake.start()
    empty = %{"content" => [%{"type" => "text", "text" => "{}"}], "isError" => false}
    Fake.on_call(fake, tool, fn _args -> {:result, empty} end)
    client = start_supervised!({Client, Fake.client_opts(fake)})

    base = %{"type" => "rsi", "interval" => "day", "start_time" => "2026-11-01T00:00:00Z"}
    refused = {:error, {:invalid_args, tool, [{[], {:exactly_one_of, keys}}]}}
    both = Map.merge(base, %{"symbol" => "AAPL", "symbols" => ["AAPL"]})

    assert MarketData.get_equity_technical_indicators(client, base) == refused
    assert MarketData.get_equity_technical_indicators(client, both) == refused

    assert MarketData.get_equity_technical_indicators(client, Map.put(base, "symbols", nil)) ==
             refused

    assert Fake.calls(fake) == []

    for one <- [%{"symbols" => ["AAPL"]}, %{"symbol" => "AAPL"}] do
      assert {:ok, %{is_error: false}} =
               MarketData.get_equity_technical_indicators(client, Map.merge(base, one))
    end

    assert Fake.calls(fake, "get_") == [tool, tool]
  end

  test "capture_tools writes the live list the catalog and generator read", %{tmp_dir: dir} do
    # A tool the committed capture lacks, as a server upgrade would add one.
    extra = %{
      "name" => "get_margin_summary",
      "description" => "Margin summary.",
      "inputSchema" => %{"type" => "object"},
      "annotations" => %{"readOnlyHint" => true}
    }

    fake = Fake.start(tools: [extra])
    out = Path.join(dir, "tools_list.json")

    assert {:ok, count} = CaptureTools.capture(Fake.client_opts(fake), out)

    %{"provenance" => provenance, "tools" => tools} = out |> File.read!() |> Jason.decode!()
    served = ["get_margin_summary" | Enum.map(Fake.tools(), & &1["name"])]
    assert Enum.map(tools, & &1["name"]) == Enum.sort(served)
    assert count == length(tools)
    assert provenance["source"] =~ "tools/list"

    captured = Enum.find(tools, &(&1["name"] == "get_margin_summary"))
    assert captured == extra
    assert Catalog.classify("get_margin_summary") == :unknown
    assert Catalog.classify("get_margin_summary", captured) == :read

    account = Generator.render(tools)[Path.join(Generator.dir(), "account.ex")]
    assert account =~ "def get_margin_summary(client"
  end
end
