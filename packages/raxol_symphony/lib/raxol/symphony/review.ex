defmodule Raxol.Symphony.Review do
  @moduledoc """
  Cross-vendor review policy: pick a reviewer that is a DIFFERENT vendor than the
  implementer, render the review prompt, and define the human-escalation reason.

  Ported from omnigent's Polly orchestrator, where review is always performed by a
  different vendor than the implementer and requires at least two available
  vendors -- otherwise the work escalates to a human. Here a "vendor" is a runner
  kind (`"raxol_agent"`, `"codex"`, ...); two distinct kinds are two distinct
  vendors.

  This module is pure: vendor availability is supplied by the caller as a
  predicate, so detection (a `command -v`-style probe) stays at the edge and the
  selection logic is trivially testable.
  """

  alias Raxol.Symphony.Review.Contract

  @escalation_reason :awaiting_human

  @doc """
  Pick a reviewer vendor distinct from `implementer`.

  Requires at least two distinct AVAILABLE candidate vendors and at least one
  available candidate that is not the implementer. Returns the first such
  reviewer, or `{:error, :insufficient_vendors}` when the cross-vendor invariant
  cannot be satisfied (the caller should escalate to a human).
  """
  @spec select_reviewer(String.t(), [String.t()], (String.t() -> boolean())) ::
          {:ok, String.t()} | {:error, :insufficient_vendors}
  def select_reviewer(implementer, candidates, available?)
      when is_binary(implementer) and is_list(candidates) and is_function(available?, 1) do
    available =
      candidates
      |> Enum.uniq()
      |> Enum.filter(available?)

    reviewers = Enum.reject(available, &(&1 == implementer))

    if length(available) >= 2 and reviewers != [] do
      {:ok, hd(reviewers)}
    else
      {:error, :insufficient_vendors}
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
