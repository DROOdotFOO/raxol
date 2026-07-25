defmodule Raxol.Telegram.HTTP do
  @moduledoc """
  Shared HTTP helpers for Bot API calls that Telegex doesn't cover.

  Used by `Raxol.Telegram.RichMessage.Sender` (Bot API 10.1 `sendRichMessage`)
  and `Raxol.Telegram.Guardian` (chat-join-request handlers). Encapsulates
  token / base-URL resolution, response classification, and the optional
  `Req` dependency.

  ## Options

    * `:bot_token`: per-call override of `:raxol_telegram` app env
    * `:api_base`: per-call override; defaults to `https://api.telegram.org`
    * `:timeout`: receive timeout in ms (default 10,000)
    * `:post_fn`: 2-arity `(url, req_opts) -> {:ok, resp} | {:error, term}`
      override for tests or alternative HTTP clients
    * `:get_fn`: same shape, for `download_file/2`'s file GET

  ## Return shape

    * `{:ok, result}` when Bot API returns `200 OK` with `"ok": true`
    * `{:error, :no_bot_token}` when neither opts nor app env carries one
    * `{:error, {:bot_api_error, status_or_code, body_or_desc}}` for API failures
    * `{:error, :req_not_available}` when `Req` is missing and no `:post_fn`/`:get_fn`
    * `{:error, {:http_error, reason}}` for transport failures

  Download URLs embed the bot token (`/file/bot<token>/...`), so neither the
  URL nor the raw request may appear in logs or error terms.
  """

  @compile {:no_warn_undefined, [Req]}

  @default_api_base "https://api.telegram.org"
  @default_timeout 10_000

  @type post_opts :: [
          bot_token: String.t(),
          api_base: String.t(),
          timeout: pos_integer(),
          post_fn: (String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          get_fn: (String.t(), keyword() -> {:ok, map()} | {:error, term()})
        ]

  @doc """
  POSTs a JSON body to a Bot API method.

  `method` is the bare method name (e.g. `"sendRichMessage"`,
  `"approveChatJoinRequest"`); URL assembly handles the `bot<token>/` prefix.
  """
  @spec post(String.t(), map(), post_opts()) :: {:ok, term()} | {:error, term()}
  def post(method, body, opts \\ []) when is_binary(method) and is_map(body) do
    with {:ok, token} <- fetch_token(opts) do
      base = fetch_base(opts)
      url = "#{base}/bot#{token}/#{method}"
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      post_fn = Keyword.get(opts, :post_fn, &default_post/2)

      classify(post_fn.(url, json: body, receive_timeout: timeout))
    end
  end

  @doc """
  Downloads the file behind a Bot API `file_id`.

  Resolves the server path with `getFile`, then GETs
  `<base>/file/bot<token>/<file_path>` and returns the raw bytes. The Bot
  API caps `getFile` at 20MB; larger files fail with a `:bot_api_error`.
  """
  @spec download_file(String.t(), post_opts()) :: {:ok, binary()} | {:error, term()}
  def download_file(file_id, opts \\ []) when is_binary(file_id) do
    with {:ok, result} <- post("getFile", %{file_id: file_id}, opts),
         {:ok, path} <- file_path(result),
         {:ok, token} <- fetch_token(opts) do
      url = "#{fetch_base(opts)}/file/bot#{token}/#{path}"
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      get_fn = Keyword.get(opts, :get_fn, &default_get/2)

      classify_download(get_fn.(url, receive_timeout: timeout))
    end
  end

  @doc "Returns the resolved bot token or `{:error, :no_bot_token}`."
  @spec fetch_token(keyword()) :: {:ok, String.t()} | {:error, :no_bot_token}
  def fetch_token(opts) do
    case Keyword.get(opts, :bot_token) || Application.get_env(:raxol_telegram, :bot_token) do
      nil -> {:error, :no_bot_token}
      "" -> {:error, :no_bot_token}
      token when is_binary(token) -> {:ok, token}
    end
  end

  @doc "Returns the resolved API base URL."
  @spec fetch_base(keyword()) :: String.t()
  def fetch_base(opts) do
    Keyword.get(opts, :api_base) ||
      Application.get_env(:raxol_telegram, :api_base) ||
      @default_api_base
  end

  defp classify({:ok, %{status: 200, body: %{"ok" => true, "result" => result}}}),
    do: {:ok, result}

  defp classify({:ok, %{status: 200, body: %{"ok" => false, "description" => desc} = body}}),
    do: {:error, {:bot_api_error, body["error_code"] || 200, desc}}

  defp classify({:ok, %{status: status, body: body}}),
    do: {:error, {:bot_api_error, status, body}}

  defp classify({:error, :req_not_available}),
    do: {:error, :req_not_available}

  defp classify({:error, reason}),
    do: {:error, {:http_error, reason}}

  defp file_path(%{"file_path" => path}) when is_binary(path) and path != "", do: {:ok, path}
  defp file_path(_result), do: {:error, :no_file_path}

  defp classify_download({:ok, %{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp classify_download({:ok, %{status: 200}}),
    do: {:error, :unexpected_download_body}

  defp classify_download({:ok, %{status: status}}),
    do: {:error, {:download_status, status}}

  defp classify_download({:error, :req_not_available}),
    do: {:error, :req_not_available}

  defp classify_download({:error, reason}),
    do: {:error, {:http_error, reason}}

  defp default_post(url, opts) do
    if Code.ensure_loaded?(Req) do
      Req.post(url, opts)
    else
      {:error, :req_not_available}
    end
  end

  defp default_get(url, opts) do
    if Code.ensure_loaded?(Req) do
      Req.get(url, opts)
    else
      {:error, :req_not_available}
    end
  end
end
