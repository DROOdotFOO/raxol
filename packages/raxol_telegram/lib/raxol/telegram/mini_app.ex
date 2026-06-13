defmodule Raxol.Telegram.MiniApp do
  @moduledoc """
  Helpers for building inline-keyboard buttons that launch consumer-hosted
  Telegram Mini Apps (`web_app: %{url: ...}`).

  Mini Apps are HTTPS-served HTML/JS pages that Telegram renders in an
  in-client webview when the user taps a button. Used by `Raxol.Telegram.Guardian`
  for the `:ask_mini_app` decision path: an applicant gets a private message
  with a button that opens the consumer's verification UI; the mini-app's
  backend later calls `answerChatJoinRequestQuery` (or
  `approveChatJoinRequest` / `declineChatJoinRequest`) directly.

  `raxol_telegram` does not host the mini-app itself. The consumer provides
  the URL and is responsible for its TLS, `WebAppInitData` HMAC verification
  (using the bot token), and the eventual decision call.

  ## URL parameter contract

  `build_url/2` appends `query_id`, `user_id`, and `chat_id` as query
  parameters so the mini-app backend has everything it needs to answer the
  join request. Apps that prefer signing the payload with their own scheme
  can call `button/2` directly with a pre-built URL.

  ## Example

      iex> alias Raxol.Telegram.MiniApp
      iex> MiniApp.button("Verify", "https://verify.example.com")
      %{text: "Verify", web_app: %{url: "https://verify.example.com"}}

      iex> applicant = %{user_id: 99, chat_id: 42, query_id: "ABC"}
      iex> MiniApp.build_url("https://verify.example.com", applicant)
      "https://verify.example.com?chat_id=42&query_id=ABC&user_id=99"
  """

  @doc """
  Builds a `web_app` inline-keyboard button.

  Returns the button shape Telegram expects: a map with `:text` (label
  shown on the button) and `:web_app` (an object with the HTTPS URL).
  """
  @spec button(String.t(), String.t()) :: map()
  def button(label, url) when is_binary(label) and is_binary(url) do
    %{text: label, web_app: %{url: url}}
  end

  @doc """
  Builds a single-button `inline_keyboard` reply markup ready to pass as
  `reply_markup` on `sendMessage`.
  """
  @spec inline_keyboard(String.t(), String.t()) :: map()
  def inline_keyboard(label, url) when is_binary(label) and is_binary(url) do
    %{inline_keyboard: [[button(label, url)]]}
  end

  @doc """
  Appends applicant context as URL query parameters so the mini-app backend
  can answer the join request without re-fetching state.

  Adds `chat_id`, `user_id`, and (when present) `query_id`. Existing query
  parameters on `base_url` are preserved; the appended keys come after any
  existing ones.

  The applicant map is the one produced by
  `Raxol.Telegram.InputAdapter.translate_join_request/1`.
  """
  @spec build_url(String.t(), map()) :: String.t()
  def build_url(base_url, applicant) when is_binary(base_url) and is_map(applicant) do
    params =
      []
      |> maybe_param("chat_id", applicant[:chat_id] || applicant["chat_id"])
      |> maybe_param("user_id", applicant[:user_id] || applicant["user_id"])
      |> maybe_param("query_id", applicant[:query_id] || applicant["query_id"])
      |> Enum.sort()

    case params do
      [] -> base_url
      params -> append_query(base_url, params)
    end
  end

  defp maybe_param(acc, _key, nil), do: acc
  defp maybe_param(acc, _key, ""), do: acc
  defp maybe_param(acc, key, value), do: [{key, to_string(value)} | acc]

  defp append_query(url, params) do
    sep = if String.contains?(url, "?"), do: "&", else: "?"
    url <> sep <> URI.encode_query(params)
  end
end
