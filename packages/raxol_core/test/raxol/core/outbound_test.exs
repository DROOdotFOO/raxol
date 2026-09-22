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
            "https://[fe80::1]/",
            # Deprecated by RFC 3879, so nothing is expected to answer with
            # one. Refused anyway: a range that is not in the table is a range
            # a resolver can hand back.
            "https://[fec0::1]/",
            "https://[feff:ffff::1]/"
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

    test "refuses the ranges that exist only on paper" do
      for {label, url} <- [
            {"IETF protocol assignments", "https://192.0.0.1/"},
            {"TEST-NET-1", "https://192.0.2.5/"},
            {"TEST-NET-2", "https://198.51.100.5/"},
            {"TEST-NET-3", "https://203.0.113.5/"},
            {"benchmarking", "https://198.18.0.1/"},
            {"benchmarking, upper half", "https://198.19.255.254/"},
            {"6to4 relay anycast", "https://192.88.99.1/"},
            {"v6 discard-only", "https://[100::1]/"},
            {"v6 benchmarking", "https://[2001:2::1]/"},
            {"v6 documentation", "https://[2001:db8::1]/"}
          ] do
        assert {:error, {:blocked_address, _host}} = Outbound.vet(url),
               "#{label} was not refused"
      end
    end

    test "the neighbours of those ranges are still reachable" do
      # Each range above sits inside a larger public block, so a clause written
      # one octet or one group too wide would be invisible against the
      # refusals and would quietly blacklist real hosts.
      for address <- [
            {192, 0, 1, 1},
            {192, 0, 3, 1},
            {198, 51, 99, 1},
            {203, 0, 114, 1},
            {198, 17, 0, 1},
            {198, 20, 0, 1},
            {192, 88, 98, 1},
            {0x100, 0, 0, 1, 0, 0, 0, 1},
            {0x2001, 3, 0, 0, 0, 0, 0, 1},
            {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1}
          ] do
        refute Outbound.blocked?(address), "#{inspect(address)} was refused"
      end
    end

    test "the generic IPv6 clause stays LAST, or the specific ones stop being reached" do
      # Every address here is answered `false` by the generic bitmask rule, so
      # each is refused ONLY because its own clause is matched first. Moving
      # the generic clause above them makes `2002:a9fe:a9fe::` — a working
      # route to the cloud metadata address — reachable, and nothing about the
      # table's shape would look wrong afterwards.
      generic? = fn {a, b, _c, _d, _e, _f, _g, _h} ->
        Bitwise.band(a, 0xFE00) == 0xFC00 or
          Bitwise.band(a, 0xFFC0) == 0xFE80 or
          Bitwise.band(a, 0xFFC0) == 0xFEC0 or
          Bitwise.band(a, 0xFF00) == 0xFF00 or
          (a == 0x2001 and b == 0)
      end

      for address <- [
            {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0},
            {0x2002, 0x7F00, 1, 0, 0, 0, 0, 0},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
            {0x64, 0xFF9B, 1, 0, 0, 0, 0x7F00, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
            {0, 0, 0, 0, 0xFFFF, 0, 0xA9FE, 0xA9FE},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0x100, 0, 0, 0, 0, 0, 0, 0},
            {0x2001, 0x2, 0, 0, 0, 0, 0, 1},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
          ] do
        refute generic?.(address),
               "#{inspect(address)} no longer needs a clause ahead of the generic one"

        assert Outbound.blocked?(address),
               "#{inspect(address)} reached the generic clause first"
      end
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
      assert {:error, {:dns_failed, {"nowhere.example", :nxdomain}}} =
               Outbound.vet("https://nowhere.example/", resolver: failing_resolver())
    end

    test "a family whose lookup FAILED refuses the host, even when the other answered" do
      # The attack: a nameserver that SERVFAILs the A query and answers AAAA
      # chose which half of its own records the policy got to judge. Mapping
      # the error to an empty list made that byte-identical to a host with no
      # A record, so the vet passed on the AAAA alone.
      split = fn
        _charlist, :inet -> {:error, :servfail}
        _charlist, :inet6 -> {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]}
      end

      assert {:error, {:dns_failed, {"half.example", {:lookup_failed, :servfail}}}} =
               Outbound.vet("https://half.example/", resolver: split)
    end

    test "a family with NO record is not a failed lookup, so a v4-only host still resolves" do
      # `:inet.getaddrs/3` answers `{:error, :nxdomain}` for a family a host
      # has no record in, which is every v4-only host's AAAA lookup. Failing
      # closed on that reason would refuse most of the internet.
      v4_only = fn
        _charlist, :inet -> {:ok, [{93, 184, 216, 34}]}
        _charlist, :inet6 -> {:error, :nxdomain}
      end

      assert {:ok, %{addresses: [{93, 184, 216, 34}]}} =
               Outbound.vet("https://v4only.example/", resolver: v4_only)
    end

    test "the reason survives, so a resolver hiccup is not a host that does not exist" do
      # `Raxol.Web3.HTTP` trips an origin's breaker on `{:dns_failed, _}`. A
      # transient timeout and a nonexistent host arriving as the same term is
      # what makes that decision unmakeable.
      timing_out = fn _charlist, _family -> {:error, :timeout} end

      assert {:error, {:dns_failed, {_host, {:lookup_failed, :timeout}}}} =
               Outbound.vet("https://flaky.example/", resolver: timing_out)
    end
  end

  describe "the port policy" do
    test "refuses a port nothing serves HTTP on, so a vetted fetch is not a port prober" do
      # Every other rule here judges the ADDRESS, so `https://<public
      # host>:22/` passes all of them and the connect result then reports
      # whether 22 is open. The port is model-chosen in
      # `Raxol.Agent.Actions.Fetch`.
      for port <- [22, 25, 3306, 6379, 9200, 11_211] do
        assert {:error, :invalid_url} = Outbound.vet("https://93.184.216.34:#{port}/"),
               "port #{port} was not refused"
      end
    end

    test "allows the ports HTTP is served on, and an explicit list overrides them" do
      for port <- [80, 443, 8080, 8443] do
        assert {:ok, _vetted} = Outbound.vet("https://93.184.216.34:#{port}/"),
               "port #{port} was refused"
      end

      assert {:ok, %{uri: %URI{port: 9443}}} =
               Outbound.vet("https://93.184.216.34:9443/", ports: [9443])
    end
  end

  describe "the returned addresses" do
    test "duplicates are dropped and the families interleave, so a cap cannot starve v6" do
      answers = %{
        inet: [{93, 184, 216, 34}, {93, 184, 216, 34}, {93, 184, 216, 35}],
        inet6: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]
      }

      assert {:ok, vetted} = Outbound.vet("https://many.example/", resolver: resolver(answers))

      assert vetted.addresses == [
               {93, 184, 216, 34},
               {0x2606, 0x4700, 0, 0, 0, 0, 0, 1},
               {93, 184, 216, 35}
             ]
    end

    test "the dial list is capped, because each address costs a caller one connect timeout" do
      # `Raxol.Web3.Dial` gives EACH address the full connect timeout (5000ms),
      # so an uncapped list is a multiplier a hostile authoritative nameserver
      # sets: 64 padded answers is 64 serial connects behind one call. The v6
      # answer survives the cut because the families interleave.
      answers = %{
        inet: for(n <- 1..64, do: {93, 184, 216, n}),
        inet6: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]
      }

      assert {:ok, vetted} = Outbound.vet("https://padded.example/", resolver: resolver(answers))

      assert length(vetted.addresses) == 8
      assert {0x2606, 0x4700, 0, 0, 0, 0, 0, 1} in vetted.addresses
    end

    test "a v6-only host keeps a full dial list rather than losing to the interleave" do
      answers = %{inet: [], inet6: for(n <- 1..12, do: {0x2606, 0x4700, 0, 0, 0, 0, 0, n})}

      assert {:ok, vetted} = Outbound.vet("https://v6many.example/", resolver: resolver(answers))

      assert length(vetted.addresses) == 8
      assert Enum.all?(vetted.addresses, &(tuple_size(&1) == 8))
    end

    test "every answer is still judged, including the ones the cap drops" do
      # The cap bounds the DIAL list, not the check. Capping first would let a
      # padded RRset carry a blocked address past the policy by parking it
      # beyond the cut, which is a weaker rule than the one stated.
      answers = %{
        inet: for(n <- 1..64, do: {93, 184, 216, n}) ++ [{169, 254, 169, 254}],
        inet6: []
      }

      assert {:error, {:blocked_address, "padded.example"}} =
               Outbound.vet("https://padded.example/", resolver: resolver(answers))
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

    test "tells a name with no records apart from a lookup that did not answer" do
      assert {:error, :nxdomain} =
               Outbound.resolve("nowhere.example", fn _charlist, _family ->
                 {:error, :nxdomain}
               end)

      assert {:error, {:lookup_failed, :timeout}} =
               Outbound.resolve("slow.example", fn _charlist, _family -> {:error, :timeout} end)
    end

    test "returns what the resolver said, uncapped and undeduplicated" do
      # The cap and the dedupe belong to `vet/2`, after the reject check has
      # seen every answer. Moving them here would bound the list the policy is
      # applied to, which is the one thing the cap must not do.
      padded = for n <- 1..20, do: {93, 184, 216, n}
      answers = %{inet: padded ++ padded, inet6: []}

      assert {:ok, addresses} = Outbound.resolve("many.example", resolver(answers))
      assert length(addresses) == 40
    end
  end

  describe "the resolution budget" do
    test "a three-arity resolver is handed the budget, and the second family what is left" do
      # `:inet.getaddrs/2` is `getaddrs(Host, Family, infinity)`, so before
      # this the only bound on a lookup was the native resolver's own
      # `res_option(timeout) * 4` and a caller with an end-to-end deadline had
      # no way to state it. The budget is a deadline across BOTH families, not
      # a timeout handed to each, or a host that hangs on A and AAAA costs it
      # twice.
      test = self()

      recording = fn _charlist, family, timeout ->
        send(test, {:budget, family, timeout})
        {:ok, []}
      end

      assert {:error, {:dns_failed, {"slow.example", :nxdomain}}} =
               Outbound.vet("https://slow.example/", resolver: recording, timeout_ms: 250)

      assert_received {:budget, :inet, v4_timeout}
      assert_received {:budget, :inet6, v6_timeout}

      assert v4_timeout > 0 and v4_timeout <= 250
      assert v6_timeout <= v4_timeout
    end

    test "the two-arity seam still works, because an injected resolver answers from a literal" do
      answers = %{inet: [{93, 184, 216, 34}], inet6: []}

      assert {:ok, %{addresses: [{93, 184, 216, 34}]}} =
               Outbound.vet("https://two-arity.example/", resolver: resolver(answers))
    end
  end
end
