defmodule Raxol.Web3.DialTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Outbound
  alias Raxol.Web3.Dial
  alias Raxol.Web3.TestSupport.TLSEndpoint

  # These tests dial loopback, which `Raxol.Core.Outbound` refuses. That is the
  # point of the split and it is asserted at the bottom of this file: the dial
  # holds no policy, so it can be pointed at a local listener, while the
  # guarded path cannot reach one. Testing the handshake through the policy
  # would mean punching a hole in the policy for the tests to walk through.

  defp trust(endpoint), do: [transport_opts: [cacerts: endpoint.cacerts]]

  defp connect(endpoint, addresses, hostname, extra \\ []) do
    Dial.connect(
      addresses,
      hostname,
      [port: endpoint.port, timeout: 5_000] ++ trust(endpoint) ++ extra
    )
  end

  # A request is what makes the `Host` header observable: Mint derives it from
  # the connection's hostname at request time, not at connect time.
  defp request(conn) do
    {:ok, conn, _ref} = Mint.HTTP.request(conn, "GET", "/api/v2/stats", [], nil)
    conn
  end

  describe "identity follows the hostname, not the address" do
    test "SNI and Host carry the hostname while the socket goes to the address" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:ok, conn} = connect(endpoint, [{127, 0, 0, 1}], "pinned.test")
      request(conn)

      assert_receive {:tls_endpoint, %{sni: "pinned.test", host: host, request: request}}, 5_000

      # Mint appends the port when it is not the scheme default, which this one
      # is not. At 443 the header is the bare name.
      assert host == "pinned.test:#{endpoint.port}"
      assert request =~ "GET /api/v2/stats HTTP/1.1"
    end

    test "two hostnames sharing one address each get their own identity" do
      # This is the failure a per-address connection pool produces, and the
      # reason this dial does not pool: the pool key is {scheme, host, port,
      # tag}, so the second hostname would reuse the first's connection and go
      # out under the first's SNI and Host. Both names are on one certificate
      # here because that is what a shared CDN front serves.
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"a.test", ~c"b.test"])

      assert {:ok, first} = connect(endpoint, [{127, 0, 0, 1}], "a.test")
      request(first)
      assert_receive {:tls_endpoint, %{sni: "a.test", host: first_host}}, 5_000

      assert {:ok, second} = connect(endpoint, [{127, 0, 0, 1}], "b.test")
      request(second)
      assert_receive {:tls_endpoint, %{sni: "b.test", host: second_host}}, 5_000

      assert first_host == "a.test:#{endpoint.port}"
      assert second_host == "b.test:#{endpoint.port}"
    end

    test "a hostname the certificate does not cover fails the handshake" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:error, {:dial_failed, [{{127, 0, 0, 1}, reason}]}} =
               connect(endpoint, [{127, 0, 0, 1}], "evil.test")

      assert %Mint.TransportError{} = reason

      # The server saw a handshake and refused it, rather than serving a request
      # to the wrong name.
      assert_receive {:tls_endpoint, {:handshake_failed, _}}, 5_000
      refute_receive {:tls_endpoint, %{sni: _}}, 200
    end

    test "verification is on, so an untrusted certificate is refused" do
      # No `:cacerts`: the peer chains to OTP's generated test root, which the
      # system trust store does not contain.
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:error, {:dial_failed, [{_address, %Mint.TransportError{}}]}} =
               Dial.connect([{127, 0, 0, 1}], "pinned.test",
                 port: endpoint.port,
                 timeout: 5_000
               )
    end
  end

  describe "the address" do
    test "an IPv6 address connects, which a host string of the same address cannot" do
      # A pool keyed by a URL host would carry "::1" as a string, and
      # `:ssl.connect/4` resolves a string with family inet unless told
      # otherwise, so the same address fails as :nxdomain. A tuple carries its
      # own family. The second assertion is the contrast, against the raw
      # socket layer rather than against our code.
      {:ok, endpoint} = TLSEndpoint.start(ip: {0, 0, 0, 0, 0, 0, 0, 1}, sans: [~c"pinned.test"])

      assert {:ok, conn} = connect(endpoint, [{0, 0, 0, 0, 0, 0, 0, 1}], "pinned.test")
      request(conn)
      assert_receive {:tls_endpoint, %{sni: "pinned.test"}}, 5_000

      assert {:error, :nxdomain} =
               :gen_tcp.connect(~c"::1", endpoint.port, [:binary, active: false], 1_000)
    end

    test "a name handed where an address belongs is refused, never resolved" do
      # The whole mechanism of rule 3 is that this function cannot resolve
      # anything. A caller that skipped `Outbound.vet/2` fails closed.
      for not_an_address <- ["pinned.test", "127.0.0.1", ~c"127.0.0.1", {1, 2, 3}, nil] do
        assert {:error, {:not_an_address, ^not_an_address}} =
                 Dial.connect([not_an_address], "pinned.test", port: 443),
               "#{inspect(not_an_address)} was accepted as an address"
      end
    end

    test "one bad address in the list refuses the whole call" do
      {:ok, endpoint} = TLSEndpoint.start()

      assert {:error, {:not_an_address, "pinned.test"}} =
               connect(endpoint, [{127, 0, 0, 1}, "pinned.test"], "pinned.test")
    end

    test "an empty list is refused rather than falling back to the name" do
      assert {:error, :no_addresses} = Dial.connect([], "pinned.test")
    end
  end

  describe "failover across the vetted list" do
    test "tries each address in order and succeeds on a later one" do
      # `Outbound.vet/2` returns every vetted answer because the hosts this
      # package targets answer with three addresses, and pinning one of them
      # would lose the failover `:gen_tcp` performs for a name. The listener is
      # on IPv4 only, so the IPv6 loopback attempt fails first.
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:ok, conn} =
               connect(
                 endpoint,
                 [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}],
                 "pinned.test"
               )

      request(conn)
      assert_receive {:tls_endpoint, %{sni: "pinned.test"}}, 5_000
    end

    test "names every address it attempted when all of them fail" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])
      TLSEndpoint.stop(endpoint)

      assert {:error, {:dial_failed, failures}} =
               connect(
                 endpoint,
                 [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}],
                 "pinned.test",
                 timeout: 500
               )

      assert [{{0, 0, 0, 0, 0, 0, 0, 1}, _}, {{127, 0, 0, 1}, _}] = failures
    end
  end

  describe "transport options that would weaken the handshake" do
    test "are refused rather than merged, and no socket is opened" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      for key <- [:verify, :verify_fun, :server_name_indication, :customize_hostname_check] do
        assert {:error, {:forbidden_transport_opts, [^key]}} =
                 Dial.connect([{127, 0, 0, 1}], "pinned.test",
                   port: endpoint.port,
                   transport_opts: [{key, :anything}]
                 )
      end

      refute_receive {:tls_endpoint, _}, 200
    end

    test "reports every forbidden key, not just the first" do
      assert {:error, {:forbidden_transport_opts, [:server_name_indication, :verify]}} =
               Dial.connect([{127, 0, 0, 1}], "pinned.test",
                 transport_opts: [verify: :verify_none, server_name_indication: ~c"evil.test"]
               )
    end
  end

  describe "composition with the policy" do
    test "the guarded path cannot reach a local endpoint, which is why the dial is tested directly" do
      # Stated as a test rather than as a comment: the reject set refuses
      # loopback, so no arrangement of `Outbound.vet/2` reaches the listener
      # above. The two halves of rule 3 are therefore tested where each lives.
      # `Raxol.Core.OutboundTest` pins the half this one cannot: a resolver that
      # changes its answer between calls yields only the first, checked answer.
      resolver = fn _charlist, family ->
        case family do
          :inet -> {:ok, [{127, 0, 0, 1}]}
          :inet6 -> {:ok, []}
        end
      end

      assert {:error, {:blocked_address, "pinned.test"}} =
               Outbound.vet("https://pinned.test/", resolver: resolver)
    end

    test "a vetted result is dialled without reshaping it" do
      # The seam between the two modules: `vet/2` returns `:addresses` and
      # `:hostname`, and those are exactly `connect/3`'s first two arguments. A
      # caller that has to transform the result is a caller that can transform
      # it wrongly.
      resolver = fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end

      assert {:ok, vetted} = Outbound.vet("https://example.test/", resolver: resolver)
      assert vetted.addresses == [{93, 184, 216, 34}]
      assert vetted.hostname == "example.test"

      # Passed straight through, with no connect attempted: the forbidden-option
      # guard runs before any socket does, so this exercises the argument shapes
      # without touching the network.
      assert {:error, {:forbidden_transport_opts, [:verify]}} =
               Dial.connect(vetted.addresses, vetted.hostname,
                 transport_opts: [verify: :verify_none]
               )
    end
  end
end
