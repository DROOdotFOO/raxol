defmodule Raxol.SSH.Server do
  @moduledoc """
  Serves a Raxol TEA application over SSH.

  Each SSH connection gets its own Lifecycle process running the TEA app,
  with terminal I/O redirected through the SSH channel.

  ## Usage

      Raxol.SSH.serve(CounterExample,
        port: 2222,
        authorized_keys_dir: "/etc/raxol/authorized"
      )

  Then connect: `ssh localhost -p 2222`

  ## Options

    * `:port` - Port to listen on (default: 2222)
    * `:host_keys_dir` - Directory for SSH host keys (default: `~/.raxol/ssh_keys`,
      a persistent path so keys survive restarts)
    * `:max_connections` - Maximum concurrent connections (default: 50;
      REQUIRED explicitly when anonymous)
    * `:max_per_ip` - Maximum concurrent connections from one peer IP (default: 10,
      REQUIRED explicitly when anonymous), so a single host cannot flood the pool
    * `:idle_timeout` - Milliseconds without client input before a session is
      closed (REQUIRED when anonymous; also passed to the daemon as `idle_time`
      for connections holding no channel)
    * `:max_session_duration` - Milliseconds a session may exist before it is
      closed regardless of activity (REQUIRED when anonymous)
    * `:negotiation_timeout` - Milliseconds a connection may spend in key exchange
      and auth before it is dropped (default: 30_000), bounding slow-handshake holds
    * `:anonymous_public` - `true` lets an anonymous server bind non-loopback
      interfaces. Without it (or `RAXOL_SSH_ANONYMOUS_PUBLIC=1`), anonymous
      servers bind loopback only, so one flag cannot carry a surface from
      laptop demo to public internet.

  On boot the server logs one posture line naming the resulting exposure
  (bind address, port, auth mode, caps, host key algorithms), so what was
  deployed is visible in the first log anyone reads.

  ## Authentication (fail-closed)

  A surface that can reach payment Actions must not be silently anonymous, so
  authentication is required unless anonymous access is explicitly requested:

    * `:allow_anonymous` - `true` accepts any connection (BBS/playground use).
      Binds loopback unless `:anonymous_public` acknowledges the exposure, and
      refuses to start unless all four resource caps (`:max_connections`,
      `:max_per_ip`, `:idle_timeout`, `:max_session_duration`) are explicit.
    * `:authorized_keys_dir` - a directory holding an `authorized_keys` file;
      connections must present a listed public key. Single-tenant: every
      keyholder is the same principal regardless of the username they claim.
    * `:tenants_dir` - multi-tenant: keys live per user at
      `<tenants_dir>/<user>/ssh/authorized_keys`, so a key only
      authenticates the username it is filed under (a keyholder cannot
      claim another tenant's name). Usernames are restricted to a
      conservative charset; anything else maps to a directory that cannot
      exist, so auth fails closed.

  With none of these, the server refuses to start.

  ## Per-tenant application options

  `:tenant_opts` - an arity-1 fun of the AUTHENTICATED username returning
  `{:ok, keyword}` (options merged into the connection's app instance,
  winning over the server-level `:app_opts`) or `{:error, reason}` (the
  connection is refused). This is how a multi-tenant host assigns each
  user their own cwd jail, session store, and spending identity.
  """

  use GenServer

  defstruct [
    :daemon_ref,
    :app_module,
    :port,
    :bind,
    :auth,
    :host_keys_dir,
    :max_connections,
    :max_per_ip,
    :idle_timeout,
    :max_session_duration,
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
    tenants_dir = Keyword.get(opts, :tenants_dir)

    cond do
      anonymous? ->
        {:ok, [no_auth_needed: true]}

      is_binary(tenants_dir) ->
        {:ok,
         [
           user_dir_fun: tenant_user_dir_fun(tenants_dir),
           auth_methods: ~c"publickey"
         ]}

      is_binary(keys_dir) ->
        {:ok,
         [user_dir: String.to_charlist(keys_dir), auth_methods: ~c"publickey"]}

      true ->
        {:error, :ssh_auth_required}
    end
  end

  @doc """
  The address the daemon binds, decided from the auth posture.

  Anonymous surfaces bind loopback unless the exposure is separately
  acknowledged with `anonymous_public: true` (or `RAXOL_SSH_ANONYMOUS_PUBLIC=1`
  in the environment), so `allow_anonymous: true` alone can never open a
  surface to the network. Key-authenticated surfaces bind all interfaces.
  """
  @spec bind_address(keyword()) :: :any | :loopback
  def bind_address(opts) do
    anonymous? = Keyword.get(opts, :allow_anonymous, false) == true

    acknowledged? =
      Keyword.get(
        opts,
        :anonymous_public,
        System.get_env("RAXOL_SSH_ANONYMOUS_PUBLIC") == "1"
      ) == true

    if anonymous? and not acknowledged?, do: :loopback, else: :any
  end

  @anonymous_required_caps [
    :max_connections,
    :max_per_ip,
    :idle_timeout,
    :max_session_duration
  ]

  @doc """
  The resource caps an anonymous surface must declare, or the empty list.

  When auth is off, every cap is required explicitly (a positive integer;
  the timeouts are milliseconds) rather than defaulted: fifty concurrent
  anonymous shells must be a stated decision, not an omission. Authenticated
  surfaces keep their defaults and return `[]`.
  """
  @spec missing_anonymous_caps(keyword()) :: [atom()]
  def missing_anonymous_caps(opts) do
    if Keyword.get(opts, :allow_anonymous, false) == true do
      Enum.reject(@anonymous_required_caps, fn key ->
        case Keyword.get(opts, key) do
          n when is_integer(n) and n > 0 -> true
          _ -> false
        end
      end)
    else
      []
    end
  end

  @doc """
  One greppable line stating the security posture this server resolved to:
  bind address, port, auth mode, resource caps, and host key algorithms.
  Logged at boot; the posture is the thing that goes wrong silently, so it
  is said out loud where people already look.
  """
  @spec posture_line(map()) :: String.t()
  def posture_line(%{} = p) do
    "[SSH] listening #{format_bind(p.bind)}:#{p.port}" <>
      " auth=#{p.auth}" <>
      " max_conn=#{p.max_connections} per_ip=#{p.max_per_ip}" <>
      " idle=#{format_cap_ms(p.idle_timeout)}" <>
      " session_max=#{format_cap_ms(p.max_session_duration)}" <>
      " host_keys=#{format_host_keys(p.host_key_algs, p.host_keys_dir)}"
  end

  defp format_bind(:any), do: "0.0.0.0"
  defp format_bind(:loopback), do: "127.0.0.1"
  defp format_bind(ip) when is_tuple(ip), do: to_string(:inet.ntoa(ip))

  defp format_cap_ms(ms) when is_integer(ms) and ms > 0, do: "#{div(ms, 1000)}s"
  defp format_cap_ms(_), do: "none"

  defp format_host_keys([], dir), do: "none(#{dir})"
  defp format_host_keys(algs, dir), do: "#{Enum.join(algs, "+")}(#{dir})"

  @doc """
  A peer address as a loggable string; anything that is not an IP tuple
  (the `:unknown` bucket) is printed as-is rather than crashing a log line.
  """
  @spec format_peer(term()) :: String.t()
  def format_peer(ip) when is_tuple(ip), do: to_string(:inet.ntoa(ip))
  def format_peer(:unknown), do: "unknown"
  def format_peer(other), do: inspect(other)

  @doc """
  Probe an SSH listener by reading its banner, not just opening a socket.

  A daemon that accepts and immediately hangs up is indistinguishable from a
  working one to a bare connect, so a health check built on connect alone
  passes during the outage it exists to catch. `:ok` only when the peer
  actually says `SSH-2.0`.
  """
  @spec banner_probe(
          charlist() | String.t() | :inet.ip_address(),
          :inet.port_number(),
          timeout()
        ) ::
          :ok | {:error, :no_banner | :not_ssh | {:connect_failed, term()}}
  def banner_probe(host, port, timeout \\ 2_000) do
    host = if is_binary(host), do: String.to_charlist(host), else: host

    case :gen_tcp.connect(host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        result =
          case :gen_tcp.recv(socket, 0, timeout) do
            {:ok, <<"SSH-2.0", _::binary>>} -> :ok
            {:ok, _other} -> {:error, :not_ssh}
            {:error, _} -> {:error, :no_banner}
          end

        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  # SSH usernames are client-supplied and become path components: only a
  # conservative charset passes, everything else (traversal shapes,
  # separators, control bytes, over-long names) is refused. Lowercase ONLY:
  # a case-insensitive filesystem (macOS/APFS) folds `Alice` and `alice` onto
  # one directory but "ssh:<user>" would still mint two ledger identities, so
  # the canonical form is single-case and any other casing is refused rather
  # than silently folded onto another principal's keys and workspace.
  @tenant_re ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  @doc """
  Normalize a client-supplied SSH username to a tenant name, or `nil`
  when it is not a safe, canonical path component. Shared with the
  tenant-option derivation so the key lookup and the workspace mapping can
  never disagree about which directory a username names. Names are canonical
  lowercase — a mixed-case username is refused, not case-folded, so one
  principal has exactly one path and one ledger key on every filesystem.
  """
  @spec sanitize_tenant(String.t() | charlist()) :: String.t() | nil
  def sanitize_tenant(user) do
    name = to_string(user)

    if name not in [".", ".."] and Regex.match?(@tenant_re, name) do
      name
    else
      nil
    end
  end

  @doc """
  The per-tenant SSH key directory for `user`:
  `<tenants_dir>/<user>/ssh` (holding that tenant's `authorized_keys`).
  An unsafe username maps to a reserved path no tenant directory can
  ever occupy, so its key lookup fails and auth is refused.
  """
  @spec tenant_user_dir(String.t(), String.t() | charlist()) :: String.t()
  def tenant_user_dir(tenants_dir, user) do
    case sanitize_tenant(user) do
      # `.denied` itself is a valid tenant NAME, but a name maps to
      # `<name>/ssh` — never to this bare path — so no tenant can occupy it.
      nil -> Path.join(tenants_dir, ".denied")
      name -> Path.join([tenants_dir, name, "ssh"])
    end
  end

  defp tenant_user_dir_fun(tenants_dir) do
    fn user ->
      tenants_dir |> tenant_user_dir(user) |> String.to_charlist()
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
  The port the daemon is actually listening on (resolved even when the
  server was started with port 0).
  """
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
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
    # surface would be silently anonymous, and refuse an anonymous surface
    # that has not stated its resource caps.
    with {:ok, auth_opts} <- auth_daemon_opts(opts),
         [] <- missing_anonymous_caps(opts) do
      start_daemon(opts, auth_opts)
    else
      {:error, :ssh_auth_required} ->
        {:stop,
         {:ssh_auth_required,
          "SSH server refused to start: no authentication configured. Pass " <>
            "allow_anonymous: true for anonymous access (e.g. a playground), or " <>
            "authorized_keys_dir: <dir> to require public-key auth."}}

      missing when is_list(missing) ->
        {:stop,
         {:anonymous_caps_required, missing,
          "SSH server refused to start: anonymous access without resource " <>
            "caps. An unauthenticated surface must state its limits; pass " <>
            Enum.map_join(missing, ", ", &"#{&1}:") <>
            " (positive integers, timeouts in milliseconds)."}}
    end
  end

  defp start_daemon(opts, auth_opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    port = Keyword.get(opts, :port, @default_port)
    host_keys_dir = Keyword.get(opts, :host_keys_dir, default_host_keys_dir())
    bind = bind_address(opts)

    max_connections =
      Keyword.get(opts, :max_connections, @default_max_connections)

    max_per_ip = Keyword.get(opts, :max_per_ip, @default_max_per_ip)
    idle_timeout = Keyword.get(opts, :idle_timeout)
    max_session_duration = Keyword.get(opts, :max_session_duration)
    server_name = Keyword.get(opts, :name, __MODULE__)

    negotiation_timeout =
      Keyword.get(opts, :negotiation_timeout, @default_negotiation_timeout_ms)

    case ensure_host_keys(host_keys_dir) do
      :ok ->
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
                 # io_writer) are added per session, and per-TENANT options
                 # (from :tenant_opts, keyed by the authenticated username)
                 # override these.
                 app_opts: Keyword.get(opts, :app_opts, []),
                 tenant_opts: Keyword.get(opts, :tenant_opts),
                 idle_timeout: idle_timeout,
                 max_session_duration: max_session_duration
               ]},
            negotiation_timeout: negotiation_timeout
          ] ++
            idle_time_opt(idle_timeout) ++ auth_opts

        boot_daemon(bind, port, daemon_opts, %__MODULE__{
          app_module: app_module,
          bind: bind,
          auth: auth_mode(auth_opts),
          host_keys_dir: host_keys_dir,
          max_connections: max_connections,
          max_per_ip: max_per_ip,
          idle_timeout: idle_timeout,
          max_session_duration: max_session_duration
        })

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # `idle_time` covers a connection holding no channel; per-session input
  # idleness is enforced by the CLIHandler timer.
  defp idle_time_opt(ms) when is_integer(ms) and ms > 0, do: [idle_time: ms]
  defp idle_time_opt(_), do: []

  defp auth_mode(auth_opts) do
    if Keyword.get(auth_opts, :no_auth_needed) == true,
      do: :none,
      else: :publickey
  end

  defp boot_daemon(bind, port, daemon_opts, state) do
    case :ssh.daemon(bind, port, daemon_opts) do
      {:ok, daemon_ref} ->
        state = %{
          state
          | daemon_ref: daemon_ref,
            port: resolve_port(daemon_ref, port)
        }

        state
        |> Map.from_struct()
        |> Map.put(:host_key_algs, host_key_algs(state.host_keys_dir))
        |> posture_line()
        |> Raxol.Core.Runtime.Log.info()

        {:ok, state}

      {:error, reason} ->
        {:stop, {:ssh_daemon_failed, reason}}
    end
  end

  # Port 0 asks the OS for an ephemeral port; report the one actually bound,
  # so the posture line and `port/1` never claim a port nothing listens on.
  defp resolve_port(daemon_ref, port) do
    case :ssh.daemon_info(daemon_ref) do
      {:ok, info} -> Keyword.get(info, :port, port)
      _ -> port
    end
  end

  @impl true
  def handle_call(:connection_count, _from, state) do
    {:reply, state.connections, state}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
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
          "[SSH] accept peer=#{format_peer(peer_ip)} " <>
            "(#{connections}/#{state.max_connections})"
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

  # File name -> algorithm label, in preference order (ed25519 first).
  @host_key_files [
    {"ssh_host_ed25519_key", "ed25519"},
    {"ssh_host_ecdsa_key", "ecdsa"},
    {"ssh_host_rsa_key", "rsa"},
    {"ssh_host_dsa_key", "dsa"}
  ]

  @doc """
  Ensure `dir` holds a usable host key, generating an ed25519 key (mode 0600)
  when none exists. Fails closed with `{:error, {:ssh_host_keys_insecure, paths}}`
  when any existing key is group- or world-readable: a readable host key means
  every client's host-key trust is forgeable, so the server must not start.
  """
  @spec ensure_host_keys(String.t()) ::
          :ok | {:error, {:ssh_host_keys_insecure, [String.t()]}}
  def ensure_host_keys(dir) do
    File.mkdir_p!(dir)

    case insecure_host_keys(dir) do
      [] ->
        if host_key_algs(dir) == [] do
          Raxol.Core.Runtime.Log.info(
            "[SSH.Server] Generating ed25519 host key in #{dir}"
          )

          generate_host_key(dir)
        end

        :ok

      insecure ->
        {:error, {:ssh_host_keys_insecure, insecure}}
    end
  end

  @doc "Algorithm labels of the host keys present in `dir`, ed25519 first."
  @spec host_key_algs(String.t()) :: [String.t()]
  def host_key_algs(dir) do
    for {file, alg} <- @host_key_files,
        File.exists?(Path.join(dir, file)),
        do: alg
  end

  defp insecure_host_keys(dir) do
    for {file, _alg} <- @host_key_files,
        path = Path.join(dir, file),
        File.exists?(path),
        insecure_mode?(path),
        do: path
  end

  defp insecure_mode?(path) do
    case File.stat(path) do
      # Any group/other bit set makes the private key readable beyond the
      # owner; a stat failure counts as insecure rather than assumed fine.
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o077) != 0
      {:error, _} -> true
    end
  end

  # ed25519 in PKCS#8 PEM, which Erlang's ssh reads directly. (OTP's
  # openssh_key_v1 encoder writes a 32-byte private blob its own decoder
  # rejects, so the experimental format is avoided.) Written 0600 via a
  # unique temp file + atomic hard-link, so no reader ever observes a
  # world-readable key and concurrent boots cannot overwrite each other.
  defp generate_host_key(dir) do
    key = :public_key.generate_key({:namedCurve, :ed25519})

    pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:PrivateKeyInfo, key)
      ])

    path = Path.join(dir, "ssh_host_ed25519_key")
    tmp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      File.write!(tmp, pem, [:write, :exclusive])
      File.chmod!(tmp, 0o600)

      case File.ln(tmp, path) do
        :ok ->
          :ok

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "link", path: path
      end
    after
      _ = File.rm(tmp)
    end
  end
end
