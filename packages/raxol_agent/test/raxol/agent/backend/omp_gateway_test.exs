defmodule Raxol.Agent.Backend.OmpGatewayTest do
  # The backend over a real Port, against the generic transcript player
  # (`test/support/gateway_transcript_player.exs`) replaying F1 transcripts
  # recorded from the real gateway. Each test gets its own server and binary.
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.Backend.OmpGateway.Server

  @moduletag :tmp_dir

  @fixtures Path.expand("../../../fixtures/omp/gateway", __DIR__)
  @player Path.expand("../../../support/gateway_transcript_player.exs", __DIR__)
  @smol "anthropic/claude-haiku-5-5"

  # Writes `omp` into the test's tmp dir: a shell script that runs the player
  # on `transcript` in `mode`, so the backend spawns and vets it like the real
  # binary. Rewriting it changes what the NEXT spawn runs.
  defp write_binary(dir, transcript, mode) do
    path = Path.join(dir, "omp")
    elixir = System.find_executable("elixir")
    fixture = Path.join(@fixtures, "#{transcript}.jsonl")

    File.write!(path, """
    #!/bin/sh
    exec '#{elixir}' '#{@player}' '#{fixture}' '#{mode}' "$@"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp start_gateway(dir, transcript, mode) do
    path = write_binary(dir, transcript, mode)
    start_supervised!({Server, name: nil, path: path})
  end

  defp user(text), do: %{role: :user, content: text}

  @weather_tool %{
    name: "get_weather",
    description: "Current weather for a city.",
    input_schema: %{
      type: "object",
      properties: %{city: %{type: "string"}},
      required: ["city"]
    }
  }

  test "a text completion is parsed and priced", %{tmp_dir: dir} do
    server = start_gateway(dir, "messages_text", "play")

    assert {:ok, response} =
             OmpGateway.complete([user("Reply with the single word pong.")],
               model: @smol,
               max_tokens: 16,
               server: server
             )

    assert response.content == "pong"
    assert response.metadata.backend == :omp_gateway
    assert response.metadata.cost_source == :flat_table
    assert response.metadata.cost_usd > 0
  end

  test "a tool_use reply comes back as tool calls", %{tmp_dir: dir} do
    server = start_gateway(dir, "messages_tool_use", "play")

    assert {:ok, response} =
             OmpGateway.complete([user("Call get_weather for Paris.")],
               model: @smol,
               max_tokens: 64,
               tools: [@weather_tool],
               server: server
             )

    assert [%{"name" => "get_weather", "arguments" => %{"city" => _}}] = response.tool_calls
  end

  test "replies in completion order reach their own callers", %{tmp_dir: dir} do
    server = start_gateway(dir, "out_of_order", "play")

    slow =
      Task.async(fn ->
        OmpGateway.complete([user("Count from 1 to 30, separated by spaces.")],
          model: @smol,
          max_tokens: 64,
          server: server
        )
      end)

    fast = Task.async(fn -> OmpGateway.request(:get, "/nope", nil, server: server) end)

    assert {:error, {:http_error, 404, nil}} = Task.await(fast)
    assert {:ok, %{content: "1 2 3" <> _}} = Task.await(slow)
  end

  test "a gateway exit fails the pending caller and the next call restarts it",
       %{tmp_dir: dir} do
    server = start_gateway(dir, "messages_text", "exit-after:1:3")
    messages = [user("Reply with the single word pong.")]
    opts = [model: @smol, max_tokens: 16, server: server]

    assert {:error, {:gateway_exit, 3}} = OmpGateway.complete(messages, opts)

    write_binary(dir, "messages_text", "play")
    assert {:ok, %{content: "pong"}} = OmpGateway.complete(messages, opts)
  end

  test "a request past its deadline times out", %{tmp_dir: dir} do
    server = start_gateway(dir, "messages_text", "never-answer")

    assert {:error, {:gateway_timeout, 200}} =
             OmpGateway.request(:get, "/v1/models", nil, server: server, timeout: 200)
  end

  # The player's teeth: a request the transcript did not record is not
  # answered from it.
  test "a request the transcript did not record is refused by the player", %{tmp_dir: dir} do
    server = start_gateway(dir, "messages_text", "play")

    assert {:error, {:gateway_exit, 97}} =
             OmpGateway.complete([user("something else")],
               model: @smol,
               max_tokens: 16,
               server: server
             )
  end

  describe "the binary" do
    @tag :unix_only
    test "a group-writable binary is refused before it runs", %{tmp_dir: dir} do
      server = start_gateway(dir, "messages_text", "play")
      File.chmod!(Path.join(dir, "omp"), 0o775)

      assert {:error, {:omp_writable, 0o775}} =
               OmpGateway.request(:get, "/v1/models", nil, server: server)
    end

    test "a relative configured path is refused" do
      assert {:error, {:omp_path_not_absolute, "bin/omp"}} = OmpGateway.resolve_binary("bin/omp")
    end

    test "a missing binary is reported as not found", %{tmp_dir: dir} do
      assert {:error, :omp_not_found} = OmpGateway.resolve_binary(Path.join(dir, "absent"))
    end
  end
end
