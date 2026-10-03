defmodule Raxol.Symphony.WorkspaceGit do
  @moduledoc false
  # Runs git in a workspace that belongs to an agent or a hook. The workspace's
  # git config is theirs, so git gets the environment minus raxol's secrets.

  @spec run([String.t()], Path.t()) :: {:ok, String.t()} | {:error, term()}
  def run(args, cwd) do
    cond do
      not File.dir?(cwd) -> {:error, :workspace_missing}
      is_nil(System.find_executable("git")) -> {:error, :git_not_found}
      true -> cmd(args, cwd)
    end
  end

  defp cmd(args, cwd) do
    case System.cmd("git", args,
           cd: cwd,
           stderr_to_stdout: true,
           env: Raxol.Core.ChildEnv.cmd_env()
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:exception, e}}
  end
end
