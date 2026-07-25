defmodule Raxol.Gateway.Adapter.EmailTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Email
  alias Raxol.Gateway.Route

  @route %Route{platform: :email, chat_type: :dm, chat_id: "to@example.com"}

  defp capture_conn(test_pid, extra \\ [], result \\ nil) do
    send_fn = fn email, relay_opts ->
      send(test_pid, {:smtp_send, email, relay_opts})

      case result do
        nil -> "2.0.0 OK queued"
        fun -> fun.()
      end
    end

    {:ok, conn} =
      Email.connect(
        [relay: "smtp.example.com", from: "bot@example.com", send_fn: send_fn] ++
          extra
      )

    conn
  end

  describe "connect/1" do
    test "requires relay and from" do
      assert {:error, :no_relay} = Email.connect(from: "a@b.c")
      assert {:error, :no_relay} = Email.connect(relay: "", from: "a@b.c")
      assert {:error, :no_from} = Email.connect(relay: "smtp.example.com")

      assert {:ok, _conn} =
               Email.connect(relay: "smtp.example.com", from: "a@b.c")

      assert {:ok, _conn} =
               Email.connect(%{relay: "smtp.example.com", from: "a@b.c"})
    end

    test "rejects non-config shapes" do
      assert {:error, :invalid_config} = Email.connect("smtp.example.com")
      assert {:error, :invalid_config} = Email.connect(%{"relay" => "x"})
    end
  end

  test "platform/0, disconnect/1, and inbound is a follow-up" do
    assert Email.platform() == :email
    assert Email.disconnect([]) == :ok
    assert Email.normalize_event(%{any: "thing"}) == :ignore
    assert Email.normalize_event("raw") == :ignore
  end

  describe "send_message/3" do
    test "submits a text/plain MIME message that round-trips, UTF-8 intact" do
      conn = capture_conn(self())
      body = "status: héllo from cron ☕\nline two"

      assert :ok = Email.send_message(conn, @route, body)

      assert_receive {:smtp_send, {from, [to], mime}, _relay_opts}
      assert from == "bot@example.com"
      assert to == "to@example.com"

      {"text", "plain", headers, _params, decoded_body} =
        :mimemail.decode(mime, [])

      header_map = Map.new(headers)
      assert header_map["From"] == "bot@example.com"
      assert header_map["To"] == "to@example.com"
      assert header_map["Subject"] == "Raxol Gateway"
      assert decoded_body == body
    end

    test "the subject is configurable per connection" do
      conn = capture_conn(self(), subject: "Nightly digest")

      assert :ok = Email.send_message(conn, @route, "hi")

      assert_receive {:smtp_send, {_from, _to, mime}, _relay_opts}
      {"text", "plain", headers, _params, _body} = :mimemail.decode(mime, [])
      assert {"Subject", "Nightly digest"} in headers
    end

    test "passes only the configured relay options through" do
      conn =
        capture_conn(self(),
          port: 587,
          username: "bot",
          password: "hunter2",
          tls: :always
        )

      assert :ok = Email.send_message(conn, @route, "hi")

      assert_receive {:smtp_send, _email, relay_opts}

      assert Enum.sort(relay_opts) ==
               Enum.sort(
                 relay: "smtp.example.com",
                 port: 587,
                 username: "bot",
                 password: "hunter2",
                 tls: :always
               )

      refute Keyword.has_key?(relay_opts, :send_fn)
      refute Keyword.has_key?(relay_opts, :from)
      refute Keyword.has_key?(relay_opts, :subject)
    end

    test "empty and whitespace-only replies are no-ops" do
      conn = capture_conn(self())

      assert :ok = Email.send_message(conn, @route, "")
      assert :ok = Email.send_message(conn, @route, " \n  ")
      refute_receive {:smtp_send, _email, _opts}, 50
    end

    test "invalid UTF-8 is rejected without a submission" do
      conn = capture_conn(self())

      assert {:error, :invalid_encoding} =
               Email.send_message(conn, @route, <<0xFF, 0xFE>>)

      refute_receive {:smtp_send, _email, _opts}, 50
    end

    test "SMTP failures classify and emit telemetry, reason only" do
      test_pid = self()
      handler_id = {__MODULE__, :smtp_failure}

      :telemetry.attach(
        handler_id,
        [:raxol_gateway, :email_adapter, :error],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_error, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      fail = fn ->
        {:error, :retries_exceeded, {:network_failure, ~c"host", :timeout}}
      end

      conn = capture_conn(self(), [], fail)

      assert {:error, {:smtp_error, :retries_exceeded, _detail}} =
               Email.send_message(conn, @route, "hi")

      assert_receive {:telemetry_error, metadata}
      assert metadata.method == "send_blocking"
      refute inspect(metadata) =~ "hunter2"
    end

    test "plain error tuples and unexpected results classify" do
      conn = capture_conn(self(), [], fn -> {:error, :no_credentials} end)
      assert {:error, :no_credentials} = Email.send_message(conn, @route, "hi")

      conn2 =
        capture_conn(self(), [], fn -> [{~c"to@example.com", "250 ok"}] end)

      assert {:error, {:unexpected_result, _lmtp}} =
               Email.send_message(conn2, @route, "hi")
    end

    test "non-binary rendered payloads are unsupported" do
      conn = capture_conn(self())

      assert {:error, :unsupported_rendered} =
               Email.send_message(conn, @route, {:view, []})
    end
  end
end
