defmodule Raxol.Earn.SignerSidecar do
  @moduledoc """
  Supervises the Node signing sidecar (`priv/signer_sidecar/server.mjs`) as an OS
  process bound to the BEAM's lifetime, and gates solver boot on its health.

  In delegated-signing mode (`Raxol.Earn.ProviderAdapter.Privy`) the raxol_earn release
  holds no key; it signs/settles by calling this sidecar over `127.0.0.1`. The sidecar
  wraps `@virtuals-protocol/acp-node-v2`'s `PrivyAlchemyEvmProviderAdapter`. This
  GenServer:

    * opens a `Port` to `node server.mjs`, so the sidecar dies with the BEAM (the port
      closes stdin on shutdown, which the sidecar treats as a shutdown signal);
    * blocks `init/1` until the sidecar answers `GET /health` 200, so the supervision
      tree is only "started" once signing is actually available;
    * relays the sidecar's stdout/stderr to `Logger` (its logs are the only signal on a
      node with no inbound port);
    * crashes (and is restarted by its supervisor) if the sidecar exits -- under the
      solver's `:rest_for_one`, that also restarts `Auth`/`Agent` downstream so they
      reconnect against a fresh signer.

  The P-256 authorization key and wallet identifiers are read from the environment by
  the sidecar itself (inherited from the BEAM's env); this GenServer never reads them.

  ## Options

  - `:base_url` -- sidecar URL (default from `RAXOL_ACP_SIDECAR_URL`, else
    `http://127.0.0.1:<port>`).
  - `:port` -- sidecar listen port (default `RAXOL_ACP_SIGNER_PORT` or `4048`).
  - `:node_path` -- node executable (default: `System.find_executable("node")`).
  - `:script` -- server.mjs path (default: this app's `priv/signer_sidecar/server.mjs`).
  - `:health_timeout_ms` -- boot health-wait budget (default `20_000`).
  - `:expect_address` -- the wallet `GET /health` must report (default
    `RAXOL_ACP_WALLET_ADDRESS`). A listener answering for another wallet is
    rejected rather than adopted as the signer.
  """

  use GenServer
  require Logger

  @default_port 4048
  # Generous margin: on a cold, cpu-constrained VM the node process must spawn and
  # `import` the acp-node-v2 SDK (~185 modules) before it answers /health.
  @default_health_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Start the sidecar for a caller that does not trap exits, such as a Mix task.

  `start_link/1` cannot report a boot failure to such a caller: `init/1` exits,
  and the link delivers that exit signal before the `{:error, _}` return value is
  ever inspected, so the caller dies with an opaque `** (EXIT from ...)`. This
  traps exits for the duration of the start and hands the reason back. The link
  is left intact on success, so a sidecar that dies later still takes the caller
  with it.
  """
  @spec start_link_or_error(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link_or_error(opts \\ []) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      opts |> start_link() |> settle()
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  # Already running: no child was spawned, so there is no exit signal to collect.
  defp settle({:error, {:already_started, pid}}), do: {:ok, pid}

  # `init_fail/3` acks the caller before the child exits, so the signal lands just
  # after start_link returns. Wait for it: leaving it queued would surface later as
  # a stray message, or vanish once the flag is restored.
  defp settle({:error, reason}) do
    receive do
      {:EXIT, _pid, _} -> :ok
    after
      1_000 -> :ok
    end

    {:error, reason}
  end

  # A sidecar that died in this window has already been converted to a message that
  # restoring the flag cannot turn back into a kill, so report it rather than lose it.
  defp settle({:ok, pid}) do
    receive do
      {:EXIT, ^pid, reason} -> {:error, reason}
    after
      0 -> {:ok, pid}
    end
  end

  @doc "The sidecar base URL for the given (or default) options."
  @spec base_url(keyword()) :: String.t()
  def base_url(opts \\ []) do
    Keyword.get(opts, :base_url) || System.get_env("RAXOL_ACP_SIDECAR_URL") ||
      "http://127.0.0.1:#{port(opts)}"
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    node_path =
      Keyword.get(opts, :node_path) || System.find_executable("node") ||
        raise("node executable not found on PATH (required for the signing sidecar)")

    script = Keyword.get(opts, :script, default_script())
    File.exists?(script) || raise("signer sidecar script not found: #{script}")

    port =
      Port.open(
        {:spawn_executable, node_path},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, [script]},
          {:env, [{~c"RAXOL_ACP_SIGNER_PORT", ~c"#{port(opts)}"}]},
          {:line, 4096}
        ]
      )

    state = %{port: port, base_url: base_url(opts)}

    case await_health(
           state.base_url,
           Keyword.get(opts, :health_timeout_ms, @default_health_timeout_ms),
           expect_address(opts)
         ) do
      :ok ->
        Logger.info("signer sidecar healthy at #{state.base_url}")
        {:ok, state}

      {:error, reason} ->
        {:stop, {:sidecar_unhealthy, reason}}
    end
  end

  @impl true
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state) do
    Logger.info("[signer] #{line}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:sidecar_exited, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:sidecar_port_closed, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    # Closing the port sends EOF on the sidecar's stdin, which it treats as a
    # shutdown signal -- so the node process does not outlive the BEAM.
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  # -- Internals --

  defp port(opts) do
    Keyword.get(opts, :port) ||
      case System.get_env("RAXOL_ACP_SIGNER_PORT") do
        nil -> @default_port
        s -> String.to_integer(s)
      end
  end

  defp default_script do
    :raxol_earn
    |> Application.app_dir("priv/signer_sidecar/server.mjs")
  end

  # The sidecar reads this env itself, so it is also what the sidecar will report.
  defp expect_address(opts) do
    Keyword.get(opts, :expect_address) || System.get_env("RAXOL_ACP_WALLET_ADDRESS")
  end

  # Poll GET /health until the sidecar answers as `expect_address`, or the budget
  # elapses. Public so the identity gate is testable against a real loopback
  # listener, without a node runtime.
  @doc false
  @spec await_health(String.t(), non_neg_integer(), String.t() | nil) :: :ok | {:error, term()}
  def await_health(base_url, timeout_ms, expect_address \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_health(base_url, deadline, expect_address)
  end

  defp do_await_health(base_url, deadline, expect) do
    case Req.get(url: base_url <> "/health", retry: false, receive_timeout: 2_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> check_identity(body, expect)
      _ -> retry_health(base_url, deadline, expect)
    end
  end

  # A 200 is only liveness. An orphaned sidecar (or any other process) holding the
  # port would otherwise become the money-path signer while callers keep reporting
  # the configured wallet, so the reported wallet has to match -- and a mismatch
  # never becomes a match by waiting, so it is returned rather than retried.
  defp check_identity(_body, nil), do: :ok

  defp check_identity(%{"address" => got}, want) when is_binary(got) do
    case String.downcase(got) == String.downcase(want) do
      true -> :ok
      false -> {:error, {:sidecar_wrong_wallet, got, want}}
    end
  end

  defp check_identity(_body, want), do: {:error, {:sidecar_wrong_wallet, nil, want}}

  defp retry_health(base_url, deadline, expect) do
    case System.monotonic_time(:millisecond) < deadline do
      true ->
        Process.sleep(250)
        do_await_health(base_url, deadline, expect)

      false ->
        {:error, :health_timeout}
    end
  end
end
