defmodule Raxol.Symphony.Evidence.Subject do
  @moduledoc """
  Builds an `Evidence` subject from a workspace path plus tracker-aware
  defaults.

  Inferred fields:

  - `:repo`         -- parsed from `git config --get remote.origin.url`
  - `:ref`          -- `git rev-parse --abbrev-ref HEAD`
  - `:issue_number` -- numeric `issue.identifier` when tracker is `github`
  """

  alias Raxol.Symphony.{Config, Issue}

  @doc """
  Builds a subject map from a workspace path and (optional) issue.

  `opts` accepts `:git_runner` for tests (a `(args :: [binary], cwd :: Path.t)`
  function that returns `{:ok, output}` or `{:error, term}`).
  """
  @spec from_workspace(Path.t(), keyword()) :: Raxol.Symphony.Evidence.subject()
  def from_workspace(workspace, opts \\ []) when is_binary(workspace) do
    git = Keyword.get(opts, :git_runner, &default_git/2)

    base = %{workspace: workspace}

    base
    |> maybe_put(:repo, parse_repo(git, workspace))
    |> maybe_put(:ref, parse_ref(git, workspace))
    |> maybe_put(:issue_number, Keyword.get(opts, :issue_number))
  end

  @doc """
  Augments a subject with issue-derived fields when `config.tracker.kind`
  exposes a numeric issue identifier (currently only `github`).
  """
  @spec augment(Raxol.Symphony.Evidence.subject(), Config.t(), Issue.t()) ::
          Raxol.Symphony.Evidence.subject()
  def augment(subject, %Config{tracker: %{kind: "github"}}, %Issue{identifier: identifier}) do
    case Integer.parse(identifier) do
      {n, ""} when n > 0 -> Map.put(subject, :issue_number, n)
      _ -> subject
    end
  end

  def augment(subject, _config, _issue), do: subject

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp parse_repo(git, workspace) do
    case git.(["config", "--get", "remote.origin.url"], workspace) do
      {:ok, url} -> repo_from_url(String.trim(url))
      {:error, _} -> nil
    end
  end

  defp parse_ref(git, workspace) do
    case git.(["rev-parse", "--abbrev-ref", "HEAD"], workspace) do
      {:ok, ref} ->
        case String.trim(ref) do
          "" -> nil
          "HEAD" -> nil
          ref -> ref
        end

      {:error, _} ->
        nil
    end
  end

  defp repo_from_url(""), do: nil

  defp repo_from_url(url) do
    case Regex.run(~r{github\.com[:/]([^/]+)/([^/]+?)(\.git)?$}, url) do
      [_, owner, name | _] -> "#{owner}/#{name}"
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_git(args, cwd) do
    cond do
      not File.dir?(cwd) ->
        {:error, :workspace_missing}

      is_nil(System.find_executable("git")) ->
        {:error, :git_not_found}

      true ->
        run_git(args, cwd)
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
