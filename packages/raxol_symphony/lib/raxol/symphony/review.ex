defmodule Raxol.Symphony.Review do
  @moduledoc """
  Cross-vendor review policy: pick a reviewer that is a DIFFERENT vendor than the
  implementer, render the review prompt, and define the human-escalation reason.

  Ported from omnigent's Polly orchestrator, where review is always performed by a
  different vendor than the implementer and requires at least two available
  vendors -- otherwise the work escalates to a human.

  A "vendor" is NOT a runner kind. Vendor identity comes from
  `Raxol.Symphony.Runner.vendor/1`, because `"raxol_agent"` and
  `"raxol_agent_session"` are two kinds with one vendor (`:raxol`): pairing them
  satisfies "two distinct kinds" while leaving the adversarial premise of review
  unmet, which is exactly what ADR-0034 Gap 5 measured. Kinds whose vendor is
  `nil` (`"review"`, `"noop"`) are not review-capable at all and are excluded
  from candidacy: an inert reviewer would approve every diff.

  This module is pure: vendor availability is supplied by the caller as a
  predicate, so detection (a `command -v`-style probe) stays at the edge and the
  selection logic is trivially testable.
  """

  alias Raxol.Symphony.{Runner, Review.Contract}

  @escalation_reason :awaiting_human

  @typedoc """
  Why the cross-vendor invariant could not be satisfied. Names the vendors that
  ARE present so an operator reading the escalation knows which second vendor is
  missing rather than only that one is.
  """
  @type insufficiency :: %{
          implementer_kind: String.t(),
          implementer_vendor: Runner.vendor(),
          available_kinds: [String.t()],
          available_vendors: [Runner.vendor()]
        }

  @doc """
  Pick a reviewer whose VENDOR differs from the implementer's.

  Candidates whose vendor is `nil` are rejected outright. Of the rest, the
  first available candidate from a vendor other than the implementer's is the
  reviewer. Returns `{:error, {:insufficient_vendors, insufficiency()}}` when
  there is none (the caller should escalate to a human).
  """
  @spec select_reviewer(String.t(), [String.t()], (String.t() -> boolean())) ::
          {:ok, String.t()} | {:error, {:insufficient_vendors, insufficiency()}}
  def select_reviewer(implementer, candidates, available?)
      when is_binary(implementer) and is_list(candidates) and is_function(available?, 1) do
    available =
      candidates
      |> Enum.uniq()
      |> Enum.filter(&(Runner.vendor(&1) != nil))
      |> Enum.filter(available?)

    implementer_vendor = Runner.vendor(implementer)

    # One condition, because the filter is by vendor: a non-empty `reviewers`
    # already proves a second vendor is available. Requiring two distinct
    # vendors among the candidates on top of that escalated a valid pair
    # whenever `candidate_kinds` omitted the implementer's own kind.
    case Enum.reject(available, &(Runner.vendor(&1) == implementer_vendor)) do
      [reviewer | _] ->
        {:ok, reviewer}

      [] ->
        {:error,
         {:insufficient_vendors,
          %{
            implementer_kind: implementer,
            implementer_vendor: implementer_vendor,
            available_kinds: available,
            available_vendors: available |> Enum.map(&Runner.vendor/1) |> Enum.uniq()
          }}}
    end
  end

  @doc "The pause reason used when the cross-vendor invariant cannot be met."
  @spec escalation_reason() :: :awaiting_human
  def escalation_reason, do: @escalation_reason

  @doc """
  Render a review prompt from a Contract.

  The prompt contains only the issue, diff, summary, and acceptance criteria --
  never a workspace path -- preserving the Contract-only isolation invariant.
  """
  @spec review_prompt(Contract.t()) :: String.t()
  def review_prompt(%Contract{} = c) do
    """
    You are reviewing changes implemented by a different agent
    (#{c.implementer_kind || "unknown"}). You have ONLY the diff and the
    acceptance contract below -- you do not have access to the implementer's
    workspace. Judge correctness, tests, security, and whether the acceptance
    criteria are met. Approve only if the change is correct and complete.

    ## Issue
    #{c.issue_identifier}#{title_suffix(c.issue_title)}

    ## Acceptance criteria
    #{blank_to_placeholder(c.acceptance_criteria, "(none provided)")}

    ## Implementer summary
    #{blank_to_placeholder(c.summary, "(none provided)")}

    ## Diff
    #{diff_block(c.diff)}
    """
  end

  defp title_suffix(nil), do: ""
  defp title_suffix(""), do: ""
  defp title_suffix(title), do: " -- #{title}"

  defp blank_to_placeholder(value, placeholder) do
    case String.trim(to_string(value)) do
      "" -> placeholder
      trimmed -> trimmed
    end
  end

  defp diff_block(diff) do
    case String.trim(to_string(diff)) do
      "" -> "(no diff captured)"
      _ -> "```diff\n#{diff}\n```"
    end
  end
end
