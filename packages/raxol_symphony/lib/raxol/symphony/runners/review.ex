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
     pause `:awaiting_review` carrying the Contract. "Different vendor" means
     `Raxol.Symphony.Runner.vendor/1` differs, not that the kind string
     differs, so `raxol_agent` cannot review `raxol_agent_session`. If no
     second vendor is available, pause `:awaiting_human` carrying
     `{:insufficient_vendors, details}`, whose `:available_vendors` names what
     was on the machine. Any non-`:ok` implementer result passes through
     unchanged.

  2. **Review (on resume).** Resolve the reviewer vendor and run it against a
     FRESH isolated workspace with ONLY the Contract -- never the implementer's
     worktree. `:ok` from the reviewer means approved (the run completes);
     `{:error, reason}` means changes requested, surfaced as
     `{:error, {:changes_requested, reason}}` so the orchestrator's failure retry
     re-dispatches the implementer with the feedback. A human escalation
     (`:awaiting_human`) resumes with an operator decision in `:resume_value`.
     Both the implementer and the reviewer can pause on their own behalf (a
     Codex approval request, say). Those pauses are forwarded wrapped in a
     `:review_delegate` envelope naming which phase minted them, so the resume
     goes back to the agent that asked and nowhere else.

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

  # Every pause that leaves this module is routed back by the shape of its
  # own token, never by a fallthrough: an operator's decision is consent
  # about one agent's proposed action, and delivering it to a different agent
  # in a different workspace is worse than refusing it. A token we do not
  # recognise is reported rather than guessed at, since guessing means
  # running the implementer -- write access to the real worktree -- on a
  # decision that was never about it.
  @impl true
  def run(%Issue{} = issue, %Config{} = config, opts) do
    opts |> Keyword.get(:resume_token) |> route(issue, config, opts)
  end

  defp route(nil, issue, config, opts), do: implement_phase(issue, config, opts)

  defp route(%{review_delegate: :implementer, inner: inner}, issue, config, opts),
    do: implement_phase(issue, config, Keyword.put(opts, :resume_token, inner))

  defp route(%{review_delegate: :reviewer, inner: inner} = token, issue, config, opts) do
    resume = [resume_token: inner, resume_value: Keyword.get(opts, :resume_value)]
    dispatch_reviewer(issue, config, opts, token, Map.fetch!(token, :reviewer_kind), resume)
  end

  defp route(%{contract: _}, issue, config, opts), do: review_phase(issue, config, opts)

  defp route(other, _issue, _config, _opts), do: {:error, {:unroutable_resume_token, other}}

  # -- Phase 1: implement -----------------------------------------------------

  defp implement_phase(issue, config, opts) do
    review = config.review
    implementer_kind = review.implementer_kind

    with {:ok, impl_mod} <- resolve(config, implementer_kind, opts),
         :ok <- impl_mod.run(issue, config, opts) do
      maybe_request_review(issue, config, opts, implementer_kind)
    else
      # Implementer errored, returned a non-:ok result, or could not be
      # resolved -- pass it through. Review only triggers on a clean :ok.
      {:error, {:unsupported_runner_kind, _}} = err ->
        err

      # A pause the implementer raised for itself. Envelope it so the resume
      # comes back here labelled, instead of arriving as a bare token the
      # review phase would mistake for one of its own.
      {:pause, reason, token} ->
        {:pause, reason, %{review_delegate: :implementer, inner: token}}

      other ->
        other
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

        {:error, {:insufficient_vendors, details}} ->
          {:pause, Review.escalation_reason(),
           %{
             contract: contract,
             implementer_kind: implementer_kind,
             reason: {:insufficient_vendors, details}
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
      kind when is_binary(kind) -> dispatch_reviewer(issue, config, opts, token, kind, [])
      _ -> human_decision(opts)
    end
  end

  # `resume` is the reviewer's own parked pause coming back to it, empty on a
  # first dispatch. The workspace is freshly isolated either way -- the old one
  # was deleted when the reviewer paused -- so the reviewer restarts from the
  # Contract, which is all it ever had.
  defp dispatch_reviewer(issue, config, opts, token, reviewer_kind, resume) do
    contract = Map.fetch!(token, :contract)

    case resolve(config, reviewer_kind, opts) do
      {:ok, reviewer_mod} ->
        with_isolated_workspace(fn isolated ->
          reviewer_opts =
            [
              parent: Keyword.fetch!(opts, :parent),
              workspace_path: isolated,
              review_contract: contract,
              review_prompt: Review.review_prompt(contract)
            ] ++ resume

          issue
          |> reviewer_mod.run(config, reviewer_opts)
          |> map_review_result(contract, reviewer_kind)
        end)

      {:error, reason} ->
        {:error, {:reviewer_unresolved, reason}}
    end
  end

  defp map_review_result(:ok, _contract, _kind), do: :ok

  defp map_review_result({:error, reason}, _contract, _kind),
    do: {:error, {:changes_requested, reason}}

  # Carry the Contract and the vendor with a forwarded reviewer pause: the
  # resume has to reach the same reviewer, and nothing else in the token says
  # which one asked.
  defp map_review_result({:pause, reason, token}, contract, kind) do
    {:pause, reason,
     %{review_delegate: :reviewer, inner: token, contract: contract, reviewer_kind: kind}}
  end

  defp map_review_result(other, _contract, _kind), do: other

  # A human escalation resumes with the operator's decision in :resume_value.
  # The MCP surface passes the raw JSON value through, so the same decision
  # arrives as a string there and as an atom from the TUI.
  defp human_decision(opts) do
    case Keyword.get(opts, :resume_value) do
      decision when decision in [:approved, "approved"] ->
        :ok

      decision when decision in [:rejected, "rejected"] ->
        {:error, {:changes_requested, :rejected_by_human}}

      other ->
        {:error, {:unexpected_human_decision, other}}
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

  # ADR-0034 Gap 5: availability is probed per VENDOR, not per kind, and the
  # unconditional `true` that used to cover four of the five kinds is gone.
  # `:raxol` runs in this VM, so there is nothing to probe; `:codex` is an
  # external binary. A kind with no vendor (`"review"`, `"noop"`) is not a
  # review participant and reports unavailable rather than pretending.
  defp default_available?(kind) do
    case Runner.vendor(kind) do
      :raxol -> true
      :codex -> not is_nil(System.find_executable("codex"))
      _ -> false
    end
  end

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
