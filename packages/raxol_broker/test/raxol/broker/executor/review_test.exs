defmodule Raxol.Broker.Executor.ReviewTest do
  @moduledoc """
  The review stage reading responses from `Raxol.Broker.Test.OrderServer`
  through a real port: anything it cannot read is a warning.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.Executor.Review
  alias Raxol.Broker.Intent
  alias Raxol.Broker.Test.OrderServer

  @moduletag :capture_log
  @unreadable "unreadable review response"

  setup do
    server = OrderServer.start()
    {:ok, port} = PortMCP.start(OrderServer.session(server), mode: :dry_run)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("2"), Decimal.new("125"), provenance: :strategy)

    {:ok, server: server, port: port, intent: intent}
  end

  defp answer(server, result),
    do: OrderServer.on_call(server, "review_equity_order", fn _args -> {:result, result} end)

  defp text(body), do: %{"type" => "text", "text" => Jason.encode!(body)}

  test "a quote with no alerts has no warnings", ctx do
    assert {:ok, %{"tool" => "review_equity_order"}, []} =
             Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "alerts become warnings", ctx do
    OrderServer.warnings(ctx.server, ["pattern day trader"])

    assert {:ok, _response, ["pattern day trader"]} =
             Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "empty content is one unreadable warning", ctx do
    answer(ctx.server, %{"content" => [], "isError" => false})
    assert {:ok, _response, [@unreadable]} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "a JSON object with none of the known keys is unreadable", ctx do
    answer(ctx.server, %{"content" => [text(%{"notice" => "margin call"})], "isError" => false})
    assert {:ok, _response, [@unreadable]} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "text that is not a JSON object is unreadable", ctx do
    answer(ctx.server, %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => false})
    assert {:ok, _response, [@unreadable]} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  for body <- [
        %{"quote" => %{}, "alerts" => nil},
        %{"quote" => %{}, "warnings" => nil},
        %{"quote" => nil},
        %{"quote" => %{}},
        %{"alerts" => "margin call"},
        %{"warnings" => %{"message" => "margin call"}}
      ] do
    @body body
    test "#{Jason.encode!(body)} is unreadable", ctx do
      answer(ctx.server, %{"content" => [text(@body)], "isError" => false})
      assert {:ok, _response, [@unreadable]} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
    end
  end

  test "a null key beside a readable list keeps the list and adds unreadable", ctx do
    body = %{"alerts" => ["pattern day trader"], "warnings" => nil}
    answer(ctx.server, %{"content" => [text(body)], "isError" => false})

    assert {:ok, _response, ["pattern day trader", @unreadable]} =
             Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "an empty warnings list with no alerts key is readable and clean", ctx do
    answer(ctx.server, %{"content" => [text(%{"warnings" => []})], "isError" => false})
    assert {:ok, _response, []} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "a quote with errors and no alerts is unreadable plus each error", ctx do
    body = %{"quote" => %{}, "errors" => ["insufficient buying power", %{"message" => "halted"}]}
    answer(ctx.server, %{"content" => [text(body)], "isError" => false})

    assert {:ok, _response, [@unreadable, "insufficient buying power", "halted"]} =
             Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "errors beside a readable alerts list are each a warning", ctx do
    body = %{"alerts" => [], "errors" => ["insufficient buying power"]}
    answer(ctx.server, %{"content" => [text(body)], "isError" => false})

    assert {:ok, _response, ["insufficient buying power"]} =
             Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "a null errors key is unreadable", ctx do
    body = %{"alerts" => [], "errors" => nil}
    answer(ctx.server, %{"content" => [text(body)], "isError" => false})
    assert {:ok, _response, [@unreadable]} = Review.run(ctx.port, ctx.intent, "ACC-1", 5_000)
  end

  test "isError fails the review", ctx do
    answer(ctx.server, %{"content" => [text(%{"quote" => %{}})], "isError" => true})

    assert Review.run(ctx.port, ctx.intent, "ACC-1", 5_000) ==
             {:error, {:review_failed, "review_equity_order", :is_error}}
  end

  test "equity?/1 covers the equity kinds and nothing else", ctx do
    assert Review.equity?(ctx.intent)
    refute Review.equity?(%{ctx.intent | kind: :cancel})
    refute Review.equity?(%{ctx.intent | kind: :option})
  end
end
