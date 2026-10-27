defmodule Raxol.Agent.Backend.OmpGatewayTest do
  # The backend over a real Port, against the generic transcript player
  # (`test/support/gateway_transcript_player.exs`) replaying F1 transcripts
  # recorded from the real gateway. Each test gets its own server and binary.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.Backend.OmpGateway.Codec
  alias Raxol.Agent.Backend.OmpGateway.Server
  alias Raxol.Agent.OMP.Version

  @moduletag :tmp_dir

  @fixtures Path.expand("../../../fixtures/omp/gateway", __DIR__)
  @player Path.expand("../../../support/gateway_transcript_player.exs", __DIR__)
  @smol "anthropic/claude-haiku-5-5"

  defp write_binary(dir, transcript, mode),
    do: write_player(dir, Path.join(@fixtures, "#{transcript}.jsonl"), mode)

  # Writes `omp` into the test's tmp dir: a shell script that runs the player
  # on `fixture` in `mode`, so the backend spawns and vets it like the real
  # binary. Rewriting it changes what the NEXT spawn runs.
  defp write_player(dir, fixture, mode) do
    path = Path.join(dir, "omp")
    elixir = System.find_executable("elixir")

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

  @tag skip: Elixir.Version.parse!(Version.tested()).minor == 0 && "the pin has no lower minor"
  test "a ready line a minor below the pin logs a warning and serves the request",
       %{tmp_dir: dir} do
    %{major: major, minor: minor} = Elixir.Version.parse!(Version.tested())
    older = "#{major}.#{minor - 1}.0"
    recorded = File.read!(Path.join(@fixtures, "messages_text.jsonl"))
    # The model fixture keeps the version it was recorded with, which can predate the pin.
    [_header, ready_event | _] = String.split(recorded, "\n", trim: true)
    %{"out" => ready_line} = Jason.decode!(ready_event)
    %{"version" => recorded_version} = Jason.decode!(ready_line)
    ready_version = ~s(\\"version\\":\\"#{recorded_version}\\")
    assert [_, _] = String.split(recorded, ready_version)

    fixture = Path.join(dir, "older_minor.jsonl")

    File.write!(
      fixture,
      String.replace(recorded, ready_version, ~s(\\"version\\":\\"#{older}\\"))
    )

    server = start_supervised!({Server, name: nil, path: write_player(dir, fixture, "play")})

    log =
      capture_log(fn ->
        assert {:ok, %{content: "pong"}} =
                 OmpGateway.complete([user("Reply with the single word pong.")],
                   model: @smol,
                   max_tokens: 16,
                   server: server
                 )
      end)

    assert log =~ "omp #{older} is older than the tested #{Version.tested()}; continuing"
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

  describe "a bad request fails only its own caller" do
    test "a body that cannot be JSON is refused while another request stays pending",
         %{tmp_dir: dir} do
      server = start_gateway(dir, "out_of_order", "play")

      slow =
        Codec.messages_body([user("Count from 1 to 30, separated by spaces.")],
          model: @smol,
          max_tokens: 64
        )

      # Sent from this process, so the barrier below is ordered after it: the
      # request is pending in the server before the bad one is made. The
      # player answers it only once the `/nope` request below arrives.
      {:ok, encoded} = Codec.encode_request(:post, "/v1/messages", slow)
      pending = :gen_server.send_request(server, {:request, encoded, 60_000})
      _ = :sys.get_state(server)

      assert {:error, {:invalid_request, Jason.EncodeError}} =
               OmpGateway.complete([user(<<"tool output ", 0xFF>>)],
                 model: @smol,
                 max_tokens: 16,
                 server: server
               )

      assert {:error, {:http_error, 404, nil}} =
               OmpGateway.request(:get, "/nope", nil, server: server)

      assert {:reply, {:ok, response}} = :gen_server.receive_response(pending, 60_000)
      assert {:ok, body} = Codec.result(response)
      assert {:ok, %{content: "1 2 3" <> _}} = Codec.parse_messages(body)
    end

    test "a timeout that is not a timer value is refused without reaching the server" do
      # No server by this name: anything that reached one would be
      # `:gateway_not_started`.
      opts = [server: :"omp_gateway_absent_#{System.unique_integer([:positive])}"]

      for timeout <- [:infinity, -1, 1.5, 4_294_967_296] do
        assert {:error, {:invalid_request, :timeout}} =
                 OmpGateway.request(:get, "/v1/models", nil, [timeout: timeout] ++ opts)
      end

      assert {:error, :gateway_not_started} = OmpGateway.request(:get, "/v1/models", nil, opts)
    end

    test "a missing model is refused without reaching the server" do
      opts = [server: :"omp_gateway_absent_#{System.unique_integer([:positive])}"]

      assert {:error, :model_required} = OmpGateway.complete([user("hi")], opts)
      assert {:error, :model_required} = OmpGateway.complete([user("hi")], [model: nil] ++ opts)

      assert {:error, :gateway_not_started} =
               OmpGateway.complete([user("hi")], [model: @smol] ++ opts)
    end

    test "the server's status shows no request body", %{tmp_dir: dir} do
      server = start_gateway(dir, "messages_text", "never-answer")
      secret = "do-not-log-#{System.unique_integer([:positive])}"

      {:ok, encoded} = Codec.encode_request(:post, "/v1/messages", %{content: secret})
      _pending = :gen_server.send_request(server, {:request, encoded, 60_000})
      _ = :sys.get_state(server)

      status =
        server |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

      refute status =~ secret
      assert status =~ "pending: 1"

      redacted = Server.format_status(%{message: {:request, encoded, 60_000}})
      refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ secret
    end
  end

  describe "the binary" do
    @tag :unix_only
    test "a group-writable binary is refused before it runs", %{tmp_dir: dir} do
      server = start_gateway(dir, "messages_text", "play")
      File.chmod!(Path.join(dir, "omp"), 0o775)

      assert {:error, {:omp_writable, 0o775}} =
               OmpGateway.request(:get, "/v1/models", nil, server: server)
    end

    @tag :unix_only
    test "a binary in a directory others may write is refused", %{tmp_dir: dir} do
      shared = Path.join(dir, "shared")
      File.mkdir!(shared)
      path = write_binary(shared, "messages_text", "play")
      File.chmod!(shared, 0o777)

      assert {:error, {:omp_dir_untrusted, ^shared, {:dir_group_or_other_writable, 0o777}}} =
               OmpGateway.resolve_binary(path)
    end

    @tag :unix_only
    test "a binary in a sticky directory others may write is accepted", %{tmp_dir: dir} do
      sticky = Path.join(dir, "sticky")
      File.mkdir!(sticky)
      path = write_binary(sticky, "messages_text", "play")
      # `File.chmod!/2` drops the sticky bit (observed on macOS); chmod(1) keeps it.
      {_, 0} = System.cmd("chmod", ["1777", sticky])

      assert {:ok, ^path} = OmpGateway.resolve_binary(path)
    end

    @tag :unix_only
    test "a symlink is vetted in its own directory as well as its target's", %{tmp_dir: dir} do
      target = write_binary(dir, "messages_text", "play")
      shared = Path.join(dir, "shared")
      File.mkdir!(shared)
      link = Path.join(shared, "omp")
      File.ln_s!(target, link)

      assert {:ok, ^link} = OmpGateway.resolve_binary(link)

      File.chmod!(shared, 0o777)

      assert {:error, {:omp_dir_untrusted, ^shared, {:dir_group_or_other_writable, 0o777}}} =
               OmpGateway.resolve_binary(link)
    end

    test "a relative configured path is refused" do
      assert {:error, {:omp_path_not_absolute, "bin/omp"}} = OmpGateway.resolve_binary("bin/omp")
    end

    test "a missing binary is reported as not found", %{tmp_dir: dir} do
      assert {:error, :omp_not_found} = OmpGateway.resolve_binary(Path.join(dir, "absent"))
    end
  end
end
