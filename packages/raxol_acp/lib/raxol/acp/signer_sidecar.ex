defmodule Raxol.ACP.SignerSidecar do
  @moduledoc """
  Supervises the Node signing sidecar (`priv/signer_sidecar/server.mjs`) as an OS
  process bound to the BEAM's lifetime, and gates solver boot on its health.

  In delegated-signing mode (`Raxol.ACP.ProviderAdapter.Privy`) the raxol_acp release
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
  """

  use GenServer
  require Logger

  @default_port 4048
  @default_health_timeout_ms 20_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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

    case await_health(state.base_url, Keyword.get(opts, :health_timeout_ms, @default_health_timeout_ms)) do
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
    :raxol_acp
    |> Application.app_dir("priv/signer_sidecar/server.mjs")
  end

  # Poll GET /health until 200 or the budget elapses.
  defp await_health(base_url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_health(base_url, deadline)
  end

  defp do_await_health(base_url, deadline) do
    case Req.get(url: base_url <> "/health", retry: false, receive_timeout: 2_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(250)
          do_await_health(base_url, deadline)
        else
          {:error, :health_timeout}
        end
    end
  end
end
