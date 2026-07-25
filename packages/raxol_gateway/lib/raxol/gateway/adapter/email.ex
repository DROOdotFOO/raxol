defmodule Raxol.Gateway.Adapter.Email do
  @moduledoc """
  `Raxol.Gateway.Adapter` implementation for outbound email.

  Email is the delivery-only platform this slice: `send_message/3` submits
  a plain-text message over SMTP, which is what makes `Raxol.Gateway.Delivery`'s
  `{:home, route}` mode useful for cron and background results without any
  platform approval process. `normalize_event/1` always returns `:ignore` -
  inbound email (an IMAP/POP3 poller feeding this callback) is a separate
  follow-up.

  Requires the optional `:gen_smtp` dependency for MIME composition and
  SMTP submission; without it `send_message/3` returns
  `{:error, :gen_smtp_not_available}`.

  ## Connection

  `connect/1` requires `:relay` (the SMTP server) and `:from` (the sender
  address) and fails fast without them. Everything else is optional:

    * `:port`, `:username`, `:password`, `:ssl`, `:tls`, `:tls_options`,
      `:auth`, `:hostname`, `:timeout`, `:retries`, `:no_mx_lookups` -
      passed through to `:gen_smtp_client` untouched
    * `:subject` - the Subject header (default "Raxol Gateway")
    * `:send_fn` - a 2-arity `(email_tuple, relay_opts) -> receipt |
      {:error, ...}` override for tests or alternative submission paths;
      the default calls `:gen_smtp_client.send_blocking/2`

  The connection is stateless; the returned handle is the validated
  option list. Routes address a mailbox: `chat_id` is the recipient
  address (`platform: :email, chat_type: :dm, chat_id: "ops@example.com"`).

  ## Outbound

  The rendered reply becomes the text/plain body (charset utf-8,
  quoted-printable), one message per send - email has no chat-style
  length limit, so nothing is chunked. Empty or whitespace-only replies
  are a no-op. Failures emit `[:raxol_gateway, :email_adapter, :error]`
  telemetry with the classified reason only; the conn (which may carry
  the SMTP password) is never logged.
  """

  @behaviour Raxol.Gateway.Adapter

  @compile {:no_warn_undefined, [:gen_smtp_client, :mimemail]}

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
  @spec normalize_event(term()) :: :ignore
  def normalize_event(_raw), do: :ignore

  @impl true
  @spec send_message(keyword(), Raxol.Gateway.Route.t() | map(), term()) ::
          :ok | {:error, term()}
  def send_message(conn, %{chat_id: to}, rendered)
      when is_binary(to) and is_binary(rendered) do
    cond do
      not String.valid?(rendered) ->
        {:error, :invalid_encoding}

      String.trim(rendered) == "" ->
        :ok

      true ->
        with {:ok, mime} <- compose(conn, to, rendered) do
          submit(conn, to, mime)
        end
    end
  end

  def send_message(_conn, _route, _rendered),
    do: {:error, :unsupported_rendered}

  defp compose(conn, to, body) do
    if Code.ensure_loaded?(:mimemail) do
      headers = [
        {"From", Keyword.fetch!(conn, :from)},
        {"To", to},
        {"Subject", Keyword.get(conn, :subject, @default_subject)}
      ]

      params = %{
        content_type_params: [{"charset", "utf-8"}],
        transfer_encoding: "quoted-printable"
      }

      {:ok, :mimemail.encode({"text", "plain", headers, params, body})}
    else
      {:error, :gen_smtp_not_available}
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
