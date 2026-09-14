defmodule Raxol.Core.OutboundTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Outbound

  # No test here touches the real resolver except through an IP literal, which
  # never reaches it. Names are resolved through an injected `:resolver`, which
  # is what makes "the resolver changed its answer" expressible at all.

  defp resolver(answers) do
    fn _charlist, family -> {:ok, Map.get(answers, family, [])} end
  end

  defp failing_resolver do
    fn _charlist, _family -> {:error, :nxdomain} end
  end

  describe "scheme policy" do
    test "defaults to https only, so a new caller cannot reach cleartext by omission" do
      assert {:error, :invalid_url} = Outbound.vet("http://93.184.216.34/")

      assert {:ok, %{hostname: "93.184.216.34"}} =
               Outbound.vet("https://93.184.216.34/")
    end

    test "an explicit scheme list is honoured, which is how the fetch tool keeps http" do
      assert {:ok, %{uri: %URI{scheme: "http"}}} =
               Outbound.vet("http://93.184.216.34/", schemes: [:http, :https])
    end

    test "refuses anything that is not an absolute URL with a host" do
      for url <- [
            "file:///etc/passwd",
            "ftp://93.184.216.34/",
            "/relative/path",
            "https:///nohost",
            "not a url",
            ""
          ] do
        assert {:error, :invalid_url} = Outbound.vet(url, schemes: [:http, :https]),
               "#{inspect(url)} was not refused"
      end
    end

    test "refuses a non-binary url rather than raising" do
      assert {:error, :invalid_url} = Outbound.vet(nil)
      assert {:error, :invalid_url} = Outbound.vet(%URI{host: "example.com"})
    end
  end

  describe "reject set" do
    test "refuses a loopback, private, link-local or CGNAT literal" do
      for url <- [
            "https://127.0.0.1/secrets",
            "https://10.0.0.5/",
            "https://172.16.0.1/",
            "https://192.168.1.1/",
            "https://169.254.169.254/latest/meta-data/",
            "https://100.64.0.1/",
            "https://0.0.0.0/",
            "https://255.255.255.255/",
            "https://[::1]/",
            "https://[::]/",
            "https://[fd00::1]/",
            "https://[fe80::1]/"
          ] do
        assert {:error, {:blocked_address, _host}} = Outbound.vet(url),
               "#{url} was not refused"
      end
    end

    test "every v6 form that embeds a v4 address is decomposed and refused" do
      # Each of these is a working route to the cloud metadata address or to
      # loopback, and each reaches a different clause of the table. A
      # reimplementation that handles only `::ffff:` passes none of them but the
      # first.
      for {label, url} <- [
            {"IPv4-mapped", "https://[::ffff:169.254.169.254]/latest/meta-data/"},
            {"IPv4-compatible", "https://[::127.0.0.1]/"},
            {"IPv4-translated (RFC 2765)",
             "https://[::ffff:0:169.254.169.254]/latest/meta-data/"},
            {"NAT64 /96 (RFC 6052)", "https://[64:ff9b::169.254.169.254]/"},
            {"NAT64 local-use (RFC 8215)", "https://[64:ff9b:1::169.254.169.254]/"},
            {"6to4 to metadata (RFC 3056)", "https://[2002:a9fe:a9fe::]/"},
            {"6to4 to loopback", "https://[2002:7f00:1::]/"},
            {"Teredo", "https://[2001:0:1234::1]/"}
          ] do
        assert {:error, {:blocked_address, _host}} = Outbound.vet(url),
               "#{label} was not refused"
      end
    end

    test "a public v6 address is still allowed" do
      # The table must not have become "refuse all IPv6": 6to4, NAT64 and the
      # fc00/fe80/ff00 bitmask are prefix matches, and an over-broad one would
      # be invisible against v4-only cases.
      refute Outbound.blocked?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
      refute Outbound.blocked?({0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 0})

      assert {:ok, _vetted} = Outbound.vet("https://[2606:4700:4700::1111]/")
    end

    test "anything that is not an address tuple fails closed" do
      for not_an_address <- [nil, :inet, "127.0.0.1", {1, 2, 3}, {1, 2, 3, 4, 5}] do
        assert Outbound.blocked?(not_an_address),
               "#{inspect(not_an_address)} was treated as connectable"
      end
    end
  end

  describe "resolution" do
    test "refuses when ANY answer is rejected, not when the first is" do
      # The ordering matters: a host whose public record is returned first must
      # still be refused for its loopback record, or reachability depends on
      # resolver ordering.
      answers = %{inet: [{93, 184, 216, 34}, {127, 0, 0, 1}], inet6: []}

      assert {:error, {:blocked_address, "mixed.example"}} =
               Outbound.vet("https://mixed.example/", resolver: resolver(answers))
    end

    test "a host with only AAAA records is resolved rather than failing DNS" do
      answers = %{inet: [], inet6: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]}

      assert {:ok, %{addresses: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]}} =
               Outbound.vet("https://v6only.example/", resolver: resolver(answers))
    end

    test "a blocked AAAA record refuses a host whose A record is public" do
      answers = %{inet: [{93, 184, 216, 34}], inet6: [{0, 0, 0, 0, 0, 0, 0, 1}]}

      assert {:error, {:blocked_address, _host}} =
               Outbound.vet("https://dual.example/", resolver: resolver(answers))
    end

    test "no answer in either family is a DNS failure, not a block" do
      assert {:error, {:dns_failed, "nowhere.example"}} =
               Outbound.vet("https://nowhere.example/", resolver: failing_resolver())
    end
  end

  describe "the returned addresses" do
    test "carries every vetted answer in resolution order, A before AAAA" do
      answers = %{
        inet: [{93, 184, 216, 34}, {93, 184, 216, 35}],
        inet6: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]
      }

      assert {:ok, vetted} = Outbound.vet("https://many.example/", resolver: resolver(answers))

      assert vetted.addresses == [
               {93, 184, 216, 34},
               {93, 184, 216, 35},
               {0x2606, 0x4700, 0, 0, 0, 0, 0, 1}
             ]
    end

    test "is what a pinning caller dials, so a resolver that changes its answer is not consulted twice" do
      # This is rule 3's precondition. `vet/2` cannot enforce the dial, but it
      # can guarantee the caller is handed the addresses that were CHECKED
      # rather than a name to look up again. A resolver that answers publicly
      # once and privately afterwards must not leak the second answer into the
      # result.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      flipping = fn _charlist, family ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})

        case {family, n} do
          {:inet, 0} -> {:ok, [{93, 184, 216, 34}]}
          {:inet, _later} -> {:ok, [{169, 254, 169, 254}]}
          {:inet6, _} -> {:ok, []}
        end
      end

      assert {:ok, vetted} = Outbound.vet("https://rebind.example/", resolver: flipping)
      assert vetted.addresses == [{93, 184, 216, 34}]

      # The second lookup returns the metadata address, and a caller that
      # re-resolved instead of dialling `vetted.addresses` would reach it.
      assert {:error, {:blocked_address, _host}} =
               Outbound.vet("https://rebind.example/", resolver: flipping)
    end

    test "hostname drops IPv6 brackets, because SNI and a cert match take a bare name" do
      assert {:ok, %{hostname: "2606:4700:4700::1111"}} =
               Outbound.vet("https://[2606:4700:4700::1111]/")
    end

    test "uri is the parsed URL, path and query intact" do
      answers = %{inet: [{93, 184, 216, 34}], inet6: []}

      assert {:ok, %{uri: uri}} =
               Outbound.vet("https://host.example/a/b?q=1", resolver: resolver(answers))

      assert uri.host == "host.example"
      assert uri.path == "/a/b"
      assert uri.query == "q=1"
    end
  end

  describe "resolve/2" do
    test "judges nothing, so it is not a substitute for vet/2" do
      assert {:ok, [{127, 0, 0, 1}]} = Outbound.resolve("127.0.0.1")
    end

    test "an IP literal never reaches the resolver" do
      exploding = fn _charlist, _family -> flunk("the resolver was consulted for a literal") end

      assert {:ok, [{93, 184, 216, 34}]} = Outbound.resolve("93.184.216.34", exploding)
      assert {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]} = Outbound.resolve("[::1]", exploding)
    end
  end
end
