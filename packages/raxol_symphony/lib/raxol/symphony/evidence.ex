defmodule Raxol.Symphony.Evidence do
  @moduledoc """
  Per-run evidence aggregator.

  Collects everything an engineer needs to manage outcomes for a Symphony
  run -- CI status, recent PR comments, code-complexity metrics, and any
  asciinema replays -- into a single struct.

  Each backend is independent and tolerates failure: a missing
  `$GITHUB_TOKEN` doesn't void the complexity report, and missing `cloc`
  doesn't void the GitHub status. Backend errors land in the `:errors`
  map so callers can surface them without having to chase exceptions.

  ## Subject

  A "subject" identifies what to collect evidence about. The minimum is a
  workspace path; richer fields enable richer evidence:

      %{
        workspace: "/path/to/workspace",
        repo: "owner/repo",        # required for GitHub evidence
        ref: "branch-or-sha",      # used for CI lookup
        issue_number: 42           # used for PR-comment lookup
      }

  Use `Raxol.Symphony.Evidence.Subject.from_workspace/2` to infer fields
  from an existing workspace's git config.

  ## Default backends

  - `Raxol.Symphony.Evidence.GitHub`     -- CI status + PR comments
  - `Raxol.Symphony.Evidence.Complexity` -- `cloc` (or SLOC fallback)
  - `Raxol.Symphony.Evidence.Recording`  -- asciicast files

  Override via `:backends` opt for testing.
  """

  alias Raxol.Symphony.Config

  defstruct [
    :workspace,
    :repo,
    :ref,
    :issue_number,
    ci: nil,
    pr_comments: [],
    complexity: nil,
    recordings: [],
    errors: %{}
  ]

  @type t :: %__MODULE__{
          workspace: Path.t() | nil,
          repo: binary() | nil,
          ref: binary() | nil,
          issue_number: non_neg_integer() | nil,
          ci: map() | nil,
          pr_comments: list(map()),
          complexity: map() | nil,
          recordings: list(map()),
          errors: %{optional(atom()) => term()}
        }

  @type subject :: %{
          required(:workspace) => Path.t(),
          optional(:repo) => binary(),
          optional(:ref) => binary(),
          optional(:issue_number) => non_neg_integer()
        }

  @type backend_spec :: {module(), keyword()}

  @default_backends [
    {Raxol.Symphony.Evidence.GitHub, []},
    {Raxol.Symphony.Evidence.Complexity, []},
    {Raxol.Symphony.Evidence.Recording, []}
  ]

  @doc """
  Collects evidence for `subject` against `config`.

  `opts`:

  - `:backends` -- list of `{module, opts}` overrides. Defaults to all
    three backends.
  """
  @spec collect(Config.t(), subject(), keyword()) :: t()
  def collect(%Config{} = config, %{workspace: _} = subject, opts \\ []) do
    backends = Keyword.get(opts, :backends, @default_backends)

    initial = %__MODULE__{
      workspace: Map.get(subject, :workspace),
      repo: Map.get(subject, :repo),
      ref: Map.get(subject, :ref),
      issue_number: Map.get(subject, :issue_number)
    }

    Enum.reduce(backends, initial, fn {module, mod_opts}, acc ->
      run_backend(module, acc, config, mod_opts)
    end)
  end

  @doc """
  Encodes the struct as a plain map, suitable for JSON serialization
  (MCP tool, JSON API).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = e) do
    %{
      workspace: e.workspace,
      repo: e.repo,
      ref: e.ref,
      issue_number: e.issue_number,
      ci: e.ci,
      pr_comments: e.pr_comments,
      complexity: e.complexity,
      recordings: e.recordings,
      errors: Map.new(e.errors, fn {k, v} -> {k, inspect(v)} end)
    }
  end

  defp run_backend(module, %__MODULE__{} = acc, %Config{} = config, mod_opts) do
    module.collect(acc, config, mod_opts)
  rescue
    e ->
      %__MODULE__{acc | errors: Map.put(acc.errors, backend_key(module), {:exception, e})}
  end

  defp backend_key(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  @doc false
  @spec put_error(t(), atom(), term()) :: t()
  def put_error(%__MODULE__{} = e, key, reason) when is_atom(key),
    do: %__MODULE__{e | errors: Map.put(e.errors, key, reason)}
end
