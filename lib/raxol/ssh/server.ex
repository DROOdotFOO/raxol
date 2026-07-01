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

  ## Authentication (fail-closed)

  A surface that can reach payment Actions must not be silently anonymous, so
  authentication is required unless anonymous access is explicitly requested:

    * `:allow_anonymous` - `true` accepts any connection (BBS/playground use).
    * `:authorized_keys_dir` - a directory holding an `authorized_keys` file;
      connections must present a listed public key.

  With neither, the server refuses to start.
  """

  use GenServer

  require Raxol.Core.Runtime.Log

  defstruct [
    :daemon_ref,
    :app_module,
    :port,
    :host_keys_dir,
    :max_connections,
    connections: 0
  ]

  @default_port Raxol.Constants.default_ssh_port()
  @default_max_connections 50

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

  @doc "Registers a new connection. Returns :ok or {:error, :max_connections}."
  @spec register_connection(GenServer.server()) ::
          :ok | {:error, :max_connections}
  def register_connection(server \\ __MODULE__) do
    GenServer.call(server, :register_connection)
  end

  @doc "Unregisters a connection when it closes."
  @spec unregister_connection(GenServer.server()) :: :ok
  def unregister_connection(server \\ __MODULE__) do
    GenServer.cast(server, :unregister_connection)
  end

  @impl true
  def init(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    port = Keyword.get(opts, :port, @default_port)
    host_keys_dir = Keyword.get(opts, :host_keys_dir, default_host_keys_dir())

    max_connections =
      Keyword.get(opts, :max_connections, @default_max_connections)

    # Resolve authentication first: refuse to open the daemon at all when the
    # surface would be silently anonymous.
    case auth_daemon_opts(opts) do
      {:ok, auth_opts} ->
        start_daemon(
          app_module,
          port,
          host_keys_dir,
          max_connections,
          auth_opts
        )

      {:error, :ssh_auth_required} ->
        {:stop,
         {:ssh_auth_required,
          "SSH server refused to start: no authentication configured. Pass " <>
            "allow_anonymous: true for anonymous access (e.g. a playground), or " <>
            "authorized_keys_dir: <dir> to require public-key auth."}}
    end
  end

  defp start_daemon(app_module, port, host_keys_dir, max_connections, auth_opts) do
    ensure_host_keys(host_keys_dir)

    daemon_opts =
      [
        system_dir: String.to_charlist(host_keys_dir),
        ssh_cli: {Raxol.SSH.CLIHandler, [app_module: app_module]}
      ] ++ auth_opts

    case :ssh.daemon(port, daemon_opts) do
      {:ok, daemon_ref} ->
        Raxol.Core.Runtime.Log.info(
          "[SSH.Server] Listening on port #{port} for #{inspect(app_module)} (max #{max_connections} connections)"
        )

        {:ok,
         %__MODULE__{
           daemon_ref: daemon_ref,
           app_module: app_module,
           port: port,
           host_keys_dir: host_keys_dir,
           max_connections: max_connections
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
  def handle_call(
        :register_connection,
        _from,
        %__MODULE__{connections: c, max_connections: m} = state
      )
      when c >= m do
    Raxol.Core.Runtime.Log.warning(
      "[SSH.Server] Connection rejected: #{c}/#{m}"
    )

    {:reply, {:error, :max_connections}, state}
  end

  @impl true
  def handle_call(:register_connection, _from, %__MODULE__{} = state) do
    new_count = state.connections + 1

    Raxol.Core.Runtime.Log.info(
      "[SSH.Server] Connection accepted (#{new_count}/#{state.max_connections})"
    )

    {:reply, :ok, %{state | connections: new_count}}
  end

  @impl true
  def handle_cast(:unregister_connection, %__MODULE__{} = state) do
    new_count = max(0, state.connections - 1)
    {:noreply, %{state | connections: new_count}}
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
