defmodule Raxol.Agent.Actions.Shell.Wait do
  @moduledoc false

  use Raxol.Agent.Action,
    name: "shell_wait",
    sensitive: true,
    description:
      "Block until a background job finishes, giving up after `timeout_ms` " <>
        "(default 30000, max 120000) and answering with its current state. " <>
        "`running: true` in the answer means the wait expired, not that the " <>
        "job failed -- wait again or poll. Waiting does not consume output; " <>
        "read it with `shell_poll`.",
    schema: [
      input: [
        job_id: [
          type: :string,
          required: true,
          description: "Handle returned by shell_start"
        ],
        timeout_ms: [
          type: :integer,
          description: "How long to block, in ms (default 30000, max 120000)"
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
        waited: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Actions.Shell
  alias Raxol.Agent.Shell.Jobs

  @impl true
  def run(%{job_id: id} = params, context) do
    with {:ok, owner} <- Shell.job_owner(context) do
      Jobs.await(id, owner, Map.get(params, :timeout_ms))
    end
  end
end
