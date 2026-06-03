defmodule Mix.Tasks.RaxolPayments.Anvil do
  @shortdoc "Spin up an anvil fork + echo server for reproducible payment rehearsals"

  @moduledoc """
  Reproducible launch-rehearsal harness. Brings up:

    1. An `anvil` node (local devchain or a fork of a real network)
    2. The x402 echo server (`Raxol.Payments.EchoServer`)

  Both stay running until you `Ctrl-C` the task. Anvil's stdout is
  streamed inline so you can see block production + tx receipts.

      mix raxol_payments.anvil
      mix raxol_payments.anvil --fork-url https://mainnet.base.org
      mix raxol_payments.anvil --anvil-port 8545 --echo-port 4002

  ## Options

  - `--fork-url`     external RPC URL to fork (omit for local devchain)
  - `--anvil-port`   anvil port, default `8545`
  - `--echo-port`    echo server port, default `4002`
  - `--echo-amount`  echo server price in atomic USDC units (default `10_000` = $0.01)
  - `--block-time`   anvil block time in seconds (default `1`)
  - `--chain-id`     chain id, default `31337` (anvil default; ignored when forking)
  - `--no-echo`      skip the echo server (anvil only)

  ## Next steps after start

  In another terminal:

      cd packages/raxol_payments
      export PREFLIGHT_TARGET_URL=http://localhost:4002/anything
      mix run examples/preflight.exs

  ## Requires

  `anvil` on `$PATH` (Foundry). If anvil is missing, the task aborts
  with a clear error before starting anything else.
  """

  use Mix.Task

  alias Raxol.Payments.EchoServer

  @anvil_default_port 8545
  @echo_default_port 4002

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    opts = parse_opts(argv)

    with :ok <- check_anvil_available(),
         {:ok, anvil_port} <- start_anvil(opts),
         :ok <- maybe_start_echo(opts) do
      print_summary(opts, anvil_port)
      Process.sleep(:infinity)
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  # --- option parsing ---

  defp parse_opts(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          fork_url: :string,
          anvil_port: :integer,
          echo_port: :integer,
          echo_amount: :integer,
          block_time: :integer,
          chain_id: :integer,
          no_echo: :boolean
        ]
      )

    [
      fork_url: Keyword.get(opts, :fork_url),
      anvil_port: Keyword.get(opts, :anvil_port, @anvil_default_port),
      echo_port: Keyword.get(opts, :echo_port, @echo_default_port),
      echo_amount: Keyword.get(opts, :echo_amount, 10_000),
      block_time: Keyword.get(opts, :block_time, 1),
      chain_id: Keyword.get(opts, :chain_id, 31_337),
      echo?: not Keyword.get(opts, :no_echo, false)
    ]
  end

  # --- anvil ---

  @doc false
  def check_anvil_available do
    case System.find_executable("anvil") do
      nil -> {:error, :anvil_not_found}
      _path -> :ok
    end
  end

  defp start_anvil(opts) do
    args = anvil_args(opts)
    {:ok, _pid} = Task.start_link(fn -> stream_anvil(args) end)

    # Wait for the JSON-RPC port to accept TCP, then return the port.
    case wait_for_port("127.0.0.1", opts[:anvil_port], 5_000) do
      :ok -> {:ok, opts[:anvil_port]}
      :timeout -> {:error, :anvil_failed_to_start}
    end
  end

  @doc false
  def anvil_args(opts) do
    base = [
      "--port",
      Integer.to_string(opts[:anvil_port]),
      "--block-time",
      Integer.to_string(opts[:block_time])
    ]

    base =
      case opts[:fork_url] do
        nil -> base ++ ["--chain-id", Integer.to_string(opts[:chain_id])]
        url -> base ++ ["--fork-url", url]
      end

    base
  end

  defp stream_anvil(args) do
    port =
      Port.open({:spawn_executable, System.find_executable("anvil")},
        args: args,
        line: 4096
      )

    drain_port(port)
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        IO.puts(["[anvil] ", line])
        drain_port(port)

      {^port, {:data, {:noeol, line}}} ->
        IO.write(["[anvil] ", line])
        drain_port(port)

      {^port, {:exit_status, status}} ->
        IO.puts(:stderr, "[anvil] exited with status #{status}")

      _other ->
        drain_port(port)
    end
  end

  defp wait_for_port(host, port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port(host, port, deadline)
  end

  defp do_wait_for_port(host, port, deadline) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(100)
          do_wait_for_port(host, port, deadline)
        end
    end
  end

  # --- echo server ---

  defp maybe_start_echo(opts) do
    if opts[:echo?] do
      case EchoServer.start_link(port: opts[:echo_port], amount: opts[:echo_amount]) do
        {:ok, _pid} -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  # --- summary ---

  defp print_summary(opts, anvil_port) do
    Mix.shell().info("""

    == anvil rehearsal harness ==
    anvil:       http://127.0.0.1:#{anvil_port}#{fork_label(opts)}
    chain_id:    #{anvil_chain_id(opts)}
    block_time:  #{opts[:block_time]}s
    echo:        #{echo_label(opts)}

    In another terminal, run the preflight:
      cd packages/raxol_payments
      mix run examples/preflight.exs

    Ctrl-C to stop.
    """)
  end

  defp fork_label(opts) do
    case opts[:fork_url] do
      nil -> ""
      url -> "  (forked from #{url})"
    end
  end

  defp anvil_chain_id(opts) do
    case opts[:fork_url] do
      nil -> opts[:chain_id]
      _ -> "matches fork"
    end
  end

  defp echo_label(opts) do
    if opts[:echo?] do
      "http://localhost:#{opts[:echo_port]}  (#{opts[:echo_amount]} atomic units / request)"
    else
      "disabled"
    end
  end

  # --- errors ---

  defp format_error(:anvil_not_found) do
    """
    `anvil` is not on $PATH.

    Install Foundry to get anvil:
      curl -L https://foundry.paradigm.xyz | bash
      foundryup
    """
  end

  defp format_error(:anvil_failed_to_start) do
    "anvil did not bind to its RPC port within 5s -- check the [anvil] log above"
  end

  defp format_error(other), do: inspect(other)
end
