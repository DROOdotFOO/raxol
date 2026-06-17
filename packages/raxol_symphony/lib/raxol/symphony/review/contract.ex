defmodule Raxol.Symphony.Review.Contract do
  @moduledoc """
  The artifact a reviewer is given for a cross-vendor review.

  A Contract is the ONLY thing a reviewer sees: the issue under review, a unified
  diff of the implementer's changes, a short summary, and the acceptance criteria.
  It deliberately carries NO reference to the implementer's workspace, so a
  reviewer running a different vendor cannot reach into the worktree and have its
  stray edits leak into the deliverable (the cross-vendor isolation invariant from
  omnigent's Polly orchestrator).

  Build one with `build/2`; the diff is collected with an injectable git runner so
  tests stay deterministic and the workspace never leaks past this module.
  """

  alias Raxol.Symphony.Issue

  @enforce_keys [:issue_identifier]
  defstruct [
    :issue_identifier,
    :issue_title,
    :implementer_kind,
    :base_ref,
    diff: "",
    summary: "",
    acceptance_criteria: ""
  ]

  @type t :: %__MODULE__{
          issue_identifier: String.t(),
          issue_title: String.t() | nil,
          implementer_kind: String.t() | nil,
          base_ref: String.t() | nil,
          diff: String.t(),
          summary: String.t(),
          acceptance_criteria: String.t()
        }

  @doc """
  Build a Contract for `issue` from the implementer's workspace.

  Options:

  - `:workspace_path` -- implementer worktree to diff (used only here; never
    placed on the Contract).
  - `:diff` -- explicit diff string; when given, no git is run.
  - `:git_runner` -- `(args :: [binary], cwd :: Path.t -> {:ok, binary} | {:error, term})`
    for tests; defaults to a real `git` invocation. Diff is best-effort: a git
    failure yields an empty diff rather than failing the build.
  - `:base_ref` -- base to diff against (`git diff <base>...HEAD`); when `nil`,
    diffs the working tree against `HEAD`.
  - `:implementer_kind`, `:summary`, `:acceptance_criteria` -- metadata.
  """
  @spec build(Issue.t(), keyword()) :: t()
  def build(%Issue{} = issue, opts) do
    %__MODULE__{
      issue_identifier: issue.identifier,
      issue_title: Map.get(issue, :title),
      implementer_kind: Keyword.get(opts, :implementer_kind),
      base_ref: Keyword.get(opts, :base_ref),
      diff: resolve_diff(opts),
      summary: Keyword.get(opts, :summary, ""),
      acceptance_criteria: Keyword.get(opts, :acceptance_criteria, "")
    }
  end

  defp resolve_diff(opts) do
    case Keyword.get(opts, :diff) do
      diff when is_binary(diff) -> diff
      _ -> diff_from_git(opts)
    end
  end

  defp diff_from_git(opts) do
    case Keyword.get(opts, :workspace_path) do
      workspace when is_binary(workspace) ->
        git = Keyword.get(opts, :git_runner, &default_git/2)

        case git.(diff_args(Keyword.get(opts, :base_ref)), workspace) do
          {:ok, output} -> output
          {:error, _} -> ""
        end

      _ ->
        ""
    end
  end

  defp diff_args(nil), do: ["diff", "HEAD"]
  defp diff_args(base) when is_binary(base), do: ["diff", "#{base}...HEAD"]

  defp default_git(args, cwd) do
    cond do
      not File.dir?(cwd) -> {:error, :workspace_missing}
      is_nil(System.find_executable("git")) -> {:error, :git_not_found}
      true -> run_git(args, cwd)
    end
  end

  defp run_git(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:exception, e}}
  end
end
