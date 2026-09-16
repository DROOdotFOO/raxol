defmodule Raxol.Web3.RedactTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Redact

  describe "reason/1" do
    test "keeps a nested atom reason, which is the operationally useful part" do
      assert Redact.reason(%Mint.TransportError{reason: :econnrefused}) == :econnrefused
      assert Redact.reason(%Mint.TransportError{reason: :timeout}) == :timeout
      assert Redact.reason(%Mint.TransportError{reason: :closed}) == :closed
    end

    test "collapses a struct whose reason is not an atom to its module" do
      # This is the shape that leaks. Mint reports a bad request target as
      # `{:invalid_request_target, target}`, and the Telegram adapter exists
      # because that target carried a bot token. A URL with an API key in its
      # query string is the same defect wearing different clothes.
      leaky = %Mint.HTTPError{
        module: Mint.HTTP1,
        reason: {:invalid_request_target, "/x?key=s3cret"}
      }

      assert Redact.reason(leaky) == Mint.HTTPError
    end

    test "collapses a bare tuple rather than inspecting it" do
      assert Redact.reason({:tls_alert, {:handshake_failure, ~c"long text"}}) == :transport_error
      assert Redact.reason({:invalid_request_target, "/x?key=s3cret"}) == :transport_error
    end

    test "passes an atom through and refuses anything else" do
      assert Redact.reason(:nxdomain) == :nxdomain
      assert Redact.reason("a string body") == :transport_error
      assert Redact.reason(%{"error" => "Missing/Invalid API Key"}) == :transport_error
    end
  end

  describe "uri/1" do
    test "drops the query string, where an API key travels" do
      uri = URI.new!("https://api.etherscan.io/v2/api?chainid=1&apikey=s3cret")

      assert Redact.uri(uri) == "https://api.etherscan.io/v2/api"
    end

    test "drops userinfo, which URI.to_string would render verbatim" do
      uri = URI.new!("https://user:p4ss@host.example/path")

      rendered = Redact.uri(uri)

      assert rendered == "https://host.example/path"
      refute rendered =~ "p4ss"
    end

    test "keeps the path, which is what makes the line worth logging" do
      assert Redact.uri(URI.new!("https://eth.blockscout.com/api/v2/stats")) ==
               "https://eth.blockscout.com/api/v2/stats"
    end
  end
end
