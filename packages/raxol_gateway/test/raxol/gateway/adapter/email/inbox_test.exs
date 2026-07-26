defmodule Raxol.Gateway.Adapter.Email.InboxTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Email.Inbox

  defp start_inbox(opts) do
    start_supervised!({Inbox, [name: nil] ++ opts})
  end

  test "delivers each fetched message to on_message, in order" do
    test = self()

    fetch_fn = fn
      nil -> {:ok, ["m1", "m2", "m3"], :done}
      :done -> {:ok, [], :done}
    end

    start_inbox(
      fetch_fn: fetch_fn,
      on_message: fn raw -> send(test, {:msg, raw}) end,
      interval_ms: 5
    )

    assert_receive {:msg, "m1"}
    assert_receive {:msg, "m2"}
    assert_receive {:msg, "m3"}
  end

  test "threads the returned cursor into the next fetch" do
    test = self()

    fetch_fn = fn cursor ->
      send(test, {:fetched, cursor})
      {:ok, [], next_cursor(cursor)}
    end

    start_inbox(
      fetch_fn: fetch_fn,
      on_message: fn _ -> :ok end,
      interval_ms: 5,
      initial_cursor: 0
    )

    assert_receive {:fetched, 0}
    assert_receive {:fetched, 1}
  end

  test "a crashing on_message is caught; sibling messages still deliver" do
    test = self()

    on_message = fn
      "boom" -> raise "kaboom"
      raw -> send(test, {:ok_msg, raw})
    end

    start_inbox(
      fetch_fn: fn _ -> {:ok, ["a", "boom", "b"], :done} end,
      on_message: on_message,
      interval_ms: 50
    )

    assert_receive {:ok_msg, "a"}
    assert_receive {:ok_msg, "b"}
  end

  test "a fetch error backs off without delivering or crashing" do
    test = self()

    inbox =
      start_inbox(
        fetch_fn: fn cursor ->
          send(test, {:fetched, cursor})
          {:error, :imap_down}
        end,
        on_message: fn raw -> send(test, {:msg, raw}) end,
        interval_ms: 5
      )

    assert_receive {:fetched, nil}
    refute_receive {:msg, _raw}, 50
    assert Process.alive?(inbox)
  end

  test "an unexpected fetch result backs off instead of crashing" do
    test = self()

    inbox =
      start_inbox(
        fetch_fn: fn cursor ->
          send(test, {:fetched, cursor})
          :garbage
        end,
        on_message: fn _ -> :ok end,
        interval_ms: 5
      )

    assert_receive {:fetched, nil}
    assert Process.alive?(inbox)
  end

  test "drops a message larger than max_bytes and emits telemetry" do
    test = self()
    handler = {__MODULE__, :oversized}

    :telemetry.attach(
      handler,
      [:raxol_gateway, :email_inbox, :oversized],
      fn _event, meas, meta, _config -> send(test, {:oversized, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    big = String.duplicate("x", 200)

    start_inbox(
      fetch_fn: fn _ -> {:ok, ["small", big], :done} end,
      on_message: fn raw -> send(test, {:msg, byte_size(raw)}) end,
      max_bytes: 100,
      interval_ms: 50
    )

    assert_receive {:msg, 5}
    assert_receive {:oversized, %{bytes: 200}, %{limit: 100}}
    refute_receive {:msg, 200}, 50
  end

  defp next_cursor(nil), do: 1
  defp next_cursor(n) when is_integer(n), do: n + 1
end
