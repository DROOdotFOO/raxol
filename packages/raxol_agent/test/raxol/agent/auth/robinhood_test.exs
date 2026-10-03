defmodule Raxol.Agent.Auth.RobinhoodTest do
  @moduledoc """
  Discovery, registration, code exchange and refresh against an in-process
  authorization server: the `:http_fn` seam answers with the shapes observed
  from the real endpoints (synthetic values), so every check runs on real
  parsing with no network.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Agent.Auth.Pkce
  alias Raxol.Agent.Auth.Robinhood

  @issuer "https://agent.robinhood.com/mcp/trading"
  @prm_url "https://agent.robinhood.com/.well-known/oauth-protected-resource/mcp/trading"
  @asm_url "https://agent.robinhood.com/.well-known/oauth-authorization-server"
  @register_url "https://agent.robinhood.com/oauth/trading/register"
  @token_url "https://api.robinhood.com/oauth2/token/"
  @client_id "FAKECLIENTID000000000000000000000000TEST"
  @redirect "http://127.0.0.1:4321/callback"
  @now ~U[2026-10-03 12:00:00Z]

  @access "eyJhbGciOiJub25lIn0.eyJmYWtlIjp0cnVlfQ.FAKE-ACCESS-TOKEN-UNIT"
  @refresh "fake-refresh-token-unit-000001"
  @rotated "fake-refresh-token-unit-000002"

  defp prm do
    %{
      "authorization_servers" => [@issuer],
      "bearer_methods_supported" => ["header"],
      "resource" => @issuer,
      "scopes_supported" => ["internal"]
    }
  end

  defp asm do
    %{
      "issuer" => @issuer,
      "authorization_endpoint" => "https://robinhood.com/oauth",
      "token_endpoint" => @token_url,
      "registration_endpoint" => @register_url,
      "code_challenge_methods_supported" => ["S256"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "response_types_supported" => ["code"],
      "scopes_supported" => ["internal"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "authorization_response_iss_parameter_supported" => true
    }
  end

  defp token(access, refresh, expires_in) do
    %{
      "access_token" => access,
      "expires_in" => expires_in,
      "token_type" => "Bearer",
      "scope" => "internal",
      "refresh_token" => refresh,
      "mfa_code" => nil,
      "backup_code" => nil,
      "user_uuid" => "00000000-0000-4000-8000-00000000fa4e"
    }
  end

  # An authorization server keyed by URL. Each request is reported to the
  # test process, so a test can assert what went on the wire.
  defp server(routes) do
    caller = self()

    fn url, body, _opts ->
      send(caller, {:http, url, body})

      case Map.fetch(routes, url) do
        {:ok, fun} when is_function(fun, 1) -> fun.(body)
        {:ok, response} -> response
        :error -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}

  defp discovery(overrides \\ %{}) do
    Map.merge(%{@prm_url => ok(prm()), @asm_url => ok(asm())}, overrides)
  end

  describe "discover/1" do
    test "accepts metadata that matches every pinned endpoint" do
      assert :ok = Robinhood.discover(http_fn: server(discovery()))
      assert_received {:http, @prm_url, :get}
      assert_received {:http, @asm_url, :get}
    end

    # Discovery confirms the pins; it never redirects the flow. A token
    # endpoint on another host would receive the code and the verifier.
    test "refuses a token endpoint that is not the pinned one" do
      moved = Map.put(asm(), "token_endpoint", "https://evil.example/token")
      http_fn = server(discovery(%{@asm_url => ok(moved)}))

      assert {:error, :metadata_mismatch} = Robinhood.discover(http_fn: http_fn)
    end

    test "refuses a different issuer" do
      http_fn = server(discovery(%{@asm_url => ok(Map.put(asm(), "issuer", "https://x"))}))
      assert {:error, :metadata_mismatch} = Robinhood.discover(http_fn: http_fn)
    end

    test "refuses a resource that names another authorization server" do
      other = Map.put(prm(), "authorization_servers", ["https://evil.example"])
      http_fn = server(discovery(%{@prm_url => ok(other)}))

      assert {:error, :metadata_mismatch} = Robinhood.discover(http_fn: http_fn)
    end

    test "refuses a server that does not promise the iss parameter" do
      without = Map.delete(asm(), "authorization_response_iss_parameter_supported")
      http_fn = server(discovery(%{@asm_url => ok(without)}))

      assert {:error, :metadata_mismatch} = Robinhood.discover(http_fn: http_fn)
    end

    test "reports a failed fetch by status only" do
      http_fn = server(discovery(%{@prm_url => {:ok, %{status: 503, body: "secret-ish"}}}))
      assert {:error, {:discovery_failed, 503}} = Robinhood.discover(http_fn: http_fn)
    end
  end

  describe "register/2" do
    defp registered(redirect_uris, method \\ "none") do
      ok(%{
        "client_id" => @client_id,
        "client_name" => "Raxol",
        "redirect_uris" => redirect_uris,
        "token_endpoint_auth_method" => method
      })
    end

    test "registers a public client for the exact loopback URI" do
      http_fn = server(%{@register_url => registered([@redirect])})

      assert {:ok, @client_id} = Robinhood.register(@redirect, http_fn: http_fn)

      assert_received {:http, @register_url, {:json, body}}

      assert body == %{
               "client_name" => "Raxol",
               "redirect_uris" => [@redirect],
               "grant_types" => ["authorization_code", "refresh_token"],
               "response_types" => ["code"],
               "token_endpoint_auth_method" => "none"
             }
    end

    test "refuses a registration that did not echo the redirect URI" do
      http_fn = server(%{@register_url => registered(["http://127.0.0.1:1/other"])})
      assert {:error, :registration_invalid} = Robinhood.register(@redirect, http_fn: http_fn)
    end

    test "refuses a confidential-client registration" do
      http_fn = server(%{@register_url => registered([@redirect], "client_secret_basic")})
      assert {:error, :registration_invalid} = Robinhood.register(@redirect, http_fn: http_fn)
    end

    test "refuses a client id outside the bounded charset" do
      bad =
        ok(%{
          "client_id" => "a b/c",
          "redirect_uris" => [@redirect],
          "token_endpoint_auth_method" => "none"
        })

      http_fn = server(%{@register_url => bad})

      assert {:error, :registration_invalid} = Robinhood.register(@redirect, http_fn: http_fn)
    end
  end

  describe "authorize_url/4" do
    test "carries every observed parameter, including the resource" do
      pkce = Pkce.new()
      url = Robinhood.authorize_url(@client_id, @redirect, pkce, "st4te")
      uri = URI.parse(url)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://robinhood.com/oauth"

      assert URI.decode_query(uri.query) == %{
               "response_type" => "code",
               "client_id" => @client_id,
               "redirect_uri" => @redirect,
               "code_challenge" => pkce.challenge,
               "code_challenge_method" => "S256",
               "state" => "st4te",
               "scope" => "internal",
               "resource" => @issuer
             }
    end
  end

  describe "exchange/5" do
    test "redeems the code as a form post and returns a credential" do
      pkce = Pkce.new()
      http_fn = server(%{@token_url => ok(token(@access, @refresh, 810_101))})

      assert {:ok, %Credential{} = cred} =
               Robinhood.exchange("the-code", pkce, @client_id, @redirect,
                 http_fn: http_fn,
                 now: @now
               )

      assert_received {:http, @token_url, {:form, form}}

      assert form == %{
               "grant_type" => "authorization_code",
               "code" => "the-code",
               "redirect_uri" => @redirect,
               "client_id" => @client_id,
               "code_verifier" => pkce.verifier,
               "resource" => @issuer
             }

      assert cred.provider == :robinhood
      assert cred.issuer == @issuer
      assert cred.client_id == @client_id
      assert cred.access_token == @access
      assert cred.refresh_token == @refresh
      assert cred.scope == "internal"
      assert cred.expires_at == DateTime.add(@now, 810_101, :second)
    end

    test "an absent expires_in is represented as nil, not defaulted" do
      body = Map.delete(token(@access, @refresh, 1), "expires_in")
      http_fn = server(%{@token_url => ok(body)})

      assert {:ok, %Credential{expires_at: nil}} =
               Robinhood.exchange("c", Pkce.new(), @client_id, @redirect, http_fn: http_fn)
    end

    test "a non-bearer token type is refused" do
      body = Map.put(token(@access, @refresh, 1), "token_type", "mac")
      http_fn = server(%{@token_url => ok(body)})

      assert {:error, :token_response_invalid} =
               Robinhood.exchange("c", Pkce.new(), @client_id, @redirect, http_fn: http_fn)
    end

    # The error carries the status and a CLOSED code atom, never the body.
    test "a rejection is the status plus the OAuth error code" do
      rejected =
        {:ok, %{status: 400, body: %{"error" => "invalid_grant", "error_description" => "leaky"}}}

      http_fn = server(%{@token_url => rejected})

      assert {:error, {:token_rejected, 400, :invalid_grant}} =
               Robinhood.exchange("c", Pkce.new(), @client_id, @redirect, http_fn: http_fn)
    end

    test "an unknown OAuth error code collapses to :other" do
      rejected = {:ok, %{status: 400, body: %{"error" => "made_up_code"}}}
      http_fn = server(%{@token_url => rejected})

      assert {:error, {:token_rejected, 400, :other}} =
               Robinhood.exchange("c", Pkce.new(), @client_id, @redirect, http_fn: http_fn)
    end
  end

  describe "refresh/2" do
    defp credential do
      %Credential{
        provider: :robinhood,
        issuer: @issuer,
        client_id: @client_id,
        access_token: @access,
        refresh_token: @refresh,
        expires_at: @now,
        scope: "internal"
      }
    end

    test "posts the refresh grant and adopts the rotated refresh token" do
      http_fn = server(%{@token_url => ok(token("new-access", @rotated, 371_497))})

      assert {:ok, %Credential{} = cred} =
               Robinhood.refresh(credential(), http_fn: http_fn, now: @now)

      assert_received {:http, @token_url, {:form, form}}

      assert form == %{
               "grant_type" => "refresh_token",
               "refresh_token" => @refresh,
               "client_id" => @client_id
             }

      assert cred.access_token == "new-access"
      assert cred.refresh_token == @rotated
      assert cred.client_id == @client_id
      assert cred.expires_at == DateTime.add(@now, 371_497, :second)
    end

    test "keeps the refresh token when the server does not rotate it" do
      body = Map.delete(token("new-access", nil, 60), "refresh_token")
      http_fn = server(%{@token_url => ok(body)})

      assert {:ok, %Credential{refresh_token: @refresh}} =
               Robinhood.refresh(credential(), http_fn: http_fn)
    end

    test "an invalid_grant is reported as such" do
      http_fn =
        server(%{@token_url => {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}}})

      assert {:error, {:token_rejected, 400, :invalid_grant}} =
               Robinhood.refresh(credential(), http_fn: http_fn)
    end

    test "a credential without a refresh token cannot refresh" do
      assert {:error, :no_refresh_token} =
               Robinhood.refresh(%{credential() | refresh_token: nil}, http_fn: server(%{}))

      refute_received {:http, _url, _body}
    end
  end

  test "Credential inspect never shows a token or the account id" do
    rendered = inspect(%{credential() | user_uuid: "00000000-0000-4000-8000-00000000fa4e"})

    refute rendered =~ @access
    refute rendered =~ @refresh
    refute rendered =~ "fa4e"
    assert rendered =~ "[REDACTED]"
  end

  test "Credential round-trips through dump/load and refuses other shapes" do
    cred = credential()
    assert {:ok, ^cred} = Credential.load(Credential.dump(cred))
    assert {:error, :malformed_credential} = Credential.load(%{"provider" => "robinhood"})
    assert {:error, :malformed_credential} = Credential.load("nope")
  end
end
