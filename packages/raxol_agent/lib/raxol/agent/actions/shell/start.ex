defmodule Raxol.Agent.Actions.Shell.Start do
  @moduledoc false

  use Raxol.Agent.Action,
    name: "shell_start",
    sensitive: true,
    description:
      "Start a shell command in the background and return a job handle " <>
        "immediately. Use this for anything that may run longer than a " <>
        "turn (builds, test suites, servers); use `bash` for short " <>
        "commands. Read its output with `shell_poll` (pass the `cursor` " <>
        "from the previous poll to get only the new bytes), block for a " <>
        "bounded time with `shell_wait`, stop it with `shell_kill`, and " <>
        "list live jobs with `shell_jobs`. Set `pty: true` for a command " <>
        "that only behaves correctly on a terminal (progress bars, colour, " <>
        "prompts); its output then carries CR-LF line endings and any " <>
        "escape sequences the command emits. A job is killed, with its " <>
        "whole process tree, when its wall-clock cap expires.",
    schema: [
      input: [
        command: [
          type: :string,
          required: true,
          description: "Shell command line to execute"
        ],
        cd: [
          type: :string,
          description: "Working directory for the command, relative to cwd"
        ],
        pty: [
          type: :boolean,
          description: "Attach a pseudo-terminal (default false)"
        ],
        timeout_ms: [
          type: :integer,
          description: "Wall-clock cap in ms (default 600000, max 3600000)"
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
        truncated: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Actions.Shell
  alias Raxol.Agent.Shell.Jobs

  @impl true
  def run(%{command: command} = params, context) do
    # The same gate the foreground shell passes: the jail refusal plus the
    # configured `Sandbox.Shell` policy. Backgrounding does not weaken what a
    # command may do, so it must not weaken what decides whether it runs.
    with :ok <- Code.shell_allow(context, command),
         {:ok, owner} <- Shell.job_owner(context),
         {:ok, cwd} <- resolve_cd(Map.get(params, :cd), context) do
      Jobs.start(command,
        owner: owner,
        cwd: cwd,
        pty: Map.get(params, :pty, false),
        timeout_ms: Map.get(params, :timeout_ms)
      )
    end
  end

  defp resolve_cd(nil, context), do: {:ok, Fs.working_dir(context)}
  defp resolve_cd(rel, context), do: Fs.resolve(rel, context)
end
