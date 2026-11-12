defmodule Raxol.System.Updater.Provenance.Policy do
  @moduledoc """
  Who must have signed a release: the GitHub Actions workflow of a
  repository, run for the release's tag on a GitHub-hosted runner.

  These are the checks `gh attestation verify --repo <repo>
  --signer-workflow <repo>/<workflow> --source-ref refs/tags/<tag>
  --cert-oidc-issuer https://token.actions.githubusercontent.com
  --deny-self-hosted-runners` makes, applied to the Fulcio certificate's
  identity (`Raxol.System.Updater.Provenance.Certificate.identity/1`).
  """

  alias Raxol.System.Updater.Provenance.Certificate

  @github "https://github.com"
  @actions_issuer "https://token.actions.githubusercontent.com"

  @type t :: %__MODULE__{
          repo: String.t(),
          signer_workflow: String.t(),
          source_ref: String.t(),
          issuer: String.t(),
          runner_environment: String.t()
        }

  @enforce_keys [:repo, :signer_workflow, :source_ref]
  defstruct [
    :repo,
    :signer_workflow,
    :source_ref,
    issuer: @actions_issuer,
    runner_environment: "github-hosted"
  ]

  @doc """
  The policy for release `tag` of `repo`, signed by `signer_workflow` (a
  path in that repository, e.g. `.github/workflows/release.yml`).
  """
  @spec for_release(String.t(), String.t(), String.t()) :: t()
  def for_release(repo, signer_workflow, tag),
    do: %__MODULE__{
      repo: repo,
      signer_workflow: signer_workflow,
      source_ref: "refs/tags/" <> tag
    }

  @doc """
  `:ok` when `identity` satisfies the policy, else the first claim that does
  not, with the certificate's value for it.
  """
  @spec check(Certificate.identity(), t()) ::
          :ok | {:error, {:identity_mismatch, atom(), term()}}
  def check(identity, %__MODULE__{} = policy) do
    Enum.find_value(expectations(policy), :ok, fn {claim, expected} ->
      actual = Map.get(identity, claim)
      if actual != expected, do: {:error, {:identity_mismatch, claim, actual}}
    end)
  end

  defp expectations(policy) do
    repo_uri = "#{@github}/#{policy.repo}"

    [
      issuer: policy.issuer,
      source_repository_uri: repo_uri,
      source_repository_ref: policy.source_ref,
      san: ["#{repo_uri}/#{policy.signer_workflow}@#{policy.source_ref}"],
      runner_environment: policy.runner_environment
    ]
  end
end
