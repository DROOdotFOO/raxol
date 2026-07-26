defmodule Raxol.Gateway.Adapter.Email do
  @moduledoc """
  `Raxol.Gateway.Adapter` implementation for email, both directions.

  Outbound: `send_message/3` submits a plain-text message over SMTP, which is
  what makes `Raxol.Gateway.Delivery`'s `{:home, route}` mode useful for cron
  and background results without any platform approval process.

  Inbound: `normalize_event/1` parses a raw RFC822 message into
  `{:ok, route, %{text: body}}` so an email thread becomes a per-chat session
  like any other platform. The adapter is a pure translator; the transport that
  actually pulls mail off a mailbox lives in `Raxol.Gateway.Adapter.Email.Inbox`
  (sink-agnostic, injectable), and reply threading state lives in
  `Raxol.Gateway.Adapter.Email.ThreadStore`. Neither is bundled here so the
  transport (IMAP/POP/Gmail API/SMTP listener) stays the deployment's choice.

  Requires the optional `:gen_smtp` dependency for MIME composition, SMTP
  submission (outbound), and parsing (`:mimemail`, inbound). Without it,
  `send_message/3` returns `{:error, :gen_smtp_not_available}` and
  `normalize_event/1` returns `:ignore`.

  ## Connection

  `connect/1` requires `:relay` (the SMTP server) and `:from` (the sender
  address) and fails fast without them. Everything else is optional:

    * `:port`, `:username`, `:password`, `:ssl`, `:tls`, `:tls_options`,
      `:auth`, `:hostname`, `:timeout`, `:retries`, `:no_mx_lookups` -
      passed through to `:gen_smtp_client` untouched
    * `:subject` - the Subject header for un-threaded sends (default
      "Raxol Gateway"); a threaded reply derives `Re: <original>` instead
    * `:thread_lookup` - a 1-arity `(route -> meta | {:ok, meta} | nil)`
      resolving the inbound message a reply threads against, where `meta` is
      the `:email` map `normalize_event/1` surfaced (`:message_id`,
      `:references`, `:subject`). `ThreadStore.thread_lookup_fn/1` builds one;
      absent, replies carry only their own generated `Message-ID`.
    * `:message_id_fn` - a 0-arity override generating the outbound
      `Message-ID`; the default derives one from the `:from` domain
    * `:send_fn` - a 2-arity `(email_tuple, relay_opts) -> receipt |
      {:error, ...}` override for tests or alternative submission paths;
      the default calls `:gen_smtp_client.send_blocking/2`

  The connection is stateless; the returned handle is the validated
  option list. Routes address a mailbox: `chat_id` is the address
  (`platform: :email, chat_type: :dm, chat_id: "ops@example.com"`).

  ## Inbound

  `normalize_event/1` accepts a raw RFC822 binary (or `%{rfc822: binary}`),
  parses it with `:mimemail.decode`, and routes on the normalized sender
  address (`chat_type: :dm`, `chat_id` = the lower-cased address, display name
  and angle brackets stripped). The event is
  `%{text: body, email: meta}` where `body` is the first `text/plain` part
  with quoted history trimmed and `meta` carries `:message_id`, `:in_reply_to`,
  `:references`, `:subject`, and `:from` for threading and session wiring.
  A message with no parseable sender or no `text/plain` part, non-mail input,
  or (when `:mimemail` is absent) any input, returns `:ignore`. Parsing never
  raises: a malformed message is `:ignore`, not a crash.

  ## Security: the sender address is unauthenticated

  The `From` header is trivially forgeable, and this adapter does NOT verify
  SPF/DKIM/DMARC. The route's `chat_id`/`user_id` are the parsed sender address,
  so any authorization keyed on them (`Raxol.Gateway.Pairing.authorize/2`,
  allowlists) is only as trustworthy as the mail path that produced the message.
  Run inbound email behind an MTA that rejects or authenticates spoofed senders,
  and treat a raw-inbound feed with no upstream authentication as anonymous. The
  agent runs tools and can spend, so a spoofed `From` reaching a paired session
  is a privilege escalation. If you need in-process verification, gate the feed's
  `:on_message` on the parsed `Authentication-Results` header before routing.

  ## Outbound

  The rendered reply becomes the text/plain body (charset utf-8,
  quoted-printable), one message per send - email has no chat-style
  length limit, so nothing is chunked. Every send carries a generated
  `Message-ID`; when `:thread_lookup` resolves the inbound message being
  replied to, the send also sets `In-Reply-To` and `References` (and a
  `Re:`-prefixed Subject) so mail clients keep the conversation together.
  Empty or whitespace-only replies are a no-op. Failures emit
  `[:raxol_gateway, :email_adapter, :error]` telemetry with the classified
  reason only; the conn (which may carry the SMTP password) is never logged.
  """

  @behaviour Raxol.Gateway.Adapter

  @compile {:no_warn_undefined, [:gen_smtp_client, :mimemail]}

  alias Raxol.Gateway.Route

  @default_subject "Raxol Gateway"

  @relay_option_keys [
    :relay,
    :port,
    :username,
    :password,
    :ssl,
    :tls,
    :tls_options,
    :auth,
    :hostname,
    :timeout,
    :retries,
    :no_mx_lookups
  ]

  @impl true
  @spec connect(keyword() | map()) ::
          {:ok, keyword()} | {:error, :no_relay | :no_from | :invalid_config}
  def connect(config) when is_list(config) do
    if Keyword.keyword?(config) do
      validate_conn(config)
    else
      {:error, :invalid_config}
    end
  end

  def connect(config) when is_map(config) do
    if Enum.all?(Map.keys(config), &is_atom/1) do
      config |> Keyword.new() |> validate_conn()
    else
      {:error, :invalid_config}
    end
  end

  def connect(_config), do: {:error, :invalid_config}

  defp validate_conn(opts) do
    cond do
      not present?(opts, :relay) -> {:error, :no_relay}
      not present?(opts, :from) -> {:error, :no_from}
      true -> {:ok, opts}
    end
  end

  defp present?(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> true
      _other -> false
    end
  end

  @impl true
  @spec disconnect(keyword()) :: :ok
  def disconnect(_conn), do: :ok

  @impl true
  @spec platform() :: :email
  def platform, do: :email

  @impl true
  @spec normalize_event(term()) :: {:ok, Route.t(), map()} | :ignore
  def normalize_event(raw) when is_binary(raw), do: parse_inbound(raw)
  def normalize_event(%{rfc822: raw}) when is_binary(raw), do: parse_inbound(raw)
  def normalize_event(_raw), do: :ignore

  # -- inbound parsing --------------------------------------------------------

  defp parse_inbound(raw) do
    if Code.ensure_loaded?(:mimemail) do
      do_parse_inbound(raw)
    else
      :ignore
    end
  end

  defp do_parse_inbound(raw) do
    with {:ok, decoded} <- safe_decode(raw),
         headers = mail_headers(decoded),
         {:ok, from} <- fetch_address(headers, "from"),
         {:ok, text} <- find_text_plain(decoded) do
      route =
        Route.new(%{
          platform: :email,
          chat_type: :dm,
          chat_id: from,
          user_id: from
        })

      {:ok, route, %{text: strip_quoted(text), email: mail_meta(headers, from)}}
    else
      _other -> :ignore
    end
  end

  defp safe_decode(raw) do
    {:ok, :mimemail.decode(raw, [])}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp mail_headers({_type, _sub, headers, _params, _body}), do: headers

  defp find_text_plain({"text", "plain", _h, _p, body}) when is_binary(body),
    do: {:ok, body}

  defp find_text_plain({"multipart", _sub, _h, _p, parts}) when is_list(parts) do
    Enum.find_value(parts, :error, fn part ->
      case find_text_plain(part) do
        {:ok, _body} = ok -> ok
        :error -> nil
      end
    end)
  end

  defp find_text_plain(_other), do: :error

  defp fetch_header(headers, name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == downcased, do: value
    end)
  end

  defp fetch_address(headers, name) do
    case normalize_address(fetch_header(headers, name)) do
      "" -> :error
      address -> {:ok, address}
    end
  end

  defp normalize_address(nil), do: ""

  defp normalize_address(raw) do
    raw = to_string(raw)

    address =
      case Regex.run(~r/<([^>]+)>/, raw) do
        [_full, inner] -> inner
        _no_brackets -> raw
      end

    address |> String.trim() |> String.downcase()
  end

  defp mail_meta(headers, from) do
    %{
      message_id: fetch_header(headers, "message-id"),
      in_reply_to: fetch_header(headers, "in-reply-to"),
      references: parse_references(fetch_header(headers, "references")),
      subject: fetch_header(headers, "subject"),
      from: from
    }
  end

  defp parse_references(nil), do: []

  defp parse_references(raw) do
    raw
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
  end

  # Trim quoted history: keep the reply text above the first quote marker
  # (a `>`-prefixed line, an "On ... wrote:" attribution, an Outlook-style
  # "----- Original Message -----" divider, or the RFC 3676 "-- " signature
  # delimiter -- the exact "dash dash space" form, so a bare "--" content line
  # is NOT a boundary). Best-effort and English-attribution-only; a non-English
  # "wrote:" equivalent is left in place rather than risking a wrong cut.
  defp strip_quoted(body) do
    body
    |> String.split(~r/\r?\n/)
    |> take_until_quote([])
    |> Enum.join("\n")
    |> String.trim()
  end

  defp take_until_quote([], acc), do: Enum.reverse(acc)

  defp take_until_quote([line | rest], acc) do
    if quote_boundary?(line) do
      Enum.reverse(acc)
    else
      take_until_quote(rest, [line | acc])
    end
  end

  defp quote_boundary?(line) do
    trimmed = String.trim_trailing(line)

    line == "-- " or String.starts_with?(trimmed, ">") or
      Regex.match?(~r/^-{2,}\s*Original Message\s*-{2,}/i, trimmed) or
      Regex.match?(~r/^On\b.+\bwrote:$/, trimmed)
  end

  # -- outbound ---------------------------------------------------------------

  @impl true
  @spec send_message(keyword(), Raxol.Gateway.Route.t() | map(), term()) ::
          :ok | {:error, term()}
  def send_message(conn, %{chat_id: to} = route, rendered)
      when is_binary(to) and is_binary(rendered) do
    cond do
      not String.valid?(rendered) ->
        {:error, :invalid_encoding}

      String.trim(rendered) == "" ->
        :ok

      true ->
        thread = resolve_thread(conn, route)

        with {:ok, mime} <- compose(conn, to, rendered, thread) do
          submit(conn, to, mime)
        end
    end
  end

  def send_message(_conn, _route, _rendered),
    do: {:error, :unsupported_rendered}

  defp resolve_thread(conn, route) do
    case Keyword.get(conn, :thread_lookup) do
      fun when is_function(fun, 1) ->
        case fun.(route) do
          %{} = meta -> meta
          {:ok, %{} = meta} -> meta
          _none -> nil
        end

      _absent ->
        nil
    end
  end

  defp compose(conn, to, body, thread) do
    if Code.ensure_loaded?(:mimemail) do
      headers =
        [
          {"From", Keyword.fetch!(conn, :from)},
          {"To", to},
          {"Subject", subject(conn, thread)},
          {"Message-ID", generate_message_id(conn)}
        ] ++ threading_headers(thread)

      params = %{
        content_type_params: [{"charset", "utf-8"}],
        transfer_encoding: "quoted-printable"
      }

      {:ok, :mimemail.encode({"text", "plain", headers, params, body})}
    else
      {:error, :gen_smtp_not_available}
    end
  end

  defp subject(_conn, %{subject: original})
       when is_binary(original) and original != "",
       do: re_prefix(original)

  defp subject(conn, _thread), do: Keyword.get(conn, :subject, @default_subject)

  defp re_prefix(subject) do
    if Regex.match?(~r/^\s*re:/i, subject), do: subject, else: "Re: " <> subject
  end

  defp threading_headers(%{message_id: message_id} = thread)
       when is_binary(message_id) and message_id != "" do
    references =
      ((thread[:references] || []) ++ [message_id])
      |> Enum.uniq()
      |> Enum.join(" ")

    [{"In-Reply-To", message_id}, {"References", references}]
  end

  defp threading_headers(_thread), do: []

  defp generate_message_id(conn) do
    case Keyword.get(conn, :message_id_fn) do
      fun when is_function(fun, 0) -> fun.()
      _absent -> default_message_id(conn)
    end
  end

  defp default_message_id(conn) do
    unique =
      Integer.to_string(System.unique_integer([:positive])) <>
        "." <> Integer.to_string(System.system_time(:microsecond))

    "<raxol-" <> unique <> "@" <> from_domain(conn) <> ">"
  end

  defp from_domain(conn) do
    conn
    |> Keyword.fetch!(:from)
    |> normalize_address()
    |> String.split("@")
    |> List.last()
    |> case do
      nil -> "localhost"
      "" -> "localhost"
      domain -> domain
    end
  end

  defp submit(conn, to, mime) do
    send_fn = Keyword.get(conn, :send_fn, &default_send/2)
    email = {Keyword.fetch!(conn, :from), [to], mime}

    case send_fn.(email, relay_options(conn)) do
      receipt when is_binary(receipt) ->
        :ok

      {:error, type, message} ->
        classify_error({:smtp_error, type, message})

      {:error, reason} ->
        classify_error(reason)

      other ->
        classify_error({:unexpected_result, other})
    end
  end

  defp classify_error(reason) do
    emit_error("send_blocking", reason)
    {:error, reason}
  end

  defp relay_options(conn), do: Keyword.take(conn, @relay_option_keys)

  defp default_send(email, relay_opts) do
    if Code.ensure_loaded?(:gen_smtp_client) do
      :gen_smtp_client.send_blocking(email, relay_opts)
    else
      {:error, :gen_smtp_not_available}
    end
  end

  # Reason only, never the conn: it may carry the SMTP password.
  defp emit_error(method, reason) do
    :telemetry.execute(
      [:raxol_gateway, :email_adapter, :error],
      %{count: 1},
      %{method: method, reason: reason}
    )
  end
end
