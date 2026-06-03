defmodule Raxol.Payments.EchoServerTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.EchoServer

  @pay_to "0x" <> String.duplicate("ab", 20)
  @asset "0x" <> String.duplicate("cd", 20)
  @network "eip155:8453"
  @amount 10_000

  setup_all do
    port = 4002 + :rand.uniform(500)

    {:ok, _pid} =
      EchoServer.start_link(
        port: port,
        pay_to: @pay_to,
        asset: @asset,
        network: @network,
        amount: @amount
      )

    on_exit(fn -> Plug.Cowboy.shutdown(Raxol.Payments.EchoServer.HTTP) end)

    %{port: port}
  end

  test "GET /health returns 200 ok", %{port: port} do
    resp = Req.get!("http://localhost:#{port}/health", retry: false)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "first request returns 402 with a valid x402 payment-required header", %{port: port} do
    resp = Req.get!("http://localhost:#{port}/anything", retry: false)
    assert resp.status == 402

    [encoded] = Req.Response.get_header(resp, "payment-required")
    challenge = encoded |> Base.decode64!() |> Jason.decode!()

    assert challenge["payTo"] == @pay_to
    assert challenge["asset"] == @asset
    assert challenge["network"] == @network
    assert challenge["maxAmountRequired"] == @amount
    assert String.starts_with?(challenge["nonce"], "0x")
  end

  test "retry with valid x-payment payload returns 200 + receipt", %{port: port} do
    payload =
      %{
        "signature" => "0x" <> String.duplicate("ab", 65),
        "network" => @network,
        "message" => %{
          "from" => "0x" <> String.duplicate("11", 20),
          "to" => @pay_to,
          "value" => @amount
        }
      }
      |> Jason.encode!()
      |> Base.encode64()

    resp =
      Req.get!(
        "http://localhost:#{port}/anything",
        headers: [{"x-payment", payload}],
        retry: false
      )

    assert resp.status == 200
    assert resp.body["ok"] == true
    assert get_in(resp.body, ["receipt", "success"]) == true
    assert get_in(resp.body, ["receipt", "network"]) == @network
  end

  test "retry with wrong recipient is rejected", %{port: port} do
    payload =
      %{
        "signature" => "0x" <> String.duplicate("ab", 65),
        "network" => @network,
        "message" => %{
          "from" => "0x" <> String.duplicate("11", 20),
          "to" => "0x" <> String.duplicate("ee", 20),
          "value" => @amount
        }
      }
      |> Jason.encode!()
      |> Base.encode64()

    resp =
      Req.get!(
        "http://localhost:#{port}/anything",
        headers: [{"x-payment", payload}],
        retry: false
      )

    assert resp.status == 402
    assert resp.body["error"] == "payment invalid"
  end

  test "retry with malformed signature is rejected", %{port: port} do
    payload =
      %{
        "signature" => "not-a-signature",
        "network" => @network,
        "message" => %{"to" => @pay_to, "value" => @amount}
      }
      |> Jason.encode!()
      |> Base.encode64()

    resp =
      Req.get!(
        "http://localhost:#{port}/anything",
        headers: [{"x-payment", payload}],
        retry: false
      )

    assert resp.status == 402
  end
end
