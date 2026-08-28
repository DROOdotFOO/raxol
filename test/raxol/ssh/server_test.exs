defmodule Raxol.SSH.ServerTest do
  use ExUnit.Case, async: false

  alias Raxol.SSH.Server

  defmodule RecordingApp do
    @moduledoc false
    # Records what Lifecycle actually resolved, so the opts merge is asserted
    # through its real consumer instead of being re-derived in the test.
    def init(%{options: options}) do
      {:ok,
       %{
         cwd: Keyword.get(options, :cwd),
         agent_id: Keyword.get(options, :agent_id),
         environment: Keyword.get(options, :environment)
       }}
    end

    def update(_msg, model), do: {model, []}
    def view(_), do: %{type: :text, content: "ok"}
  end

  describe "authentication (fail-closed)" do
    test "refuses to start with no auth configured" do
      # An SSH surface that can reach payment Actions must not be silently
      # anonymous. With neither allow_anonymous nor authorized_keys_dir, the
      # server refuses to start rather than accepting any connection.
      # start_link links, and a {:stop, _} init propagates an exit signal, so
      # trap it to inspect the {:error, reason} return.
      Process.flag(:trap_exit, true)

      assert {:error, {:ssh_auth_required, _msg}} =
               Server.start_link(app_module: Raxol.Playground.App, port: 0)
    end

    test "allow_anonymous yields no_auth_needed daemon opts" do
      assert {:ok, opts} = Server.auth_daemon_opts(allow_anonymous: true)
      assert opts[:no_auth_needed] == true
    end

    test "authorized_keys_dir yields public-key auth daemon opts" do
      assert {:ok, opts} =
               Server.auth_daemon_opts(authorized_keys_dir: "/etc/raxol/keys")

      assert opts[:user_dir] == ~c"/etc/raxol/keys"
      assert opts[:auth_methods] == ~c"publickey"
      refute Keyword.has_key?(opts, :no_auth_needed)
    end

    test "no auth option fails closed" do
      assert {:error, :ssh_auth_required} = Server.auth_daemon_opts([])
    end

    test "tenants_dir yields per-user public-key auth" do
      assert {:ok, opts} = Server.auth_daemon_opts(tenants_dir: "/srv/tenants")
      assert is_function(opts[:user_dir_fun], 1)
      assert opts[:auth_methods] == ~c"publickey"

      # The fun maps a username to that tenant's key dir…
      assert opts[:user_dir_fun].(~c"alice") ==
               ~c"/srv/tenants/alice/ssh"

      # …and an unsafe username to a path no tenant dir can occupy.
      assert opts[:user_dir_fun].(~c"../root") == ~c"/srv/tenants/.denied"
    end
  end

  describe "tenant username handling" do
    test "sanitize_tenant accepts conservative names only" do
      assert Server.sanitize_tenant("alice") == "alice"
      assert Server.sanitize_tenant("bob-2.dev_x") == "bob-2.dev_x"
      assert Server.sanitize_tenant(~c"carol") == "carol"

      for bad <- [
            "",
            ".",
            "..",
            "../etc",
            "a/b",
            "-leading",
            ".hidden",
            "name with space",
            "nul\0byte",
            # Mixed/upper case is refused, not case-folded: on a
            # case-insensitive filesystem it would share one workspace but mint
            # a second "ssh:<user>" ledger identity.
            "Alice",
            "ALICE",
            "aLICE",
            String.duplicate("a", 65)
          ] do
        assert Server.sanitize_tenant(bad) == nil, "accepted #{inspect(bad)}"
      end
    end

    test "a tenant literally named .denied cannot occupy the refusal path" do
      # ".denied" fails sanitize (leading dot), and even a hypothetical
      # tenant name maps to <name>/ssh — never the bare refusal path.
      assert Server.sanitize_tenant(".denied") == nil

      assert Server.tenant_user_dir("/t", "alice") == "/t/alice/ssh"
      assert Server.tenant_user_dir("/t", "../x") == "/t/.denied"
    end
  end

  describe "host key default" do
    test "default host keys dir is persistent, not /tmp" do
      dir = Server.default_host_keys_dir()
      refute String.starts_with?(dir, "/tmp")
      assert String.contains?(dir, ".raxol")
    end
  end

  # Connection accounting is a pure function so a per-IP flood can be exercised
  # without binding a real SSH daemon.
  describe "connection accounting (admit/release)" do
    @ip_a {203, 0, 113, 1}
    @ip_b {203, 0, 113, 2}

    test "admits under both the global and per-IP caps" do
      assert {:ok, 1, per_ip} = Server.admit(0, %{}, @ip_a, 100, 2)
      assert {:ok, 2, _} = Server.admit(1, per_ip, @ip_a, 100, 2)
    end

    test "refuses a third connection from the same peer, independent of others" do
      per_ip = %{@ip_a => 2}
      # Global cap is far off, but this peer is at its per-IP limit.
      assert {:error, :ip_limit} = Server.admit(2, per_ip, @ip_a, 100, 2)
      # A different peer is unaffected.
      assert {:ok, 3, _} = Server.admit(2, per_ip, @ip_b, 100, 2)
    end

    test "the global cap still takes precedence" do
      assert {:error, :max_connections} = Server.admit(100, %{}, @ip_a, 100, 2)
    end

    test "release frees a global and per-IP slot, dropping empty buckets" do
      assert {1, %{@ip_a => 1}} = Server.release(2, %{@ip_a => 2}, @ip_a)
      assert {0, per_ip} = Server.release(1, %{@ip_a => 1}, @ip_a)
      refute Map.has_key?(per_ip, @ip_a)
    end

    test "release never drops below zero" do
      assert {0, _} = Server.release(0, %{}, @ip_a)
    end
  end

  describe "app_opts threading" do
    test "the CLI handler retains per-server app options for its sessions" do
      {:ok, state} =
        Raxol.SSH.CLIHandler.init(
          app_module: FakeApp,
          app_opts: [ascii: true, system: "be terse"]
        )

      assert state.app_opts == [ascii: true, system: "be terse"]
    end

    test "app_opts default to empty" do
      {:ok, state} = Raxol.SSH.CLIHandler.init(app_module: FakeApp)
      assert state.app_opts == []
    end

    test "connection transport keys win over server app_opts (first-occurrence)" do
      # Session prepends transport wiring, so a served app's app_opts cannot
      # shadow :environment/:io_writer/:width.
      merged =
        Raxol.SSH.Session.lifecycle_opts(:chan, 80, 24,
          app_opts: [environment: :agent, width: 999, model: "m"]
        )

      assert Keyword.get(merged, :environment) == :ssh
      assert Keyword.get(merged, :width) == 80
      assert Keyword.get(merged, :io_writer) == :chan
      # A non-colliding app option still flows through.
      assert Keyword.get(merged, :model) == "m"
    end

    test "tenant opts beat server app_opts but never the transport wiring" do
      merged =
        Raxol.SSH.Session.lifecycle_opts(:chan, 80, 24,
          tenant_opts: [cwd: "/t/alice/work", agent_id: "ssh:alice", width: 5],
          app_opts: [cwd: "/srv/shared", model: "m"]
        )

      # The tenant's jail wins over the server-wide default...
      assert Keyword.get(merged, :cwd) == "/t/alice/work"
      assert Keyword.get(merged, :agent_id) == "ssh:alice"
      # ...but transport keys stay untouchable.
      assert Keyword.get(merged, :width) == 80
      # Non-colliding server options still flow.
      assert Keyword.get(merged, :model) == "m"
    end

    test "a started :ssh Lifecycle initializes with the tenant option" do
      # The merge order only means anything because Lifecycle reads every
      # option with Keyword.get, so assert through the real consumer: the app
      # must come up holding the tenant's identity, not the server-wide one.
      opts =
        Raxol.SSH.Session.lifecycle_opts(fn _ -> :ok end, 40, 10,
          tenant_opts: [cwd: "/t/alice/work", agent_id: "ssh:alice"],
          app_opts: [cwd: "/srv/shared", environment: :agent]
        )

      assert {:ok, pid} =
               Raxol.Core.Runtime.Lifecycle.start_link(RecordingApp, opts)

      try do
        dispatcher = :sys.get_state(pid, 5_000).dispatcher_pid
        model = :sys.get_state(dispatcher, 5_000).model

        assert model.cwd == "/t/alice/work"
        assert model.agent_id == "ssh:alice"
        assert model.environment == :ssh
      after
        Process.unlink(pid)

        try do
          Raxol.Core.Runtime.Lifecycle.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  describe "channel session admission" do
    test "a repeated pty-req resizes instead of starting another session" do
      # One connection registers ONE slot at :ssh_channel_up, so a client that
      # loops pty-req on the same channel could otherwise stand up unbounded
      # sessions inside its single admitted connection -- each orphaning the
      # last, and all of them past max_connections/max_per_ip.
      session = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(session, :kill) end)

      {:ok, state} = Raxol.SSH.CLIHandler.init(app_module: FakeApp)
      state = %{state | session_pid: session, channel_id: 0}

      pty = {:ssh_cm, :conn, {:pty, 0, false, {~c"xterm", 100, 40, 0, 0, []}}}

      assert {:ok, ^state} = Raxol.SSH.CLIHandler.handle_ssh_msg(pty, state)

      # Same session, told to resize.
      assert state.session_pid == session
      assert Process.alive?(session)
    end

    test "the resize reaches the existing session" do
      parent = self()

      session =
        spawn(fn ->
          receive do
            message -> send(parent, {:got, message})
          end
        end)

      {:ok, state} = Raxol.SSH.CLIHandler.init(app_module: FakeApp)
      state = %{state | session_pid: session, channel_id: 0}

      pty = {:ssh_cm, :conn, {:pty, 0, false, {~c"xterm", 120, 50, 0, 0, []}}}
      {:ok, _state} = Raxol.SSH.CLIHandler.handle_ssh_msg(pty, state)

      assert_receive {:got, {:resize, 120, 50}}, 1_000
    end
  end

  describe "host key generation" do
    test "generates RSA host key" do
      dir =
        Path.join(System.tmp_dir!(), "raxol_ssh_test_#{:rand.uniform(100_000)}")

      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)
      refute File.exists?(Path.join(dir, "ssh_host_rsa_key"))

      rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})

      rsa_pem =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
        ])

      File.write!(Path.join(dir, "ssh_host_rsa_key"), rsa_pem)

      assert File.exists?(Path.join(dir, "ssh_host_rsa_key"))
      assert byte_size(rsa_pem) > 100
    end
  end

  describe "connection tracking" do
    @tag :integration
    test "tracks connections and enforces max" do
      port = 22_000 + :rand.uniform(1000)

      dir =
        Path.join(System.tmp_dir!(), "raxol_ssh_conn_#{:rand.uniform(100_000)}")

      on_exit(fn -> File.rm_rf!(dir) end)

      start_supervised!(
        {Server,
         app_module: Raxol.Playground.App,
         port: port,
         host_keys_dir: dir,
         allow_anonymous: true,
         max_connections: 2,
         max_per_ip: 2,
         idle_timeout: 60_000,
         max_session_duration: 60_000,
         name: :test_ssh_server}
      )

      assert Server.connection_count(:test_ssh_server) == 0

      assert :ok = Server.register_connection(:test_ssh_server)
      assert Server.connection_count(:test_ssh_server) == 1

      assert :ok = Server.register_connection(:test_ssh_server)
      assert Server.connection_count(:test_ssh_server) == 2

      assert {:error, :max_connections} =
               Server.register_connection(:test_ssh_server)

      assert Server.connection_count(:test_ssh_server) == 2

      Server.unregister_connection(:test_ssh_server)
      # cast is async, give it a moment
      Process.sleep(10)
      assert Server.connection_count(:test_ssh_server) == 1

      assert :ok = Server.register_connection(:test_ssh_server)
      assert Server.connection_count(:test_ssh_server) == 2
    end

    @tag :integration
    test "unregister does not go below zero" do
      port = 22_000 + :rand.uniform(1000)

      dir =
        Path.join(System.tmp_dir!(), "raxol_ssh_zero_#{:rand.uniform(100_000)}")

      on_exit(fn -> File.rm_rf!(dir) end)

      start_supervised!(
        {Server,
         app_module: Raxol.Playground.App,
         port: port,
         host_keys_dir: dir,
         allow_anonymous: true,
         max_connections: 10,
         max_per_ip: 10,
         idle_timeout: 60_000,
         max_session_duration: 60_000,
         name: :test_ssh_zero}
      )

      Server.unregister_connection(:test_ssh_zero)
      Process.sleep(10)
      assert Server.connection_count(:test_ssh_zero) == 0
    end
  end

  describe "anonymous bind default" do
    test "anonymous binds loopback without a second acknowledgment" do
      # One flag must not carry a surface from laptop demo to public
      # internet: allow_anonymous alone never leaves loopback.
      assert Server.bind_address(allow_anonymous: true) == :loopback
    end

    test "anonymous_public: true is the acknowledgment that binds publicly" do
      assert Server.bind_address(
               allow_anonymous: true,
               anonymous_public: true
             ) == :any
    end

    test "anonymous_public: false pins loopback even with the env var set" do
      System.put_env("RAXOL_SSH_ANONYMOUS_PUBLIC", "1")
      on_exit(fn -> System.delete_env("RAXOL_SSH_ANONYMOUS_PUBLIC") end)

      # The explicit option wins over the environment in both directions.
      assert Server.bind_address(
               allow_anonymous: true,
               anonymous_public: false
             ) == :loopback

      # Without the option, the env var is the deployment-boundary escape
      # hatch.
      assert Server.bind_address(allow_anonymous: true) == :any
    end

    test "key-authenticated surfaces bind all interfaces" do
      assert Server.bind_address(authorized_keys_dir: "/etc/raxol/keys") ==
               :any

      assert Server.bind_address(tenants_dir: "/srv/tenants") == :any
    end
  end

  describe "anonymous resource caps (fail-closed)" do
    test "anonymous without caps names every missing cap" do
      assert Server.missing_anonymous_caps(allow_anonymous: true) == [
               :max_connections,
               :max_per_ip,
               :idle_timeout,
               :max_session_duration
             ]
    end

    test "a non-positive or non-integer cap does not count as stated" do
      missing =
        Server.missing_anonymous_caps(
          allow_anonymous: true,
          max_connections: 0,
          max_per_ip: "10",
          idle_timeout: 300_000,
          max_session_duration: 3_600_000
        )

      assert missing == [:max_connections, :max_per_ip]
    end

    test "a fully-capped anonymous config is complete" do
      assert Server.missing_anonymous_caps(
               allow_anonymous: true,
               max_connections: 50,
               max_per_ip: 10,
               idle_timeout: 300_000,
               max_session_duration: 3_600_000
             ) == []
    end

    test "authenticated surfaces keep their defaults" do
      assert Server.missing_anonymous_caps(authorized_keys_dir: "/keys") == []
    end

    test "start refuses an anonymous surface that omits its caps" do
      Process.flag(:trap_exit, true)

      assert {:error, {:anonymous_caps_required, missing, msg}} =
               Server.start_link(
                 app_module: Raxol.Playground.App,
                 port: 0,
                 allow_anonymous: true
               )

      assert :idle_timeout in missing
      assert msg =~ "resource"
    end
  end

  describe "boot posture line" do
    @posture_base %{
      bind: :loopback,
      port: 2222,
      auth: :none,
      max_connections: 50,
      max_per_ip: 10,
      idle_timeout: 300_000,
      max_session_duration: 3_600_000,
      host_keys_dir: "/app/ssh_keys",
      host_key_algs: ["ed25519"]
    }

    test "states bind, auth, caps, and host keys in one line" do
      assert Server.posture_line(@posture_base) ==
               "[SSH] listening 127.0.0.1:2222 auth=none max_conn=50 " <>
                 "per_ip=10 idle=300s session_max=3600s " <>
                 "host_keys=ed25519(/app/ssh_keys)"
    end

    test "a public anonymous surface says so" do
      line = Server.posture_line(%{@posture_base | bind: :any})
      assert line =~ "listening 0.0.0.0:2222 auth=none"
    end

    test "a keyed surface without session caps prints them as none" do
      line =
        Server.posture_line(%{
          @posture_base
          | auth: :publickey,
            idle_timeout: nil,
            max_session_duration: nil,
            host_key_algs: ["ed25519", "rsa"]
        })

      assert line =~ "auth=publickey"
      assert line =~ "idle=none session_max=none"
      assert line =~ "host_keys=ed25519+rsa(/app/ssh_keys)"
    end
  end

  describe "peer formatting" do
    test "formats IPv4, IPv6, and the unknown bucket" do
      assert Server.format_peer({203, 0, 113, 7}) == "203.0.113.7"

      assert Server.format_peer({0x2A09, 0x8280, 1, 0, 0, 0x9E, 0x475, 0}) ==
               "2a09:8280:1::9e:475:0"

      assert Server.format_peer(:unknown) == "unknown"
    end
  end

  describe "banner probe (protocol, not socket)" do
    defp local_listener do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      {listener, port}
    end

    test "ok only when the peer speaks SSH" do
      {listener, port} = local_listener()

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          :ok = :gen_tcp.send(socket, "SSH-2.0-Test\r\n")
          :gen_tcp.close(socket)
        end)

      assert Server.banner_probe(~c"127.0.0.1", port) == :ok
      Task.await(peer)
    end

    test "accept-then-hang-up is not healthy" do
      # The failure mode the old connect-only health check could not see: a
      # daemon that accepts the socket and says nothing.
      {listener, port} = local_listener()

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          :gen_tcp.close(socket)
        end)

      assert Server.banner_probe(~c"127.0.0.1", port) == {:error, :no_banner}
      Task.await(peer)
    end

    test "a non-SSH banner is not healthy" do
      {listener, port} = local_listener()

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\n")
          :gen_tcp.close(socket)
        end)

      assert Server.banner_probe(~c"127.0.0.1", port) == {:error, :not_ssh}
      Task.await(peer)
    end

    test "a refused connection reports the reason" do
      {listener, port} = local_listener()
      :gen_tcp.close(listener)

      assert {:error, {:connect_failed, _reason}} =
               Server.banner_probe(~c"127.0.0.1", port)
    end
  end

  describe "host keys (generated, never readable)" do
    defp tmp_keys_dir(label) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol_ssh_keys_#{label}_#{:rand.uniform(100_000)}"
        )

      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    test "generates an ed25519 key with owner-only permissions" do
      dir = tmp_keys_dir("gen")

      assert Server.ensure_host_keys(dir) == :ok

      path = Path.join(dir, "ssh_host_ed25519_key")
      assert File.exists?(path)
      assert File.read!(path) =~ "BEGIN PRIVATE KEY"
      assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
      assert Server.host_key_algs(dir) == ["ed25519"]
    end

    test "refuses to serve a group- or world-readable host key" do
      # A readable private host key makes every client's host-key trust
      # forgeable, so boot fails closed instead of serving with it.
      dir = tmp_keys_dir("insecure")
      File.mkdir_p!(dir)
      path = Path.join(dir, "ssh_host_rsa_key")
      File.write!(path, "not-really-a-key")
      File.chmod!(path, 0o644)

      assert Server.ensure_host_keys(dir) ==
               {:error, {:ssh_host_keys_insecure, [path]}}
    end

    test "an existing owner-only key is kept, not regenerated" do
      dir = tmp_keys_dir("keep")
      assert Server.ensure_host_keys(dir) == :ok
      original = File.read!(Path.join(dir, "ssh_host_ed25519_key"))

      assert Server.ensure_host_keys(dir) == :ok
      assert File.read!(Path.join(dir, "ssh_host_ed25519_key")) == original
    end

    test "concurrent first boots converge on one owner-only key" do
      dir = tmp_keys_dir("concurrent")

      results =
        1..12
        |> Task.async_stream(fn _ -> Server.ensure_host_keys(dir) end,
          ordered: false,
          max_concurrency: 12
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, :ok}, &1))

      path = Path.join(dir, "ssh_host_ed25519_key")
      assert File.read!(path) =~ "BEGIN PRIVATE KEY"
      assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
      assert Path.wildcard(path <> ".tmp.*") == []
    end
  end

  describe "anonymous server end to end" do
    test "starts loopback-only with caps and speaks SSH on the bound port" do
      {:ok, _} = Application.ensure_all_started(:ssh)

      dir =
        Path.join(System.tmp_dir!(), "raxol_ssh_e2e_#{:rand.uniform(100_000)}")

      on_exit(fn -> File.rm_rf!(dir) end)

      pid =
        start_supervised!(
          {Server,
           app_module: Raxol.Playground.App,
           port: 0,
           host_keys_dir: dir,
           allow_anonymous: true,
           max_connections: 5,
           max_per_ip: 2,
           idle_timeout: 60_000,
           max_session_duration: 60_000,
           name: :test_ssh_e2e}
        )

      assert Process.alive?(pid)

      # The daemon resolved a real port, generated its ed25519 key, bound
      # loopback, and answers with an SSH banner: the posture the boot line
      # claims is the posture a probe observes.
      port = Server.port(:test_ssh_e2e)
      assert is_integer(port) and port > 0
      assert Server.banner_probe(~c"127.0.0.1", port) == :ok
      assert Server.host_key_algs(dir) == ["ed25519"]
    end
  end
end
