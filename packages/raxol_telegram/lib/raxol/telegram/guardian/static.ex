defmodule Raxol.Telegram.Guardian.Static do
  @moduledoc """
  Default `Raxol.Telegram.Guardian` implementation.

  Without configuration, approves every applicant (least-surprising default
  for an unconfigured bot). With a predicate function configured in app env,
  delegates to it for the decision.

  ## Configuration

      config :raxol_telegram,
        guardian_predicate: fn applicant ->
          cond do
            blocked_user?(applicant.user_id) -> {:decline, "user blocked"}
            applicant.bio == nil -> {:ask_mini_app, "https://verify.example.com", "Verify"}
            true -> {:approve, nil}
          end
        end

  The predicate receives the applicant map produced by
  `Raxol.Telegram.InputAdapter.translate_join_request/1` and must return a
  `Raxol.Telegram.Guardian.decision/0` tuple.

  Use this module for tests, simple deployments, and as a reference impl
  for richer Guardians (e.g. an LLM-backed screener built on
  `Raxol.Agent.Stream`).
  """

  @behaviour Raxol.Telegram.Guardian

  @impl true
  def screen(applicant) do
    case Application.get_env(:raxol_telegram, :guardian_predicate) do
      nil -> {:approve, nil}
      fun when is_function(fun, 1) -> fun.(applicant)
      _other -> {:approve, nil}
    end
  end
end
