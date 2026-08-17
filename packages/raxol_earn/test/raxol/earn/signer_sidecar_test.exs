defmodule Raxol.Earn.SignerSidecarTest do
  # async: false -- these exercise process-global env vars.
  use ExUnit.Case, async: false

  alias Raxol.Earn.SignerSidecar

  # init/1 opens a Node Port, so the boot tests below stop at the pre-Port checks;
  # the health gate is exercised against a real loopback listener instead.

  @wallet "0x468AEAE798B3a6548ac2401d276f83afdc172283"

  setup do
    prior_url = System.get_env("RAXOL_ACP_SIDECAR_URL")
    prior_port = System.get_env("RAXOL_ACP_SIGNER_PORT")
    System.delete_env("RAXOL_ACP_SIDECAR_URL")
    System.delete_env("RAXOL_ACP_SIGNER_PORT")

    on_exit(fn ->
      restore("RAXOL_ACP_SIDECAR_URL", prior_url)
      restore("RAXOL_ACP_SIGNER_PORT", prior_port)
    end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  describe "base_url/1" do
    test "defaults to loopback on the default port" do
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:4048"
    end

    test "honors an explicit :port" do
      assert SignerSidecar.base_url(port: 5000) == "http://127.0.0.1:5000"
    end

    test "an explicit :base_url wins over the default" do
      assert SignerSidecar.base_url(base_url: "http://sidecar:9000") == "http://sidecar:9000"
    end

    test "falls back to RAXOL_ACP_SIDECAR_URL when no :base_url is given" do
      System.put_env("RAXOL_ACP_SIDECAR_URL", "http://env-host:1234")
      assert SignerSidecar.base_url([]) == "http://env-host:1234"
      # An explicit :base_url still overrides the env.
      assert SignerSidecar.base_url(base_url: "http://opt-host") == "http://opt-host"
    end

    test "the default url uses RAXOL_ACP_SIGNER_PORT" do
      System.put_env("RAXOL_ACP_SIGNER_PORT", "7000")
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:7000"
      # An explicit :port still wins over the env.
      assert SignerSidecar.base_url(port: 8001) == "http://127.0.0.1:8001"
    end
  end

  describe "start_link_or_error/1" do
    test "start_link/1 kills a caller that does not trap exits" do
      {_pid, ref} = spawn_monitor(fn -> SignerSidecar.start_link(boot_failure_opts()) end)

      assert_receive {:DOWN, ^ref, :process, _pid, reason}, 5_000
      assert reason != :normal
    end

    test "the same failure comes back as a reason, leaving the caller alive" do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:result, SignerSidecar.start_link_or_error(boot_failure_opts())})
          Process.sleep(:infinity)
        end)

      assert_receive {:result, {:error, reason}}, 5_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert inspect(reason) =~ "signer sidecar script not found"

      Process.exit(pid, :kill)
    end
  end

  describe "await_health/3" do
    test "no expected address accepts any 200, as before" do
      url = health_listener(~s({"ok":true,"address":"#{@wallet}"}))
      assert SignerSidecar.await_health(url, 2_000) == :ok
    end

    test "the sidecar's own wallet passes, whatever the checksum casing" do
      url = health_listener(~s({"ok":true,"address":"#{String.downcase(@wallet)}"}))
      assert SignerSidecar.await_health(url, 2_000, @wallet) == :ok
    end

    test "a listener answering for another wallet is rejected, not adopted" do
      other = "0x939ead944b5d28b86d91af1961812d3bbc46cac1"
      url = health_listener(~s({"ok":true,"address":"#{other}"}))

      assert SignerSidecar.await_health(url, 2_000, @wallet) ==
               {:error, {:sidecar_wrong_wallet, other, @wallet}}
    end

    test "a 200 that names no wallet is rejected" do
      url = health_listener(~s({"ok":true}))

      assert SignerSidecar.await_health(url, 2_000, @wallet) ==
               {:error, {:sidecar_wrong_wallet, nil, @wallet}}
    end

    test "nothing listening times out" do
      assert SignerSidecar.await_health(health_free_url(), 300, @wallet) ==
               {:error, :health_timeout}
    end
  end

  # A real loopback HTTP listener: the health gate reads a body off the wire, so a
  # stubbed Req would test nothing.
  defp health_listener(body) do
    parent = self()

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    pid =
      spawn(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen)
        send(parent, {:listening, port})
        serve(listen, response)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    receive do
      {:listening, port} -> "http://127.0.0.1:#{port}"
    after
      2_000 -> flunk("health listener never bound a port")
    end
  end

  defp serve(listen, response) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.send(socket, response)
    :ok = :gen_tcp.close(socket)
    serve(listen, response)
  end

  # Bind then release a port, so the url is well-formed and reliably unserved.
  defp health_free_url do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}"
  end

  # Fails in init/1 before the Node Port is opened, so no node runtime is needed.
  defp boot_failure_opts, do: [name: nil, script: "/nonexistent/signer_sidecar/server.mjs"]
end
