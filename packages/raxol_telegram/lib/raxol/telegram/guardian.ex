defmodule Raxol.Telegram.Guardian do
  @moduledoc """
  Behaviour for screening Telegram `chat_join_request` updates.

  Design record: `docs/adr/0014-telegram-ai-guardian.md` in the raxol repo.
  Designed for AI moderation: a coding agent (or simple predicate) decides
  whether an applicant should be admitted, declined, or pushed through a
  consumer-hosted mini-app for verification.

  ## Implementing a Guardian

  Define a module with `@behaviour Raxol.Telegram.Guardian` and implement
  `screen/1`. The return value is one of:

    * `{:approve, reason_or_nil}`: admit the applicant. Reason is opaque
      string used for telemetry and logging.
    * `{:decline, reason_or_nil}`: reject the applicant.
    * `{:ask_mini_app, url, button_text}`: send the applicant a private
      message with a button that launches the given URL. The mini-app
      backend is responsible for the final approve / decline call.

  ## Wiring up

  Pass the module via `opts` to `Raxol.Telegram.Bot.handle_update/2`, or
  set it in app env:

      config :raxol_telegram, guardian: MyApp.SpamFilter

  Defaults to `Raxol.Telegram.Guardian.Static` (approves everyone when
  unconfigured).

  ## Bot API path selection

  When the applicant carries a `query_id` (Bot API 10.1+), `apply_decision/2`
  uses `answerChatJoinRequestQuery` for approve / decline. Without
  `query_id`, it falls back to the pre-10.0 pair (`approveChatJoinRequest`
  and `declineChatJoinRequest`).

  Both paths call the Bot API via `Raxol.Telegram.HTTP` (raw `Req`, optional
  dep). Telegex 1.8 predates Bot API 10.1 and does not expose
  `answerChatJoinRequestQuery`.

  ## Telemetry

    * `[:raxol_telegram, :guardian, :received]`: before `screen/1` runs
    * `[:raxol_telegram, :guardian, :approved]`: after a successful approve
    * `[:raxol_telegram, :guardian, :declined]`: after a successful decline
    * `[:raxol_telegram, :guardian, :asked]`: after a mini-app message goes out
    * `[:raxol_telegram, :guardian, :error]`: any Bot API failure

  All carry `chat_id` and `user_id`; terminal events also carry `reason`
  (or `url` for `:asked`) and `source: :bot | :mcp`.
  """

  alias Raxol.Telegram.{HTTP, MiniApp}

  @type applicant :: %{
          required(:user_id) => integer(),
          required(:chat_id) => integer(),
          optional(:query_id) => String.t() | nil,
          optional(:username) => String.t() | nil,
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil,
          optional(:bio) => String.t() | nil,
          optional(:invite_link) => String.t() | nil
        }

  @type decision ::
          {:approve, String.t() | nil}
          | {:decline, String.t() | nil}
          | {:ask_mini_app, url :: String.t(), button_text :: String.t()}

  @callback screen(applicant()) :: decision()

  @doc """
  Invokes the configured Guardian module's `screen/1` for an applicant.

  Pass `module` explicitly, or omit to read from `:raxol_telegram` app env
  (key `:guardian`, default `Raxol.Telegram.Guardian.Static`).
  """
  @spec decide(applicant(), module() | nil) :: decision()
  def decide(applicant, module \\ nil)

  def decide(applicant, nil) do
    module = Application.get_env(:raxol_telegram, :guardian, Raxol.Telegram.Guardian.Static)
    decide(applicant, module)
  end

  def decide(applicant, module) when is_atom(module) do
    module.screen(applicant)
  end

  @doc """
  Applies a `screen/1` decision to the Bot API.

  ## Options

    * `:bot_token`, `:api_base`, `:timeout`, `:post_fn`: forwarded to
      `Raxol.Telegram.HTTP.post/3`
    * `:source`: `:bot | :mcp` metadata for telemetry; default `:bot`
    * `:mini_app_url_builder`: 2-arity `(base_url, applicant) -> url`
      override for the `:ask_mini_app` path; default
      `&Raxol.Telegram.MiniApp.build_url/2`
  """
  @spec apply_decision(applicant(), decision(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def apply_decision(applicant, decision, opts \\ [])

  def apply_decision(applicant, {:approve, reason}, opts) do
    result = call_approve(applicant, opts)
    emit_terminal(:approved, applicant, reason, opts, result)
    result
  end

  def apply_decision(applicant, {:decline, reason}, opts) do
    result = call_decline(applicant, opts)
    emit_terminal(:declined, applicant, reason, opts, result)
    result
  end

  def apply_decision(applicant, {:ask_mini_app, url, button_text}, opts) do
    builder = Keyword.get(opts, :mini_app_url_builder, &MiniApp.build_url/2)
    full_url = builder.(url, applicant)

    body = %{
      chat_id: applicant.user_id,
      text: button_text,
      reply_markup: MiniApp.inline_keyboard(button_text, full_url)
    }

    result = HTTP.post("sendMessage", body, opts)
    emit_terminal(:asked, applicant, %{url: full_url}, opts, result)
    result
  end

  # --- Private ---

  defp call_approve(%{query_id: q} = applicant, opts) when is_binary(q) and q != "" do
    HTTP.post("answerChatJoinRequestQuery", %{query_id: q, action: "approve"}, opts)
    |> case do
      {:ok, _} = ok -> ok
      {:error, _} = err -> fallback_approve(applicant, opts, err)
    end
  end

  defp call_approve(applicant, opts) do
    HTTP.post(
      "approveChatJoinRequest",
      %{chat_id: applicant.chat_id, user_id: applicant.user_id},
      opts
    )
  end

  defp call_decline(%{query_id: q} = applicant, opts) when is_binary(q) and q != "" do
    HTTP.post("answerChatJoinRequestQuery", %{query_id: q, action: "decline"}, opts)
    |> case do
      {:ok, _} = ok -> ok
      {:error, _} = err -> fallback_decline(applicant, opts, err)
    end
  end

  defp call_decline(applicant, opts) do
    HTTP.post(
      "declineChatJoinRequest",
      %{chat_id: applicant.chat_id, user_id: applicant.user_id},
      opts
    )
  end

  # If answerChatJoinRequestQuery fails because the Bot API rejects the
  # method (e.g. older API server), fall back silently to the pre-10.0 pair.
  # Other errors (auth, network) propagate.
  defp fallback_approve(applicant, opts, {:error, {:bot_api_error, _, _}}) do
    HTTP.post(
      "approveChatJoinRequest",
      %{chat_id: applicant.chat_id, user_id: applicant.user_id},
      opts
    )
  end

  defp fallback_approve(_applicant, _opts, err), do: err

  defp fallback_decline(applicant, opts, {:error, {:bot_api_error, _, _}}) do
    HTTP.post(
      "declineChatJoinRequest",
      %{chat_id: applicant.chat_id, user_id: applicant.user_id},
      opts
    )
  end

  defp fallback_decline(_applicant, _opts, err), do: err

  defp emit_terminal(event, applicant, reason_or_meta, opts, result) do
    metadata =
      %{
        chat_id: applicant.chat_id,
        user_id: applicant.user_id,
        source: Keyword.get(opts, :source, :bot)
      }
      |> Map.merge(reason_metadata(reason_or_meta))
      |> Map.merge(result_metadata(result))

    final_event = if match?({:error, _}, result), do: :error, else: event

    :telemetry.execute(
      [:raxol_telegram, :guardian, final_event],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp reason_metadata(%{url: url}), do: %{url: url}
  defp reason_metadata(nil), do: %{reason: nil}
  defp reason_metadata(reason) when is_binary(reason), do: %{reason: reason}
  defp reason_metadata(_), do: %{}

  defp result_metadata({:ok, _}), do: %{}
  defp result_metadata({:error, reason}), do: %{error_reason: reason}
end
