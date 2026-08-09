defmodule Raxol.Agent.Auth.LoopbackTest do
  @moduledoc """
  The redirect catcher, driven with a real socket rather than a stub: the
  browser is the one participant in this flow we cannot inject, so the HTTP it
  speaks is the part worth testing for real.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.Loopback

  setup do
    {:ok, listener} = Loopback.open()
    on_exit(fn -> Loopback.close(listener) end)

    {:ok, listener: listener}
  end

  test "advertises the loopback URL a provider redirects to", %{
    listener: listener
  } do
    assert Loopback.redirect_uri(listener) ==
             "http://localhost:#{listener.port}/callback"
  end

  # Bound to 127.0.0.1, not 0.0.0.0: an OAuth code in a URL is a bearer
  # credential for the length of the flow and must not be catchable off-box.
  test "binds the loopback interface only", %{listener: listener} do
    assert {:ok, {{127, 0, 0, 1}, _port}} = :inet.sockname(listener.socket)
  end

  test "returns the code the browser arrives with", %{listener: listener} do
    fire(listener.port, "/callback?code=abc123")

    assert {:ok, "abc123"} = Loopback.await(listener, 2_000)
  end

  test "answers the browser a page rather than a dropped connection", %{
    listener: listener
  } do
    caller = self()

    spawn_link(fn ->
      send(caller, {:response, request(listener.port, "/callback?code=abc123")})
    end)

    assert {:ok, "abc123"} = Loopback.await(listener, 2_000)
    assert_receive {:response, response}, 2_000

    assert response =~ "200 OK"
    assert response =~ "close this tab"
  end

  test "reports a denial at the provider instead of waiting out the clock", %{
    listener: listener
  } do
    fire(
      listener.port,
      "/callback?error=access_denied&error_description=User+said+no"
    )

    assert {:error, {:oauth_error, "access_denied", "User said no"}} =
             Loopback.await(listener, 2_000)
  end

  # A browser fetches /favicon.ico unprompted. Treating any request as the
  # redirect would end the wait before the user ever approved.
  test "a request without a code does not end the wait", %{listener: listener} do
    caller = self()

    spawn_link(fn ->
      send(caller, {:favicon, request(listener.port, "/favicon.ico")})
      request(listener.port, "/callback?code=late-but-real")
    end)

    assert {:ok, "late-but-real"} = Loopback.await(listener, 3_000)
    assert_receive {:favicon, favicon_response}, 2_000
    assert favicon_response =~ "404 Not Found"
  end

  test "gives up on the deadline when the browser never arrives", %{
    listener: listener
  } do
    assert {:error, :timeout} = Loopback.await(listener, 50)
  end

  test "close releases the port", %{listener: listener} do
    :ok = Loopback.close(listener)

    assert {:error, _reason} =
             :gen_tcp.connect(
               ~c"127.0.0.1",
               listener.port,
               [:binary, active: false],
               500
             )
  end

  # Send a request without waiting on its response: reading it inline would
  # block until `await/2` accepts, which the caller has not reached yet.
  defp fire(port, path) do
    spawn_link(fn -> request(port, path) end)
    :ok
  end

  defp request(port, path) do
    {:ok, socket} =
      :gen_tcp.connect(
        ~c"127.0.0.1",
        port,
        [:binary, active: false, packet: :raw],
        2_000
      )

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\nAccept: */*\r\n\r\n"
      )

    response = read(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp read(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read(socket, acc <> data)
      {:error, _reason} -> acc
    end
  end
end
