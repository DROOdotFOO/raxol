defmodule Raxol.Agent.Actions.Shell.Kill do
  @moduledoc false

  use Raxol.Agent.Action,
    name: "shell_kill",
    sensitive: true,
    description:
      "Kill a background job and everything it spawned. Idempotent: a job " <>
        "that already finished reports its final state. `killed` says the " <>
        "kill signal landed and `confirmed_dead` that the process group's " <>
        "death was observed at the OS level -- neither is inferred from the " <>
        "job simply going away. Buffered output stays readable with " <>
        "`shell_poll` afterwards.",
    schema: [
      input: [
        job_id: [
          type: :string,
          required: true,
          description: "Handle returned by shell_start"
        ]
      ],
      output: [
        job_id: [type: :string],
        command: [type: :string],
        pty: [type: :boolean],
        status: [type: :string],
        running: [type: :boolean],
        exit_code: [type: :integer],
        os_pid: [type: :integer],
        runtime_ms: [type: :integer],
        output_bytes: [type: :integer],
        truncated: [type: :boolean],
        killed: [type: :boolean],
        confirmed_dead: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Actions.Shell
  alias Raxol.Agent.Shell.Jobs

  @impl true
  def run(%{job_id: id}, context) do
    with {:ok, owner} <- Shell.job_owner(context) do
      Jobs.kill(id, owner)
    end
  end
end
