defmodule Raxol.SSH.ServerTest do
  use ExUnit.Case, async: false

  alias Raxol.SSH.Server

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
         max_connections: 2,
         allow_anonymous: true,
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
         max_connections: 10,
         allow_anonymous: true,
         name: :test_ssh_zero}
      )

      Server.unregister_connection(:test_ssh_zero)
      Process.sleep(10)
      assert Server.connection_count(:test_ssh_zero) == 0
    end
  end
end
