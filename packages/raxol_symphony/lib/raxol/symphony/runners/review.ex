defmodule Raxol.Symphony.Runners.Review do
  @moduledoc """
  A `Raxol.Symphony.Runner` decorator that adds cross-vendor review.

  Activated with `runner.kind: "review"` plus a `review:` config block. It runs in
  two phases, riding the orchestrator's generic pause/resume primitive (no
  orchestrator changes needed):

  1. **Implement.** Resolve and run `review.implementer_kind` against the real
     workspace. If it succeeds and review is enabled, build a
     `Raxol.Symphony.Review.Contract` (diff of the implementer's changes), pick a
     different-vendor reviewer via `Raxol.Symphony.Review.select_reviewer/3`, and
     pause `:awaiting_review` carrying the Contract. If no different vendor is
     available, pause `:awaiting_human` instead. Any non-`:ok` implementer result
     passes through unchanged.

  2. **Review (on resume).** Resolve the reviewer vendor and run it against a
     FRESH isolated workspace with ONLY the Contract -- never the implementer's
     worktree. `:ok` from the reviewer means approved (the run completes);
     `{:error, reason}` means changes requested, surfaced as
     `{:error, {:changes_requested, reason}}` so the orchestrator's failure retry
     re-dispatches the implementer with the feedback. A human escalation
     (`:awaiting_human`) resumes with an operator decision in `:resume_value`.

  ## Test seams

  All edge effects are injectable via `opts` so the flow is unit-testable without
  real vendors or git:

  - `:review_runner_resolver` -- `(kind :: String.t -> {:ok, module} | {:error, term})`
  - `:review_vendor_availability` -- `(kind :: String.t -> boolean)`
  - `:review_git_runner` -- forwarded to `Contract.build/2`
  """

  @behaviour Raxol.Symphony.Runner

  alias Raxol.Symphony.{Config, Issue, Review, Runner}
  alias Raxol.Symphony.Review.Contract

  @impl true
  def run(%Issue{} = issue, %Config{} = config, opts) do
    if Keyword.has_key?(opts, :resume_value) do
      review_phase(issue, config, opts)
    else
      implement_phase(issue, config, opts)
    end
  end

  # -- Phase 1: implement -----------------------------------------------------

  defp implement_phase(issue, config, opts) do
    review = config.review
    implementer_kind = review.implementer_kind

    with {:ok, impl_mod} <- resolve(config, implementer_kind, opts),
         :ok <- impl_mod.run(issue, config, opts) do
      maybe_request_review(issue, config, opts, implementer_kind)
    else
      # Implementer paused, errored, returned a non-:ok result, or could not be
      # resolved -- pass it through. Review only triggers on a clean :ok.
      {:error, {:unsupported_runner_kind, _}} = err -> err
      other -> other
    end
  end

  defp maybe_request_review(issue, config, opts, implementer_kind) do
    review = config.review

    if review.enabled do
      contract = build_contract(issue, config, opts, implementer_kind)
      candidates = candidate_kinds(review, implementer_kind)

      case Review.select_reviewer(implementer_kind, candidates, availability_fun(opts)) do
        {:ok, reviewer_kind} ->
          {:pause, :awaiting_review,
           %{
             contract: contract,
             reviewer_kind: reviewer_kind,
             implementer_kind: implementer_kind
           }}

        {:error, :insufficient_vendors} ->
          {:pause, Review.escalation_reason(),
           %{
             contract: contract,
             implementer_kind: implementer_kind,
             reason: :insufficient_vendors
           }}
      end
    else
      :ok
    end
  end

  # -- Phase 2: review (on resume) --------------------------------------------

  defp review_phase(issue, config, opts) do
    token = Keyword.get(opts, :resume_token, %{})

    case Map.get(token, :reviewer_kind) do
      kind when is_binary(kind) -> dispatch_reviewer(issue, config, opts, token, kind)
      _ -> human_decision(opts)
    end
  end

  defp dispatch_reviewer(issue, config, opts, token, reviewer_kind) do
    contract = Map.fetch!(token, :contract)

    case resolve(config, reviewer_kind, opts) do
      {:ok, reviewer_mod} ->
        with_isolated_workspace(fn isolated ->
          reviewer_opts = [
            parent: Keyword.fetch!(opts, :parent),
            workspace_path: isolated,
            review_contract: contract,
            review_prompt: Review.review_prompt(contract)
          ]

          map_review_result(reviewer_mod.run(issue, config, reviewer_opts))
        end)

      {:error, reason} ->
        {:error, {:reviewer_unresolved, reason}}
    end
  end

  defp map_review_result(:ok), do: :ok
  defp map_review_result({:error, reason}), do: {:error, {:changes_requested, reason}}
  defp map_review_result({:pause, _, _} = pause), do: pause
  defp map_review_result(other), do: other

  # A human escalation resumes with the operator's decision in :resume_value.
  defp human_decision(opts) do
    case Keyword.get(opts, :resume_value) do
      :approved -> :ok
      :rejected -> {:error, {:changes_requested, :rejected_by_human}}
      other -> {:error, {:unexpected_human_decision, other}}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp build_contract(issue, config, opts, implementer_kind) do
    contract_opts =
      [
        workspace_path: Keyword.get(opts, :workspace_path),
        implementer_kind: implementer_kind,
        base_ref: config.review.base_ref,
        acceptance_criteria: config.review.acceptance || "",
        summary: ""
      ]
      |> maybe_put_git_runner(Keyword.get(opts, :review_git_runner))

    Contract.build(issue, contract_opts)
  end

  # Only forward :git_runner when set -- Contract.build/2 falls back to its own
  # default git invocation when the key is absent (but not when it is nil).
  defp maybe_put_git_runner(opts, nil), do: opts
  defp maybe_put_git_runner(opts, fun), do: Keyword.put(opts, :git_runner, fun)

  defp candidate_kinds(review, implementer_kind) do
    case review.candidate_kinds do
      list when is_list(list) and list != [] -> list
      _ -> Enum.uniq([implementer_kind, review.reviewer_kind])
    end
  end

  defp resolve(config, kind, opts) do
    resolver =
      Keyword.get(opts, :review_runner_resolver, fn k ->
        Runner.resolve(%{config | runner: Map.put(config.runner, :kind, k)})
      end)

    resolver.(kind)
  end

  defp availability_fun(opts) do
    Keyword.get(opts, :review_vendor_availability, &default_available?/1)
  end

  defp default_available?(kind)
       when kind in ["raxol_agent", "raxol_agent_session", "noop", "review"],
       do: true

  defp default_available?("codex"), do: not is_nil(System.find_executable("codex"))
  defp default_available?(_), do: false

  defp with_isolated_workspace(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony_review_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end
