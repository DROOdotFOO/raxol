defmodule Raxol.Agent.Actions.Shell.Poll do
  @moduledoc false

  use Raxol.Agent.Action,
    name: "shell_poll",
    sensitive: true,
    description:
      "Read a background job's output from `cursor` onward and report its " <>
        "state. Pass the `cursor` returned by the previous poll to get only " <>
        "the new bytes; pass 0 (the default) to re-read from the start. " <>
        "`output_bytes` is what the command has actually written, so it " <>
        "exceeds the bytes you can read once `truncated` is true.",
    schema: [
      input: [
        job_id: [
          type: :string,
          required: true,
          description: "Handle returned by shell_start"
        ],
        cursor: [
          type: :integer,
          description: "Byte offset to read from (default 0)"
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
        output: [type: :string],
        cursor: [type: :integer],
        output_bytes: [type: :integer],
        truncated: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Actions.Shell
  alias Raxol.Agent.Shell.Jobs

  @impl true
  def run(%{job_id: id} = params, context) do
    with {:ok, owner} <- Shell.job_owner(context) do
      Jobs.poll(id, owner, max(Map.get(params, :cursor) || 0, 0))
    end
  end
end
