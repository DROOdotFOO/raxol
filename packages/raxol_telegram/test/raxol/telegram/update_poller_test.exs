defmodule Raxol.Telegram.UpdatePollerTest do
  # async: false - poller processes are named-free but tests rely on ordered
  # mailbox interplay with a blocking post_fn.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Telegram.UpdatePoller

  # The post_fn runs INSIDE the poller process and blocks on a selective
  # receive until this test feeds a response with respond/2. The `after`
  # fallback keeps a wedged test from hanging supervision teardown; the
  # poller is specced :brutal_kill for the same reason. Never GenServer.call
  # into the poller while it is blocked here.
  defp start_poller!(opts \\ []) do
    test_pid = self()

    post_fn = fn url, req_opts ->
      send(test_pid, {:poll_request, url, req_opts})

      receive do
        {:respond, resp} -> resp
      after
        2_000 -> {:error, :test_timeout}
      end
    end

    defaults = [
      conn: [bot_token: "test-token", post_fn: post_fn],
      on_update: fn update -> send(test_pid, {:update, update}) end,
      poll_timeout_s: 0
    ]

    pid =
      start_supervised!(%{
        id: UpdatePoller,
        start: {UpdatePoller, :start_link, [Keyword.merge(defaults, opts)]},
        shutdown: :brutal_kill
      })

    pid
  end

  defp respond(pid, result) do
    send(pid, {:respond, {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}}})
  end

  defp update(id, text \\ "hi") do
    %{"update_id" => id, "message" => %{"text" => text, "chat" => %{"id" => 1}}}
  end

  test "delivers updates in order and advances the offset" do
    pid = start_poller!()

    assert_receive {:poll_request, url, req_opts}
    assert String.ends_with?(url, "/getUpdates")
    refute Keyword.fetch!(req_opts, :json) |> Map.has_key?(:offset)

    respond(pid, [update(10, "first"), update(11, "second")])

    assert_receive {:update, %{"update_id" => 10}}
    assert_receive {:update, %{"update_id" => 11}}

    assert_receive {:poll_request, _url, req_opts2}
    assert Keyword.fetch!(req_opts2, :json).offset == 12

    respond(pid, [])
  end

  test "the HTTP receive timeout strictly exceeds the long-poll hold" do
    pid = start_poller!(poll_timeout_s: 30)

    assert_receive {:poll_request, _url, req_opts}
    body = Keyword.fetch!(req_opts, :json)
    receive_timeout = Keyword.fetch!(req_opts, :receive_timeout)

    assert body.timeout == 30
    assert receive_timeout > 30 * 1_000

    respond(pid, [])
  end

  test "a transport error backs off instead of re-polling immediately" do
    pid = start_poller!()

    assert_receive {:poll_request, _, _}

    log =
      capture_log(fn ->
        send(pid, {:respond, {:error, :econnrefused}})
        refute_receive {:poll_request, _, _}, 100
      end)

    assert log =~ "econnrefused"

    # Fire the backoff cycle manually - no sleeping on the real timer.
    send(pid, :poll)
    assert_receive {:poll_request, _, _}
    respond(pid, [])
  end

  test "a crashing on_update is logged, skipped, and the offset advances" do
    test_pid = self()

    pid =
      start_poller!(
        on_update: fn
          %{"update_id" => 1} -> raise "bad update"
          update -> send(test_pid, {:update, update})
        end
      )

    assert_receive {:poll_request, _, _}

    log =
      capture_log(fn ->
        respond(pid, [update(1), update(2)])
        assert_receive {:update, %{"update_id" => 2}}
        assert_receive {:poll_request, _, req_opts}
        assert Keyword.fetch!(req_opts, :json).offset == 3
        respond(pid, [])
      end)

    assert log =~ "bad update"
  end
end
