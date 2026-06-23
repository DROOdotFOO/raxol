defmodule Raxol.SSH.ServerTest do
  use ExUnit.Case, async: false

  alias Raxol.SSH.Server

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
         name: :test_ssh_zero}
      )

      Server.unregister_connection(:test_ssh_zero)
      Process.sleep(10)
      assert Server.connection_count(:test_ssh_zero) == 0
    end
  end
end
