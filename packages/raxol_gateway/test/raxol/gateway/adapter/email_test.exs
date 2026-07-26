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

  test "platform/0 and disconnect/1" do
    assert Email.platform() == :email
    assert Email.disconnect([]) == :ok
  end

  describe "normalize_event/1 (inbound)" do
    test "maps a plain-text message to a dm route and text event" do
      raw =
        raw_mail(
          [
            {"From", "bob@x.com"},
            {"To", "bot@example.com"},
            {"Subject", "hi"},
            {"Message-ID", "<m1@x.com>"}
          ],
          "hello there"
        )

      assert {:ok, route, event} = Email.normalize_event(raw)
      assert %Route{platform: :email, chat_type: :dm, chat_id: "bob@x.com"} = route
      assert route.user_id == "bob@x.com"
      assert event.text == "hello there"
    end

    test "strips the display name and lower-cases the sender address" do
      raw = raw_mail([{"From", "Bob Smith <Bob@X.COM>"}, {"To", "bot@x"}], "hi")
      assert {:ok, %Route{chat_id: "bob@x.com"}, _event} = Email.normalize_event(raw)
    end

    test "picks the text/plain part out of a multipart/alternative message" do
      raw =
        raw_multipart(
          [{"From", "a@x.com"}, {"To", "bot@x"}, {"Subject", "Re: s"}],
          "the plain part",
          "<p>the html part</p>"
        )

      assert {:ok, _route, %{text: "the plain part"}} = Email.normalize_event(raw)
    end

    test "trims quoted history below the reply" do
      raw =
        raw_mail(
          [{"From", "a@x.com"}, {"To", "bot@x"}],
          "Yes, ship it.\r\n\r\nOn Mon, Alice wrote:\r\n> old quoted line"
        )

      assert {:ok, _route, %{text: "Yes, ship it."}} = Email.normalize_event(raw)
    end

    test "trims below the RFC 3676 signature but keeps a bare -- content line" do
      sig = raw_mail([{"From", "a@x.com"}, {"To", "bot@x"}], "the reply\r\n-- \r\nSignature")
      assert {:ok, _route, %{text: "the reply"}} = Email.normalize_event(sig)

      dashes = raw_mail([{"From", "a@x.com"}, {"To", "bot@x"}], "before\r\n--\r\nafter")
      assert {:ok, _route, %{text: "before\n--\nafter"}} = Email.normalize_event(dashes)
    end

    test "reinterprets a non-UTF-8 (Latin-1) body as valid UTF-8" do
      # A lone 0xE9 byte is "é" in Latin-1 but invalid UTF-8. :mimemail does not
      # transcode charset, so without the inbound guard this text would reach the
      # agent turn as invalid UTF-8 and crash the first Jason.encode/LiveView
      # render. The guard reinterprets it as Latin-1 -> valid UTF-8.
      raw = raw_mail([{"From", "a@x.com"}, {"To", "bot@x"}], "caf" <> <<0xE9>>)

      assert {:ok, _route, %{text: text}} = Email.normalize_event(raw)
      assert String.valid?(text)
      assert text == "café"
    end

    test "surfaces threading metadata under :email" do
      raw =
        raw_mail(
          [
            {"From", "Bob <bob@x.com>"},
            {"To", "bot@x"},
            {"Subject", "Re: hi"},
            {"Message-ID", "<m1@x.com>"},
            {"In-Reply-To", "<p0@x.com>"},
            {"References", "<r0@x.com> <p0@x.com>"}
          ],
          "body"
        )

      assert {:ok, _route, %{email: meta}} = Email.normalize_event(raw)
      assert meta.message_id == "<m1@x.com>"
      assert meta.in_reply_to == "<p0@x.com>"
      assert meta.references == ["<r0@x.com>", "<p0@x.com>"]
      assert meta.subject == "Re: hi"
      assert meta.from == "bob@x.com"
    end

    test "accepts a %{rfc822: raw} envelope" do
      raw = raw_mail([{"From", "a@x.com"}, {"To", "bot@x"}], "hi")
      assert {:ok, %Route{chat_id: "a@x.com"}, _event} = Email.normalize_event(%{rfc822: raw})
    end

    test "non-mail, unparseable, and sender-less input are ignored" do
      assert Email.normalize_event(%{any: "thing"}) == :ignore
      assert Email.normalize_event("raw") == :ignore
      assert Email.normalize_event(<<0xFF, 0xFE>>) == :ignore
      assert Email.normalize_event(raw_mail([{"To", "bot@x"}], "no sender")) == :ignore
    end
  end

  describe "send_message/3 (threading)" do
    test "sets In-Reply-To, References, and a Re: subject from thread_lookup" do
      thread = %{message_id: "<m1@x.com>", references: ["<r0@x.com>"], subject: "status"}
      conn = capture_conn(self(), thread_lookup: fn _route -> thread end)

      assert :ok = Email.send_message(conn, @route, "reply body")
      assert_receive {:smtp_send, {_from, _to, mime}, _relay}
      headers = decoded_headers(mime)

      assert headers["In-Reply-To"] == "<m1@x.com>"
      assert headers["References"] == "<r0@x.com> <m1@x.com>"
      assert headers["Subject"] == "Re: status"
      assert headers["Message-ID"] =~ ~r/^<.+>$/
    end

    test "does not double the Re: prefix on an already-Re: subject" do
      conn =
        capture_conn(self(),
          thread_lookup: fn _route -> %{message_id: "<m@x>", subject: "Re: hi"} end
        )

      assert :ok = Email.send_message(conn, @route, "body")
      assert_receive {:smtp_send, {_from, _to, mime}, _relay}
      assert decoded_headers(mime)["Subject"] == "Re: hi"
    end

    test "without a thread, carries only a generated Message-ID and the default subject" do
      conn = capture_conn(self())

      assert :ok = Email.send_message(conn, @route, "body")
      assert_receive {:smtp_send, {_from, _to, mime}, _relay}
      headers = decoded_headers(mime)

      assert headers["Subject"] == "Raxol Gateway"
      assert headers["Message-ID"] =~ ~r/^<.+>$/
      refute Map.has_key?(headers, "In-Reply-To")
    end

    test "message_id_fn overrides the generated Message-ID" do
      conn = capture_conn(self(), message_id_fn: fn -> "<fixed@raxol.io>" end)

      assert :ok = Email.send_message(conn, @route, "body")
      assert_receive {:smtp_send, {_from, _to, mime}, _relay}
      assert decoded_headers(mime)["Message-ID"] == "<fixed@raxol.io>"
    end
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

  # -- helpers ----------------------------------------------------------------

  defp raw_mail(headers, body) do
    lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)
    Enum.join(lines ++ ["", body], "\r\n") <> "\r\n"
  end

  defp raw_multipart(headers, plain, html) do
    boundary = "BOUND"

    all_headers =
      headers ++
        [
          {"MIME-Version", "1.0"},
          {"Content-Type", ~s(multipart/alternative; boundary="#{boundary}")}
        ]

    header_lines = Enum.map(all_headers, fn {k, v} -> "#{k}: #{v}" end)

    parts = [
      "--#{boundary}",
      "Content-Type: text/plain; charset=utf-8",
      "",
      plain,
      "--#{boundary}",
      "Content-Type: text/html; charset=utf-8",
      "",
      html,
      "--#{boundary}--"
    ]

    Enum.join(header_lines ++ [""] ++ parts, "\r\n") <> "\r\n"
  end

  defp decoded_headers(mime) do
    {_type, _sub, headers, _params, _body} = :mimemail.decode(mime, [])
    Map.new(headers)
  end
end
