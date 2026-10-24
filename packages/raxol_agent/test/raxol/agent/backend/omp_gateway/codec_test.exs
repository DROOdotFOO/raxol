defmodule Raxol.Agent.Backend.OmpGateway.CodecTest do
  # Pure: decodes the bytes `scripts/omp_fixtures/capture.exs` recorded from
  # the real `omp auth-gateway stdio` (F1).
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.OmpGateway.Codec

  @fixtures Path.expand("../../../../fixtures/omp/gateway", __DIR__)

  @smol "anthropic/claude-haiku-5-5"

  defp events(name) do
    [_header | lines] =
      @fixtures |> Path.join("#{name}.jsonl") |> File.read!() |> String.split("\n", trim: true)

    Enum.map(lines, &Jason.decode!/1)
  end

  defp outs(name), do: for(%{"out" => line} <- events(name), do: line)
  defp ins(name), do: for(%{"in" => line} <- events(name), do: line)

  defp reply(name, id) do
    Enum.find_value(outs(name), fn line ->
      case Codec.decode_response(line) do
        {:ok, %{id: ^id} = response} -> response
        _ -> nil
      end
    end)
  end

  describe "ready line" do
    test "the recorded ready line passes the version pin" do
      [ready | _] = outs("no_model")

      assert {:ok, version, []} = Codec.decode_ready(ready)
      assert to_string(version) == "18.12.6"
    end

    test "a different major is refused" do
      [ready | _] = outs("no_model")
      wrong = String.replace(ready, "18.12.6", "19.0.0")

      assert {:error, {:unsupported_major, "19.0.0", "18.12.6"}} = Codec.decode_ready(wrong)
    end

    test "a reply line is not a ready line" do
      [_ready, reply | _] = outs("no_model")
      assert {:error, :invalid_ready_line} = Codec.decode_ready(reply)
    end
  end

  describe "errors carry status and type, never the body" do
    test "invalid JSON is a 400 with no id" do
      assert {:error, {:http_error, 400, "invalid_request_error"}} =
               "no_model" |> reply(nil) |> Codec.result()
    end

    test "a missing path is a 400" do
      assert {:error, {:http_error, 400, "invalid_request_error"}} =
               "no_model" |> reply(3) |> Codec.result()
    end

    test "an unknown model is a 404" do
      assert {:error, {:http_error, 404, "invalid_request_error"}} =
               "no_model" |> reply(4) |> Codec.result()
    end

    test "an unknown route is a 404 whose string error has no type" do
      assert {:error, {:http_error, 404, nil}} = "no_model" |> reply(5) |> Codec.result()
    end
  end

  test "GET /v1/models lists model ids" do
    assert {:ok, body} = "no_model" |> reply(1) |> Codec.result()
    assert Codec.model_ids(body) == []
  end

  describe "requests" do
    test "a messages request encodes to the recorded request" do
      body =
        Codec.messages_body([%{role: :user, content: "Reply with the single word pong."}],
          model: @smol,
          max_tokens: 16
        )

      encoded = 1 |> Codec.encode_request(:post, "/v1/messages", body) |> IO.iodata_to_binary()

      assert String.ends_with?(encoded, "\n")
      assert Jason.decode!(encoded) == Jason.decode!(hd(ins("messages_text")))
    end

    test "a GET carries no body" do
      encoded = 2 |> Codec.encode_request(:get, "/nope", nil) |> IO.iodata_to_binary()

      assert Jason.decode!(encoded) == Jason.decode!(List.last(ins("out_of_order")))
    end
  end

  describe "messages replies" do
    test "a text reply is parsed and priced on the model that answered" do
      assert {:ok, body} = "messages_text" |> reply(1) |> Codec.result()
      assert {:ok, response} = Codec.parse_messages(body)

      assert response.content == "pong"
      assert response.usage["input_tokens"] == 41
      assert response.usage["output_tokens"] == 4
      assert response.metadata.backend == :omp_gateway
      assert response.metadata.model == @smol
      assert response.metadata.stop_reason == "end_turn"
      assert response.metadata.cost_source == :flat_table
      # claude-haiku at $1 / $5 per Mtok: 41 in, 4 out.
      assert_in_delta response.metadata.cost_usd, (41 * 1.0 + 4 * 5.0) / 1_000_000, 1.0e-12
    end

    test "a tool_use reply carries the tool call" do
      assert {:ok, body} = "messages_tool_use" |> reply(1) |> Codec.result()
      assert {:ok, response} = Codec.parse_messages(body)

      assert response.metadata.stop_reason == "tool_use"

      assert [%{"id" => "toolu_" <> _, "name" => "get_weather", "arguments" => %{"city" => _}}] =
               response.tool_calls
    end

    test "a synthetic message id is tolerated" do
      assert {:ok, %{"id" => "msg_" <> _} = body} = "messages_text" |> reply(1) |> Codec.result()
      assert {:ok, %{content: "pong"}} = Codec.parse_messages(body)
    end

    test "an unpriced model keeps its tokens and is flagged, not free" do
      assert {:ok, body} = "messages_text" |> reply(1) |> Codec.result()

      assert {:ok, response} =
               Codec.parse_messages(%{body | "model" => "acme/unpriced-model"})

      assert response.metadata.cost_usd == nil
      assert response.metadata.cost_source == :unpriced
      assert response.usage["input_tokens"] == 41
    end
  end

  test "replies come back in completion order, correlated by id" do
    ids =
      for line <- tl(outs("out_of_order")) do
        {:ok, %{id: id}} = Codec.decode_response(line)
        id
      end

    assert ids == [2, 1]
  end
end
