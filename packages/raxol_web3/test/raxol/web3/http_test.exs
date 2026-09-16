defmodule Raxol.Web3.HTTPTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Tables

  # Every test uses its own hostname, so its bucket and its breaker are its
  # own: both are keyed per origin in one shared table, and sharing a host
  # between async tests would make one test's refusal another's failure.
  #
  # Two injections, both of them the house pattern rather than a mock. The
  # resolver is `Raxol.Core.Outbound`'s documented seam, and it is what lets a
  # made-up host be vetted without a DNS lookup. The `:exchange` stage is the
  # same injection `Raxol.Agent.Actions.Fetch` uses for its transport, and it is
  # what lets the stages BEFORE the socket be tested at all: a local endpoint
  # listens on loopback, which the vet refuses, so there is no arrangement in
  # which a real socket exercises this pipeline locally.

  defp resolver(addresses \\ [{93, 184, 216, 34}]) do
    fn _charlist, family ->
      case family do
        :inet -> {:ok, addresses}
        :inet6 -> {:ok, []}
      end
    end
  end

  defp failing_resolver do
    fn _charlist, _family -> {:error, :nxdomain} end
  end

  # Reports every call to the test process, so "the exchange was not reached"
  # is an assertion rather than an absence.
  defp seam(result) do
    fn _vetted, request, _opts ->
      send(self(), {:exchange, request})
      result
    end
  end

  defp refusing_seam do
    fn _vetted, request, _opts ->
      flunk("the pipeline reached the exchange with #{inspect(request)}")
    end
  end

  defp ok(status \\ 200, body \\ "{}") do
    seam({:ok, %{status: status, headers: [{"content-type", "application/json"}], body: body}})
  end

  defp opts(extra) do
    [resolver: resolver()] ++ extra
  end

  defp origin_id(host) do
    Origin.id(URI.new!("https://#{host}/"))
  end

  defp failures(host) do
    CircuitBreaker.status(Tables.breakers(), {:origin, origin_id(host)}).failures
  end

  defp breaker_state(host) do
    CircuitBreaker.status(Tables.breakers(), {:origin, origin_id(host)}).state
  end

  describe "the vet runs first" do
    test "http is refused, and nothing downstream runs" do
      assert {:error, {:blocked, :invalid_url}} =
               HTTP.get("http://scheme.example/x", opts(exchange: refusing_seam()))
    end

    test "a target resolving into the reject set is refused without naming the host" do
      assert {:error, {:blocked, :address}} =
               HTTP.get("https://private.example/x",
                 resolver: resolver([{169, 254, 169, 254}]),
                 exchange: refusing_seam()
               )
    end

    test "a host that does not resolve is an unhealthy origin, named by id" do
      host = "nxdomain.example"

      assert {:error, {:dns_failed, id}} =
               HTTP.get("https://#{host}/x",
                 resolver: failing_resolver(),
                 exchange: refusing_seam()
               )

      assert id == origin_id(host)
      assert {:ok, "https://#{host}:443"} == Origin.resolve(id)

      # A dead name trips the breaker, so the router fails over instead of every
      # call paying for the same failed lookup.
      assert failures(host) == 1
    end
  end

  describe "the token bucket runs before the socket" do
    test "a refusal costs no request and reports how long to wait" do
      host = "bucket.example"
      limit = [rate_limit: [capacity: 1, refill_per_second: 2.0]]

      assert {:ok, _response} =
               HTTP.get("https://#{host}/a", opts([exchange: ok()] ++ limit))

      assert_receive {:exchange, _request}

      assert {:error, {:rate_limited, retry_after}} =
               HTTP.get("https://#{host}/b", opts([exchange: refusing_seam()] ++ limit))

      assert retry_after > 0
      refute_receive {:exchange, _request}
    end

    test "a bucket refusal is not a health signal" do
      # Our budget, not the upstream's behaviour. Counting it as a failure would
      # quarantine a perfectly healthy origin for being popular.
      host = "bucket-health.example"
      limit = [rate_limit: [capacity: 1, refill_per_second: 2.0]]

      assert {:ok, _} = HTTP.get("https://#{host}/a", opts([exchange: ok()] ++ limit))

      assert {:error, {:rate_limited, _}} =
               HTTP.get("https://#{host}/b", opts([exchange: refusing_seam()] ++ limit))

      assert failures(host) == 0
      assert breaker_state(host) == :closed
    end

    test "the bucket is keyed per origin, not per URL" do
      # Two paths on one host share a budget, because the limit belongs to the
      # upstream. Keying by URL would mint a bucket per endpoint and spend the
      # upstream's allowance N times over.
      host = "shared-bucket.example"
      limit = [rate_limit: [capacity: 1, refill_per_second: 2.0]]

      assert {:ok, _} =
               HTTP.get("https://#{host}/api/v2/stats", opts([exchange: ok()] ++ limit))

      assert {:error, {:rate_limited, _}} =
               HTTP.get(
                 "https://#{host}/api/v2/blocks",
                 opts([exchange: refusing_seam()] ++ limit)
               )
    end
  end

  describe "the circuit breaker short-circuits" do
    test "an open breaker refuses before the socket, naming the origin by id" do
      host = "breaker.example"
      trip = [breaker: [failure_threshold: 1, recovery_ms: 60_000]]

      # A 503 is the upstream broken, so one is enough at this threshold.
      assert {:ok, %{status: 503}} =
               HTTP.get("https://#{host}/a", opts([exchange: ok(503)] ++ trip))

      # Drained, so the refute below is about the SECOND call. Without this the
      # first call's own message satisfies it and the test passes whatever the
      # breaker does.
      assert_receive {:exchange, %{path: "/a"}}
      assert breaker_state(host) == :open

      assert {:error, {:breaker_open, id}} =
               HTTP.get("https://#{host}/b", opts([exchange: refusing_seam()] ++ trip))

      assert id == origin_id(host)
      refute_receive {:exchange, _request}
    end
  end

  describe "health is decided by status, success is not" do
    test "a challenge, a back-off and a server error are failures" do
      # 403 is the challenge page decision 9 describes, 429 is the upstream
      # telling us to slow down, 500 is it broken. All three arrive as
      # responses, because classifying the body is the backend's job, and all
      # three count against health.
      for {status, host} <- [{403, "s403.example"}, {429, "s429.example"}, {500, "s500.example"}] do
        assert {:ok, %{status: ^status}} =
                 HTTP.get("https://#{host}/x", opts(exchange: ok(status)))

        assert failures(host) == 1, "#{status} was not recorded as a failure"
      end
    end

    test "a 404 is a healthy answer about a missing thing" do
      host = "s404.example"

      assert {:ok, %{status: 404}} = HTTP.get("https://#{host}/x", opts(exchange: ok(404)))
      assert failures(host) == 0
    end

    test "a success closes a breaker that had started to count" do
      host = "recover.example"
      trip = [breaker: [failure_threshold: 3]]

      assert {:ok, _} = HTTP.get("https://#{host}/x", opts([exchange: ok(500)] ++ trip))
      assert failures(host) == 1

      assert {:ok, _} = HTTP.get("https://#{host}/x", opts([exchange: ok(200)] ++ trip))
      assert failures(host) == 0
    end

    test "a transport failure is a health signal and its reason is an atom" do
      host = "transport.example"

      assert {:error, {:transport, :econnrefused}} =
               HTTP.get(
                 "https://#{host}/x",
                 opts(exchange: seam({:error, {:transport, :econnrefused}}))
               )

      assert failures(host) == 1
    end

    test "a size refusal is neither a success nor a failure" do
      # Our refusal of a well-formed response. Treating it as unhealth would
      # quarantine an origin for answering a question we should not have asked.
      host = "too-large.example"

      assert {:error, {:too_large, 2048}} =
               HTTP.get("https://#{host}/x", opts(exchange: seam({:error, {:too_large, 2048}})))

      assert failures(host) == 0
      assert breaker_state(host) == :closed
    end
  end

  describe "the request it builds" do
    test "identifies as raxol_web3 and refuses to be told otherwise" do
      assert {:ok, _} =
               HTTP.get(
                 "https://ua.example/x",
                 opts(
                   exchange: ok(),
                   headers: [{"User-Agent", "Mozilla/5.0"}, {"x-api-key", "secret"}]
                 )
               )

      assert_receive {:exchange, request}

      assert {"user-agent", user_agent} =
               Enum.find(request.headers, fn {name, _} -> name == "user-agent" end)

      assert user_agent =~ "raxol_web3/"
      assert user_agent =~ "+https://raxol.io"
      refute Enum.any?(request.headers, fn {_n, v} -> v == "Mozilla/5.0" end)

      # A supplied header that is not the user-agent survives: the enforcement
      # is one header, not a whitelist.
      assert {"x-api-key", "secret"} in request.headers
    end

    test "asks for an identity encoding, because the reader does not decompress" do
      assert {:ok, _} = HTTP.get("https://encoding.example/x", opts(exchange: ok()))
      assert_receive {:exchange, request}
      assert {"accept-encoding", "identity"} in request.headers
    end

    test "lets a caller override the encoding, unlike the user-agent" do
      assert {:ok, _} =
               HTTP.get(
                 "https://encoding2.example/x",
                 opts(exchange: ok(), headers: [{"accept-encoding", "gzip"}])
               )

      assert_receive {:exchange, request}
      assert {"accept-encoding", "gzip"} in request.headers
      refute {"accept-encoding", "identity"} in request.headers
    end

    test "carries the path and the query string" do
      assert {:ok, _} =
               HTTP.get(
                 "https://query.example/api/v2/search?q=vitalik&type=address",
                 opts(exchange: ok())
               )

      assert_receive {:exchange, request}
      assert request.path == "/api/v2/search?q=vitalik&type=address"
    end

    test "a bare origin becomes a root path" do
      assert {:ok, _} = HTTP.get("https://root.example", opts(exchange: ok()))
      assert_receive {:exchange, request}
      assert request.path == "/"
    end

    test "post carries its body and method" do
      body = ~s({"method":"eth_blockNumber","params":[]})

      assert {:ok, _} =
               HTTP.post(
                 "https://rpc.example/",
                 body,
                 opts(exchange: ok(), headers: [{"content-type", "application/json"}])
               )

      assert_receive {:exchange, request}
      assert request.method == "POST"
      assert request.body == body
    end
  end

  describe "the origin id" do
    test "is on every response and resolves on this node" do
      host = "resolve.example"

      assert {:ok, %{origin_id: id}} = HTTP.get("https://#{host}/x", opts(exchange: ok()))
      assert {:ok, "https://#{host}:443"} == Origin.resolve(id)
    end

    test "is the same for two paths on one host and different across hosts" do
      assert origin_id("a.example") == Origin.id(URI.new!("https://a.example/some/path"))
      assert origin_id("a.example") != origin_id("b.example")
    end

    test "carries no host, which is the point" do
      # A per-account URL names the account in its hostname, and an error term
      # travels into logs, telemetry and model-visible text.
      host = "secret-account.example"

      assert {:error, {:dns_failed, id}} =
               HTTP.get("https://#{host}/x", resolver: failing_resolver())

      refute id =~ "secret"
      refute id =~ host
    end
  end

  describe "against a real upstream" do
    # Excluded by default (see test_helper.exs): it opens a socket to a third
    # party, so it is a gate to run deliberately, not on every save. It is the
    # only test in this package that exercises the whole pipeline, including the
    # system trust store and a real DNS answer.
    @tag :live_web3
    test "reads a public explorer endpoint end to end" do
      assert {:ok, response} =
               HTTP.get("https://eth.blockscout.com/api/v2/stats", deadline_ms: 30_000)

      assert response.status == 200
      assert response.body =~ "total_blocks"
      assert {:ok, "https://eth.blockscout.com:443"} == Origin.resolve(response.origin_id)
    end
  end
end
