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
    send(
      pid,
      {:respond, {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}}}
    )
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

  # Durable-offset tests stop the poller gracefully (terminate must run so
  # the DETS file is synced and closed), so they park it in backoff first
  # and use a normal shutdown instead of the :brutal_kill helper.
  defp start_durable_poller!(id, dets_opts) do
    test_pid = self()

    post_fn = fn url, req_opts ->
      send(test_pid, {:poll_request, url, req_opts})

      receive do
        {:respond, resp} -> resp
      after
        2_000 -> {:error, :test_timeout}
      end
    end

    start_supervised!(
      %{
        id: id,
        start:
          {UpdatePoller, :start_link,
           [
             [
               conn: [bot_token: "test-token", post_fn: post_fn],
               on_update: fn update -> send(test_pid, {:update, update}) end,
               poll_timeout_s: 0
             ] ++ dets_opts
           ]},
        shutdown: 5_000
      },
      restart: :temporary
    )
  end

  defp park_in_backoff_and_stop(pid, id) do
    capture_log(fn ->
      send(pid, {:respond, {:error, :econnrefused}})
      refute_receive {:poll_request, _, _}, 100
      :ok = stop_supervised(id)
    end)
  end

  test "with :dets_path the offset survives a restart" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "poller_dets_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    dets_opts = [
      dets_path: Path.join(dir, "offset.dets"),
      dets_name: :"poller_offset_#{System.unique_integer([:positive])}"
    ]

    pid = start_durable_poller!(:durable_a, dets_opts)

    assert_receive {:poll_request, _url, req_opts}
    refute Keyword.fetch!(req_opts, :json) |> Map.has_key?(:offset)

    respond(pid, [update(10), update(11)])
    assert_receive {:update, %{"update_id" => 11}}

    assert_receive {:poll_request, _url, req_opts2}
    assert Keyword.fetch!(req_opts2, :json).offset == 12

    park_in_backoff_and_stop(pid, :durable_a)

    pid2 = start_durable_poller!(:durable_b, dets_opts)

    assert_receive {:poll_request, _url, req_opts3}
    assert Keyword.fetch!(req_opts3, :json).offset == 12

    park_in_backoff_and_stop(pid2, :durable_b)
  end

  test "a non-integer persisted offset is ignored" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "poller_dets_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "offset.dets")
    name = :"poller_offset_junk_#{System.unique_integer([:positive])}"

    handle = Raxol.Core.Stores.Dets.open!(name, path, fn _ -> :ok end)
    Raxol.Core.Stores.Dets.put(handle, :offset, "junk")
    Raxol.Core.Stores.Dets.close(handle)

    pid = start_durable_poller!(:durable_junk, dets_path: path, dets_name: name)

    assert_receive {:poll_request, _url, req_opts}
    refute Keyword.fetch!(req_opts, :json) |> Map.has_key?(:offset)

    park_in_backoff_and_stop(pid, :durable_junk)
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
