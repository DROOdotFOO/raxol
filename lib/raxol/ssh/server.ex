defmodule Raxol.SSH.Server do
  @moduledoc """
  Serves a Raxol TEA application over SSH.

  Each SSH connection gets its own Lifecycle process running the TEA app,
  with terminal I/O redirected through the SSH channel.

  ## Usage

      Raxol.SSH.serve(CounterExample, port: 2222)

  Then connect: `ssh localhost -p 2222`

  ## Options

    * `:port` - Port to listen on (default: 2222)
    * `:host_keys_dir` - Directory for SSH host keys (default: `~/.raxol/ssh_keys`,
      a persistent path so keys survive restarts)
    * `:max_connections` - Maximum concurrent connections (default: 50)
    * `:max_per_ip` - Maximum concurrent connections from one peer IP (default: 10),
      so a single host cannot flood the pool
    * `:negotiation_timeout` - Milliseconds a connection may spend in key exchange
      and auth before it is dropped (default: 30_000), bounding slow-handshake holds

  ## Authentication (fail-closed)

  A surface that can reach payment Actions must not be silently anonymous, so
  authentication is required unless anonymous access is explicitly requested:

    * `:allow_anonymous` - `true` accepts any connection (BBS/playground use).
    * `:authorized_keys_dir` - a directory holding an `authorized_keys` file;
      connections must present a listed public key.

  With neither, the server refuses to start.
  """

  use GenServer

  defstruct [
    :daemon_ref,
    :app_module,
    :port,
    :host_keys_dir,
    :max_connections,
    :max_per_ip,
    connections: 0,
    per_ip: %{}
  ]

  @default_port Raxol.Constants.default_ssh_port()
  @default_max_connections 50
  @default_max_per_ip 10
  # Cap how long an unauthenticated connection may hold resources during key
  # exchange + auth, so a slow or stalled handshake cannot pin a slot.
  @default_negotiation_timeout_ms 30_000

  @spec serve(module(), keyword()) :: GenServer.on_start()
  def serve(app_module, opts \\ []) do
    start_link([app_module: app_module] ++ opts)
  end

  @doc """
  Default directory for SSH host keys: a persistent per-user path.

  A host key under `/tmp` rotates on reboot, which trains clients to click
  through the host-key-changed warning -- the one warning that matters. Keys
  live under the user's home so they survive restarts.
  """
  @spec default_host_keys_dir() :: String.t()
  def default_host_keys_dir, do: Path.expand("~/.raxol/ssh_keys")

  @doc """
  Build the `:ssh.daemon` authentication options, failing closed.

  Returns `{:ok, opts}` for `allow_anonymous: true` (no auth) or
  `authorized_keys_dir: dir` (public-key auth), and `{:error, :ssh_auth_required}`
  when neither is given so the caller refuses to start an anonymous surface.
  """
  @spec auth_daemon_opts(keyword()) ::
          {:ok, keyword()} | {:error, :ssh_auth_required}
  def auth_daemon_opts(opts) do
    anonymous? = Keyword.get(opts, :allow_anonymous, false) == true
    keys_dir = Keyword.get(opts, :authorized_keys_dir)

    cond do
      anonymous? ->
        {:ok, [no_auth_needed: true]}

      is_binary(keys_dir) ->
        {:ok,
         [user_dir: String.to_charlist(keys_dir), auth_methods: ~c"publickey"]}

      true ->
        {:error, :ssh_auth_required}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current number of active connections."
  @spec connection_count(GenServer.server()) :: non_neg_integer()
  def connection_count(server \\ __MODULE__) do
    GenServer.call(server, :connection_count)
  end

  @doc """
  Registers a new connection from `peer_ip`.

  Returns `:ok`, `{:error, :max_connections}` (global cap), or
  `{:error, :ip_limit}` (this peer already holds `max_per_ip` connections, so a
  single host cannot exhaust the pool).
  """
  @spec register_connection(GenServer.server(), term()) ::
          :ok | {:error, :max_connections | :ip_limit}
  def register_connection(server \\ __MODULE__, peer_ip \\ :unknown) do
    GenServer.call(server, {:register_connection, peer_ip})
  end

  @doc "Unregisters a connection from `peer_ip` when it closes."
  @spec unregister_connection(GenServer.server(), term()) :: :ok
  def unregister_connection(server \\ __MODULE__, peer_ip \\ :unknown) do
    GenServer.cast(server, {:unregister_connection, peer_ip})
  end

  @doc false
  # Pure admission decision: global cap first, then the per-peer cap.
  @spec admit(non_neg_integer(), map(), term(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer(), map()}
          | {:error, :max_connections | :ip_limit}
  def admit(connections, per_ip, peer_ip, max_connections, max_per_ip) do
    cond do
      connections >= max_connections ->
        {:error, :max_connections}

      Map.get(per_ip, peer_ip, 0) >= max_per_ip ->
        {:error, :ip_limit}

      true ->
        {:ok, connections + 1, Map.update(per_ip, peer_ip, 1, &(&1 + 1))}
    end
  end

  @doc false
  # Pure release: frees a global and per-peer slot, never below zero, dropping
  # an emptied per-peer bucket so the map does not grow unbounded.
  @spec release(non_neg_integer(), map(), term()) :: {non_neg_integer(), map()}
  def release(connections, per_ip, peer_ip) do
    new_per_ip =
      case Map.get(per_ip, peer_ip, 0) do
        n when n <= 1 -> Map.delete(per_ip, peer_ip)
        n -> Map.put(per_ip, peer_ip, n - 1)
      end

    {max(0, connections - 1), new_per_ip}
  end

  @impl true
  def init(opts) do
    # Resolve authentication first: refuse to open the daemon at all when the
    # surface would be silently anonymous.
    case auth_daemon_opts(opts) do
      {:ok, auth_opts} ->
        start_daemon(opts, auth_opts)

      {:error, :ssh_auth_required} ->
        {:stop,
         {:ssh_auth_required,
          "SSH server refused to start: no authentication configured. Pass " <>
            "allow_anonymous: true for anonymous access (e.g. a playground), or " <>
            "authorized_keys_dir: <dir> to require public-key auth."}}
    end
  end

  defp start_daemon(opts, auth_opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    port = Keyword.get(opts, :port, @default_port)
    host_keys_dir = Keyword.get(opts, :host_keys_dir, default_host_keys_dir())

    max_connections =
      Keyword.get(opts, :max_connections, @default_max_connections)

    max_per_ip = Keyword.get(opts, :max_per_ip, @default_max_per_ip)
    server_name = Keyword.get(opts, :name, __MODULE__)

    negotiation_timeout =
      Keyword.get(opts, :negotiation_timeout, @default_negotiation_timeout_ms)

    ensure_host_keys(host_keys_dir)

    daemon_opts =
      [
        system_dir: String.to_charlist(host_keys_dir),
        ssh_cli:
          {Raxol.SSH.CLIHandler,
           [
             app_module: app_module,
             server: server_name,
             # Per-server app options, passed into every connection's app
             # instance (`context.options`); connection-scoped values (size,
             # io_writer) are added per session.
             app_opts: Keyword.get(opts, :app_opts, [])
           ]},
        negotiation_timeout: negotiation_timeout
      ] ++ auth_opts

    case :ssh.daemon(port, daemon_opts) do
      {:ok, daemon_ref} ->
        Raxol.Core.Runtime.Log.info(
          "[SSH.Server] Listening on port #{port} for #{inspect(app_module)} (max #{max_connections} connections, #{max_per_ip}/peer)"
        )

        {:ok,
         %__MODULE__{
           daemon_ref: daemon_ref,
           app_module: app_module,
           port: port,
           host_keys_dir: host_keys_dir,
           max_connections: max_connections,
           max_per_ip: max_per_ip
         }}

      {:error, reason} ->
        {:stop, {:ssh_daemon_failed, reason}}
    end
  end

  @impl true
  def handle_call(:connection_count, _from, state) do
    {:reply, state.connections, state}
  end

  @impl true
  def handle_call({:register_connection, peer_ip}, _from, %__MODULE__{} = state) do
    case admit(
           state.connections,
           state.per_ip,
           peer_ip,
           state.max_connections,
           state.max_per_ip
         ) do
      {:ok, connections, per_ip} ->
        Raxol.Core.Runtime.Log.info(
          "[SSH.Server] Connection accepted (#{connections}/#{state.max_connections})"
        )

        {:reply, :ok, %{state | connections: connections, per_ip: per_ip}}

      {:error, reason} = err ->
        Raxol.Core.Runtime.Log.warning(
          "[SSH.Server] Connection rejected (#{reason}): #{state.connections}/#{state.max_connections}, peer #{inspect(peer_ip)}"
        )

        {:reply, err, state}
    end
  end

  @impl true
  def handle_cast({:unregister_connection, peer_ip}, %__MODULE__{} = state) do
    {connections, per_ip} = release(state.connections, state.per_ip, peer_ip)
    {:noreply, %{state | connections: connections, per_ip: per_ip}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{daemon_ref: ref}) when not is_nil(ref) do
    :ssh.stop_daemon(ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ensure_host_keys(dir) do
    File.mkdir_p!(dir)
    host_key_path = Path.join(dir, "ssh_host_rsa_key")

    unless File.exists?(host_key_path) do
      Raxol.Core.Runtime.Log.info("[SSH.Server] Generating host keys in #{dir}")
      generate_host_key(dir)
    end
  end

  defp generate_host_key(dir) do
    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})

    rsa_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
      ])

    File.write!(Path.join(dir, "ssh_host_rsa_key"), rsa_pem)
  end
end
