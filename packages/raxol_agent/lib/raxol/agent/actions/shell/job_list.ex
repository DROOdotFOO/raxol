defmodule Raxol.Agent.Actions.Shell.JobList do
  @moduledoc false

  use Raxol.Agent.Action,
    name: "shell_jobs",
    sensitive: true,
    description:
      "List the background jobs started in this working directory, oldest " <>
        "first, with their status, exit code and buffered byte count. Use " <>
        "it to recover a job handle from an earlier turn, or to see what is " <>
        "still running before starting more work.",
    schema: [
      input: [],
      output: [
        count: [type: :integer],
        running: [type: :integer],
        jobs: [type: :list]
      ]
    ]

  alias Raxol.Agent.Actions.Shell
  alias Raxol.Agent.Shell.Jobs

  @impl true
  def run(_params, context) do
    with {:ok, owner} <- Shell.job_owner(context) do
      jobs = Jobs.list(owner)

      {:ok,
       %{
         count: length(jobs),
         running: Enum.count(jobs, & &1.running),
         jobs: jobs
       }}
    end
  end
end
