defmodule Raxol.Gateway.Adapter.Discord.GatewaySocket.MintTransportTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Discord.GatewaySocket.MintTransport

  # "%zz" is not a valid request target: Mint opens the TCP connection, then
  # refuses the upgrade request with `{:error, conn, reason}` -- a real
  # upgrade failure that hands back a live socket. The socket reconnects on
  # every such failure, so each attempt must release what it opened.
  test "an upgrade failure closes every connection it was handed" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parts = %{scheme: :ws, host: "127.0.0.1", port: port, path: "/%zz"}

    for _attempt <- 1..3 do
      assert {:error, %Mint.HTTPError{reason: {:invalid_request_target, "/%zz"}}} =
               MintTransport.connect(parts, [])

      {:ok, server_side} = :gen_tcp.accept(listener, 1_000)

      # The recv timeout is the hang bound for a leaked (still open) socket.
      assert :gen_tcp.recv(server_side, 0, 1_000) == {:error, :closed}
    end
  end
end
