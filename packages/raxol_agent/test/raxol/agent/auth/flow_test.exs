defmodule Raxol.Agent.Auth.FlowTest do
  @moduledoc """
  The whole Agent Auth path, browser included -- the browser is simulated by
  fetching the callback URL the flow just handed it, so the loopback socket,
  the redirect parse, and the PKCE binding are all the real ones. Only the
  network call and the credential store are injected.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.Flow

  @key "sk-or-v1-minted"

  defp exchange_ok do
    fn _url, _body, _opts -> {:ok, %{"key" => @key}} end
  end

  # Stands in for the user approving in a browser: fetch the callback URL the
  # flow put in the authorization URL, with a code attached.
  defp browser(code \\ "the-code") do
    fn url ->
      url
      |> callback_url()
      |> Kernel.<>("?code=#{code}")
      |> fetch()

      :ok
    end
  end

  defp callback_url(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("callback_url")
  end

  defp fetch(url) do
    uri = URI.parse(url)

    spawn_link(fn ->
      {:ok, socket} =
        :gen_tcp.connect(
          ~c"127.0.0.1",
          uri.port,
          [:binary, active: false, packet: :raw],
          2_000
        )

      path = uri.path <> "?" <> uri.query
      :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
      :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end)

    :ok
  end

  defp store_to(pid) do
    fn provider, key ->
      send(pid, {:stored, provider, key})
      {:ok, provider, "op://Private/OpenRouter/api_key", :valid}
    end
  end

  defp refute_stored do
    refute_receive {:stored, _provider, _key}, 100
  end

  describe "providers without a flow" do
    # Claiming a method we cannot run would hang the client at sign-in, which
    # is strictly worse than never offering it.
    test "are refused immediately rather than waiting on a browser" do
      assert {:error, {:no_oauth_flow, :anthropic}} = Flow.run(:anthropic)
      assert {:error, {:no_oauth_flow, :ollama}} = Flow.run(:ollama)
    end

    test "are pointed at the method that does work for them" do
      assert Flow.describe({:no_oauth_flow, :anthropic}) =~
               "raxol login anthropic"
    end

    test "are absent from the advertised list" do
      assert Flow.providers() == [:openrouter]
      assert Flow.supported?(:openrouter)
      refute Flow.supported?(:anthropic)
    end
  end

  describe "a completed sign-in" do
    test "stores the minted key against the provider" do
      assert {:ok, %{provider: :openrouter, validation: :valid}} =
               Flow.run(:openrouter,
                 browser_fn: browser(),
                 http_fn: exchange_ok(),
                 store_fn: store_to(self()),
                 timeout: 2_000
               )

      assert_receive {:stored, :openrouter, @key}
    end

    test "releases its port, so a second sign-in can bind one" do
      opts = [
        browser_fn: browser(),
        http_fn: exchange_ok(),
        store_fn: store_to(self()),
        timeout: 2_000
      ]

      assert {:ok, _first} = Flow.run(:openrouter, opts)
      assert {:ok, _second} = Flow.run(:openrouter, opts)
    end

    # PKCE only binds if the verifier that redeems the code is the one whose
    # challenge went to the provider.
    test "redeems the code with the verifier behind the challenge it advertised" do
      caller = self()

      capture = fn url ->
        send(
          caller,
          {:challenge,
           url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()}
        )

        browser().(url)
      end

      http_fn = fn _url, body, _opts ->
        send(caller, {:verifier, body["code_verifier"]})
        {:ok, %{"key" => @key}}
      end

      assert {:ok, _result} =
               Flow.run(:openrouter,
                 browser_fn: capture,
                 http_fn: http_fn,
                 store_fn: store_to(self()),
                 timeout: 2_000
               )

      assert_receive {:challenge, query}
      assert_receive {:verifier, verifier}

      assert query["code_challenge"] ==
               Raxol.Agent.Auth.Pkce.challenge(verifier)
    end
  end

  describe "a sign-in that does not complete" do
    test "reports a browser it could not open, with the URL to finish by hand" do
      assert {:error, {:no_browser_opener, "xdg-open", url}} =
               Flow.run(:openrouter,
                 browser_fn: fn _url ->
                   {:error, {:no_browser_opener, "xdg-open"}}
                 end,
                 store_fn: store_to(self()),
                 timeout: 2_000
               )

      assert url =~ "https://openrouter.ai/auth"
      assert Flow.describe({:no_browser_opener, "xdg-open", url}) =~ url
      refute_stored()
    end

    test "times out when nobody approves, and stores nothing" do
      assert {:error, :timeout} =
               Flow.run(:openrouter,
                 browser_fn: fn _url -> :ok end,
                 http_fn: exchange_ok(),
                 store_fn: store_to(self()),
                 timeout: 50
               )

      refute_stored()
    end

    test "stores nothing when the code will not exchange" do
      assert {:error, {:exchange_rejected, 403}} =
               Flow.run(:openrouter,
                 browser_fn: browser(),
                 http_fn: fn _url, _body, _opts ->
                   {:error, {:exchange_rejected, 403}}
                 end,
                 store_fn: store_to(self()),
                 timeout: 2_000
               )

      refute_stored()
    end

    # The reference is written before validation runs, but a key the provider
    # will not authorize is not a sign-in the client should be told succeeded.
    test "fails when the provider will not authorize the key it just minted" do
      store_fn = fn provider, _key ->
        {:ok, provider, "op://ref", {:rejected, 401}}
      end

      assert {:error, {:key_rejected, 401}} =
               Flow.run(:openrouter,
                 browser_fn: browser(),
                 http_fn: exchange_ok(),
                 store_fn: store_fn,
                 timeout: 2_000
               )
    end

    # No `op` means nowhere to put a key, and raxol does not fall back to
    # writing one to disk.
    test "fails rather than write a key to disk when 1Password is absent" do
      store_fn = fn _provider, _key -> {:error, :op_unavailable} end

      assert {:error, {:store_failed, :op_unavailable}} =
               Flow.run(:openrouter,
                 browser_fn: browser(),
                 http_fn: exchange_ok(),
                 store_fn: store_fn,
                 timeout: 2_000
               )

      message = Flow.describe({:store_failed, :op_unavailable})

      assert message =~ "op"
      assert message =~ "never writes a key to disk"
    end
  end

  describe "describe/1" do
    test "renders each failure as a sentence a user can act on" do
      assert Flow.describe(:timeout) =~ "timed out"

      assert Flow.describe({:oauth_error, "access_denied", nil}) =~
               "access_denied"

      assert Flow.describe({:oauth_error, "access_denied", "User said no"}) =~
               "User said no"

      assert Flow.describe({:exchange_rejected, 400}) =~ "400"
      assert Flow.describe(:no_http_client) =~ "HTTP client"
      assert Flow.describe({:key_rejected, 401}) =~ "401"
      assert Flow.describe({:listen_failed, :eaddrinuse}) =~ "local port"
    end
  end
end
