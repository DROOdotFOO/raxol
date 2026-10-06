defmodule Raxol.Broker.Test.Fixtures do
  @moduledoc """
  The sanitized Robinhood auth exchange captured on 2026-10-02/03, replayed
  from `test/fixtures/auth`. Every token, code, client id and account id in
  those files is synthetic. The real access token is a JWT of about 1250
  bytes; the fixtures use opaque `fake-access-token-*` strings instead,
  because nothing here parses the token (expiry comes from `expires_in`)
  and a JWT-shaped fake trips secret scanners.
  """

  @dir Path.expand("../fixtures/auth", __DIR__)

  @spec load(String.t()) :: term()
  def load(name), do: @dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()

  @doc "The fixture with `{port}`, `{state}`... placeholders substituted."
  @spec fill(term(), %{String.t() => String.t()}) :: term()
  def fill(value, bindings) when is_binary(value) do
    Enum.reduce(bindings, value, fn {key, sub}, acc -> String.replace(acc, "{#{key}}", sub) end)
  end

  def fill(value, bindings) when is_list(value), do: Enum.map(value, &fill(&1, bindings))

  def fill(value, bindings) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, fill(v, bindings)} end)

  def fill(value, _bindings), do: value
end

defmodule Raxol.Broker.Test.AuthServer do
  @moduledoc """
  An in-process Robinhood authorization server for the `:http_fn` seam.

  It answers discovery, registration and the token endpoint from the
  fixtures, verifies what it is sent against the recorded requests (PKCE
  included), counts refresh grants, and enforces refresh-token rotation:
  presenting a refresh token that was already used is `invalid_grant`.
  """

  alias Raxol.Broker.Test.Fixtures

  @prm "https://agent.robinhood.com/.well-known/oauth-protected-resource/mcp/trading"
  @asm "https://agent.robinhood.com/.well-known/oauth-authorization-server"
  @register "https://agent.robinhood.com/oauth/trading/register"
  @token "https://api.robinhood.com/oauth2/token/"

  @spec start(keyword()) :: pid()
  def start(opts \\ []) do
    refreshes = Keyword.get(opts, :refreshes, [Fixtures.load("refresh_response")])

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          challenge: nil,
          redirect_uri: nil,
          valid_refresh: nil,
          refreshes: refreshes,
          refresh_count: 0,
          refresh_status: Keyword.get(opts, :refresh_status)
        }
      end)

    pid
  end

  @doc "How many refresh grants reached the token endpoint."
  @spec refresh_count(pid()) :: non_neg_integer()
  def refresh_count(server), do: Agent.get(server, & &1.refresh_count)

  @doc "Called by the fake browser: the challenge the authorize request carried."
  @spec authorized(pid(), String.t()) :: :ok
  def authorized(server, challenge), do: Agent.update(server, &%{&1 | challenge: challenge})

  @doc "Accept `refresh_token` as current (a credential the test stored directly)."
  @spec issue_refresh(pid(), String.t()) :: :ok
  def issue_refresh(server, token), do: Agent.update(server, &%{&1 | valid_refresh: token})

  @spec http_fn(pid()) :: (String.t(), term(), keyword() -> {:ok, map()})
  def http_fn(server), do: fn url, body, _opts -> answer(server, url, body) end

  defp answer(_server, @prm, :get), do: ok(Fixtures.load("protected_resource"))
  defp answer(_server, @asm, :get), do: ok(Fixtures.load("authorization_server"))

  defp answer(server, @register, {:json, %{"redirect_uris" => [uri]} = body}) do
    port = uri |> URI.parse() |> Map.fetch!(:port) |> Integer.to_string()

    if body == Fixtures.fill(Fixtures.load("registration_request"), %{"port" => port}) do
      Agent.update(server, &%{&1 | redirect_uri: uri})
      ok(Fixtures.fill(Fixtures.load("registration_response"), %{"port" => port}))
    else
      error(400, "invalid_client_metadata")
    end
  end

  defp answer(server, @token, {:form, %{"grant_type" => "authorization_code"} = form}) do
    if code_grant_valid?(Agent.get(server, & &1), form) do
      response = Fixtures.load("token_response")
      Agent.update(server, &%{&1 | valid_refresh: response["refresh_token"]})
      ok(response)
    else
      error(400, "invalid_grant")
    end
  end

  defp answer(server, @token, {:form, %{"grant_type" => "refresh_token"} = form}) do
    Agent.get_and_update(server, fn state ->
      state = %{state | refresh_count: state.refresh_count + 1}

      cond do
        state.refresh_status ->
          {error(state.refresh_status, "invalid_grant"), state}

        form["refresh_token"] != state.valid_refresh or form["client_id"] != client_id() ->
          {error(400, "invalid_grant"), state}

        state.refreshes == [] ->
          {error(400, "invalid_grant"), state}

        true ->
          [response | rest] = state.refreshes
          {ok(response), %{state | refreshes: rest, valid_refresh: response["refresh_token"]}}
      end
    end)
  end

  defp answer(_server, _url, _body), do: {:ok, %{status: 404, body: ""}}

  # The recorded token request, with this run's redirect URI and verifier,
  # and a verifier whose S256 is the challenge the browser carried.
  defp code_grant_valid?(%{redirect_uri: uri, challenge: challenge}, form) when is_binary(uri) do
    port = uri |> URI.parse() |> Map.fetch!(:port) |> Integer.to_string()
    verifier = form["code_verifier"] || ""

    expected =
      Fixtures.fill(Fixtures.load("token_request"), %{"port" => port, "code_verifier" => verifier})

    form == expected and
      Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge
  end

  defp code_grant_valid?(_state, _form), do: false

  defp client_id, do: Fixtures.load("registration_response")["client_id"]

  defp ok(body), do: {:ok, %{status: 200, body: body}}
  defp error(status, code), do: {:ok, %{status: status, body: %{"error" => code}}}
end

defmodule Raxol.Broker.Test.Browser do
  @moduledoc """
  The approving user: checks the authorization URL against the recorded
  authorize request, tells the auth server the challenge, then makes a real
  GET to the loopback callback with the recorded callback parameters.
  """

  alias Raxol.Broker.Test.AuthServer
  alias Raxol.Broker.Test.Fixtures

  @spec approve(pid()) :: (String.t() -> :ok | {:error, term()})
  def approve(server) do
    fn url ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      port = query["redirect_uri"] |> URI.parse() |> Map.fetch!(:port) |> Integer.to_string()

      expected =
        Fixtures.fill(Fixtures.load("authorize_params"), %{
          "port" => port,
          "state" => query["state"],
          "code_challenge" => query["code_challenge"]
        })

      if "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://robinhood.com/oauth" and
           query == expected do
        AuthServer.authorized(server, query["code_challenge"])
        params = Fixtures.fill(Fixtures.load("callback_params"), %{"state" => query["state"]})
        get(query["redirect_uri"] <> "?" <> URI.encode_query(params))
      else
        {:error, :unexpected_authorize_request}
      end
    end
  end

  defp get(url) do
    uri = URI.parse(url)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false], 2_000)

      :ok =
        :gen_tcp.send(socket, "GET #{uri.path}?#{uri.query} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      _ = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end)

    :ok
  end
end
