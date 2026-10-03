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
        git = Keyword.get(opts, :git_runner, &Raxol.Symphony.WorkspaceGit.run/2)

        case git.(diff_args(Keyword.get(opts, :base_ref)), workspace) do
          {:ok, output} -> output
          {:error, _} -> ""
        end

      _ ->
        ""
    end
  end

  # The workspace is the implementer's, so its git config is agent-controlled:
  # no external diff, textconv or fsmonitor command runs, and git itself gets
  # the environment minus raxol's secrets (a repo's filter drivers still run).
  @diff_prefix ~w(-c core.fsmonitor=false -c diff.external= diff --no-ext-diff --no-textconv)

  defp diff_args(base), do: @diff_prefix ++ diff_range(base)

  defp diff_range(nil), do: ["HEAD"]
  defp diff_range(base) when is_binary(base), do: ["#{base}...HEAD"]
end
