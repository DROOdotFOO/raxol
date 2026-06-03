defmodule Mix.Tasks.RaxolPayments.Echo do
  @shortdoc "Run the x402 self-pay echo server"

  @moduledoc """
  Run `Raxol.Payments.EchoServer` for local agent validation.

      mix raxol_payments.echo --port 4002 --amount 10000

  ## Options

  - `--port` (integer, default 4002)
  - `--amount` (integer atomic units, default 10000 = $0.01 USDC)
  - `--pay-to` (hex address, default deterministic dev address)
  - `--asset` (hex address, default deterministic dev asset)
  - `--network` (CAIP-2, default `eip155:8453` / Base)

  The server runs until you `Ctrl-C` it. Hit `GET /health` for a liveness
  ping; any other path triggers the 402 -> 200 dance.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          port: :integer,
          amount: :integer,
          pay_to: :string,
          asset: :string,
          network: :string
        ]
      )

    server_opts =
      opts
      |> Keyword.take([:port, :amount, :pay_to, :asset, :network])
      |> Keyword.update(:pay_to, nil, &normalize_address/1)
      |> Keyword.update(:asset, nil, &normalize_address/1)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Raxol.Payments.EchoServer.start_link(server_opts) do
      {:ok, _pid} ->
        port = Keyword.get(server_opts, :port, 4002)
        Mix.shell().info("x402 echo listening on http://localhost:#{port} (Ctrl-C to stop)")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start echo server: #{inspect(reason)}")
    end
  end

  defp normalize_address(nil), do: nil
  defp normalize_address("0x" <> _ = addr), do: addr
  defp normalize_address(addr) when is_binary(addr), do: "0x" <> addr
end
