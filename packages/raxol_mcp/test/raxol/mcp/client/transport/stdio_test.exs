defmodule Raxol.MCP.Client.Transport.StdioTest do
  # RAXOL_WALLET_KEY is set by no other test in this package's VM and read by
  # nothing in it, so the async run is safe.
  use ExUnit.Case, async: true

  @moduletag :unix_only

  alias Raxol.MCP.Client.Transport.Stdio

  setup do
    previous = System.get_env("RAXOL_WALLET_KEY")
    System.put_env("RAXOL_WALLET_KEY", "probe-not-a-key")

    on_exit(fn ->
      if previous,
        do: System.put_env("RAXOL_WALLET_KEY", previous),
        else: System.delete_env("RAXOL_WALLET_KEY")
    end)
  end

  # A `.mcp.json` server is third-party code; the "server" here is `sh`
  # printing what it inherited, read back through the transport's own decode.
  defp server_sees(env) do
    script = ~s(printf '%s|%s|%s\\n' "${RAXOL_WALLET_KEY-unset}" "${FOO-unset}" "${HOME:+home}")

    assert {:ok, %Stdio{port: port} = handle} =
             Stdio.connect(%{command: "/bin/sh", args: ["-c", script], env: env})

    assert_receive {^port, {:data, {:eol, _}}} = line, 5_000
    assert {:messages, [seen], _handle} = Stdio.decode_info(handle, line)
    assert_receive {^port, {:exit_status, 0}}, 5_000
    seen
  end

  test "a server does not inherit raxol's secrets, but does the rest" do
    assert server_sees([{"FOO", "bar"}]) == "unset|bar|home"
  end

  test "a secret the spec's env names explicitly reaches the server" do
    assert server_sees([{"RAXOL_WALLET_KEY", "given"}]) == "given|unset|home"
  end
end
