defmodule Raxol.Agent.Auth.OpenRouterTest do
  @moduledoc """
  The provider half of Agent Auth: what we put in the browser URL, and what we
  will accept back as a credential. The transport is injected, so nothing here
  reaches the network.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.OpenRouter
  alias Raxol.Agent.Auth.Pkce

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  defp pkce, do: Pkce.new(@verifier)

  describe "the authorization URL" do
    test "carries the callback and the S256 challenge OpenRouter expects" do
      url = OpenRouter.authorize_url(pkce(), "http://localhost:4567/callback")

      assert %URI{host: "openrouter.ai", path: "/auth", scheme: "https"} =
               URI.parse(url)

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["callback_url"] == "http://localhost:4567/callback"
      assert query["code_challenge"] == Pkce.challenge(@verifier)
      assert query["code_challenge_method"] == "S256"
    end

    # The whole point of PKCE: the browser (and anything watching it) sees the
    # challenge, never the verifier that redeems the code.
    test "never carries the verifier" do
      url = OpenRouter.authorize_url(pkce(), "http://localhost:4567/callback")

      refute url =~ @verifier
    end
  end

  describe "the code exchange" do
    test "sends the code with its verifier and returns the minted key" do
      caller = self()

      http_fn = fn url, body, _opts ->
        send(caller, {:posted, url, body})
        {:ok, %{"key" => "sk-or-v1-minted"}}
      end

      assert {:ok, "sk-or-v1-minted"} =
               OpenRouter.exchange("the-code", pkce(), http_fn: http_fn)

      assert_receive {:posted, url, body}

      assert url == OpenRouter.keys_url()
      assert body["code"] == "the-code"
      assert body["code_verifier"] == @verifier
      assert body["code_challenge_method"] == "S256"
    end

    test "a rejected exchange is an error, not an empty key" do
      http_fn = fn _url, _body, _opts -> {:error, {:exchange_rejected, 400}} end

      assert {:error, {:exchange_rejected, 400}} =
               OpenRouter.exchange("stale-code", pkce(), http_fn: http_fn)
    end

    test "a 200 with no key is refused rather than stored" do
      http_fn = fn _url, _body, _opts -> {:ok, %{"error" => "nope"}} end

      assert {:error, {:no_key_in_response, ["error"]}} =
               OpenRouter.exchange("the-code", pkce(), http_fn: http_fn)
    end

    test "an empty key is refused" do
      http_fn = fn _url, _body, _opts -> {:ok, %{"key" => ""}} end

      assert {:error, {:no_key_in_response, ["key"]}} =
               OpenRouter.exchange("the-code", pkce(), http_fn: http_fn)
    end

    # The reason reaches an ACP error message, so it must name the failure
    # without echoing a provider-controlled body back at the client.
    test "a failure reason carries neither the key nor the verifier" do
      http_fn = fn _url, _body, _opts ->
        {:ok, %{"key" => "", "debug" => "sk-or-v1-leaked"}}
      end

      assert {:error, reason} =
               OpenRouter.exchange("the-code", pkce(), http_fn: http_fn)

      refute inspect(reason) =~ "sk-or-v1-leaked"
      refute inspect(reason) =~ @verifier
    end
  end
end
