defmodule Raxol.CLI.MCPIntegrationTest do
  @moduledoc """
  `raxol mcp` as a real OS process: `mix run` of `Raxol.CLI.main(["mcp"])`
  with `RAXOL_MODE=mcp`, so `config/runtime.exs` boots it the way the
  release does. A unit test supplies frames instead of a process and so cannot
  see what this checks: a byte on stdout that is not JSON-RPC, and the exit
  status at end of input.

  stdin and stderr are FIFOs. A `cat` port writes the client's lines into
  stdin and closing it is end of input (a port cannot close only its child's
  stdin); a second `cat` port reads stderr, which is how output an app writes
  outside the wire is observed arriving somewhere other than stdout.

  Run with:
      mix test --include integration test/raxol/cli/mcp_integration_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  @cli_dir Path.expand("../../..", __DIR__)

  # Booting the whole tree under `mix run` takes seconds; this bounds a hang.
  @reply_ms 120_000

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    input = Path.join(dir, "stdin.fifo")
    errors = Path.join(dir, "stderr.fifo")
    for fifo <- [input, errors], do: {_, 0} = System.cmd("mkfifo", [fifo])

    sh = System.find_executable("sh")

    server =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        cd: @cli_dir,
        args: [
          "-c",
          ~s(exec "$0" run --no-compile --no-deps-check -e "$1" < "$2" 2> "$3"),
          System.find_executable("mix"),
          ~s|System.halt(Raxol.CLI.main(["mcp"]))|,
          input,
          errors
        ],
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"RAXOL_MODE", ~c"mcp"},
          {~c"RAXOL_CLI_INSTALL_DIR", false},
          {~c"__BURRITO", false}
        ]
      ])

    # Not `exec`: the shell keeps the port's stdout open while `cat` writes the
    # FIFO, or the port would close at once on that pipe's end of file.
    writer = Port.open({:spawn_executable, sh}, [:binary, args: ["-c", ~s(cat > "$0"), input]])

    stderr =
      Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, args: [errors]])

    %{server: server, writer: writer, stderr: stderr}
  end

  test "end of input exits 0, and stdout carries only JSON-RPC", ctx do
    send_line(ctx.writer, %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
    {init, seen} = read_reply(ctx.server, 1)
    assert init["result"]["serverInfo"] == %{"name" => "raxol", "version" => Raxol.CLI.version()}

    send_line(ctx.writer, %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})
    {list, listed} = read_reply(ctx.server, 2)
    names = Enum.map(list["result"]["tools"], & &1["name"])
    assert "raxol_start" in names
    assert Enum.filter(names, &String.starts_with?(&1, "harness_")) == []

    path_start = %{"path" => "examples/demo.exs", "id" => "p"}
    send_line(ctx.writer, tool_call(3, "raxol_start", path_start))
    {refused, refusals} = read_reply(ctx.server, 3)
    assert %{"isError" => true, "content" => [%{"text" => text}]} = refused["result"]
    assert %{"error" => "authorization_required", "detail" => detail} = Jason.decode!(text)
    assert detail =~ ~s("path" is refused)

    {status, rest} = end_input(ctx)
    assert status == 0
    assert_json_rpc(seen ++ listed ++ refusals ++ rest)
  end

  test "an app's OSC output reaches stderr, never the wire", ctx do
    send_line(ctx.writer, %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
    {_init, seen} = read_reply(ctx.server, 1)

    demo = %{"module" => "Raxol.Playground.Demos.OscAmbientDemo", "id" => "o"}
    send_line(ctx.writer, tool_call(2, "raxol_start", demo))
    {started, starting} = read_reply(ctx.server, 2)
    refute started["result"]["isError"], inspect(started)

    # Space starts the demo's task, which writes OSC 9;4 progress with IO.write.
    send_line(ctx.writer, tool_call(3, "raxol_send_key", %{"id" => "o", "key" => " "}))
    {keyed, keying} = read_reply(ctx.server, 3)
    refute keyed["result"]["isError"], inspect(keyed)

    # Positive control: the bytes were written, and they went to stderr.
    assert_stderr(ctx.stderr, "\e]9;4;1;", "")

    {status, rest} = end_input(ctx)
    assert status == 0
    assert_json_rpc(seen ++ starting ++ keying ++ rest)
  end

  # -- plumbing ------------------------------------------------------------------

  defp tool_call(id, name, arguments),
    do: %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: name, arguments: arguments}
    }

  defp send_line(writer, message), do: Port.command(writer, [Jason.encode!(message), "\n"])

  # Every stdout line read up to and including the reply to `id`.
  defp read_reply(server, id, seen \\ []) do
    receive do
      {^server, {:data, {:eol, line}}} ->
        seen = [line | seen]

        case Jason.decode(line) do
          {:ok, %{"id" => ^id} = reply} -> {reply, Enum.reverse(seen)}
          _ -> read_reply(server, id, seen)
        end

      {^server, {:data, {:noeol, chunk}}} ->
        flunk("stdout line longer than the port's line buffer: #{String.slice(chunk, 0, 200)}")

      {^server, {:exit_status, status}} ->
        flunk(
          "raxol mcp exited #{status} before replying to #{id}: #{inspect(Enum.reverse(seen))}"
        )
    after
      @reply_ms -> flunk("no reply to #{id}; stdout so far: #{inspect(Enum.reverse(seen))}")
    end
  end

  # Closing the writer ends its `cat`, which closes the FIFO: end of input.
  defp end_input(%{server: server, writer: writer}) do
    Port.close(writer)
    drain(server, [])
  end

  defp drain(server, seen) do
    receive do
      {^server, {:data, {:eol, line}}} -> drain(server, [line | seen])
      {^server, {:data, {:noeol, chunk}}} -> flunk("unterminated stdout: #{chunk}")
      {^server, {:exit_status, status}} -> {status, Enum.reverse(seen)}
    after
      @reply_ms -> flunk("raxol mcp did not exit at end of input")
    end
  end

  defp assert_stderr(stderr, needle, acc) do
    if String.contains?(acc, needle) do
      :ok
    else
      receive do
        {^stderr, {:data, chunk}} -> assert_stderr(stderr, needle, acc <> chunk)
      after
        @reply_ms -> flunk("#{inspect(needle)} never reached stderr; got: #{inspect(acc)}")
      end
    end
  end

  defp assert_json_rpc(lines) do
    assert lines != []

    for line <- lines do
      assert {:ok, %{"jsonrpc" => "2.0"}} = Jason.decode(line), "not JSON-RPC: #{inspect(line)}"
    end
  end
end
