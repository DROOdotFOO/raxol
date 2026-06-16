# Agent Team Example
#
# A coordinator dispatches files to worker agents for analysis.
# Workers report back via inter-agent messaging.
#
# What you'll learn:
#   - Agent.Team is an OTP Supervisor for agent groups (crash isolation)
#   - Directive.send_agent(target, msg) routes messages via Registry
#   - Coordinator/worker pattern: coordinator assigns, workers report back
#   - Each agent is a separate process with its own TEA loop
#
# Usage:
#   mix run examples/agents/agent_team.exs

Logger.configure(level: :warning)

defmodule FileAnalyzer do
  @moduledoc "Worker agent that analyzes files and reports back to coordinator."
  use Raxol.Agent

  @impl true
  def init(_context), do: %{analyzed: 0}

  # Worker receives work assignment with a reply_to address.
  # Uses Directive.async to do file I/O off the TEA loop.
  @impl true
  def update({:agent_message, _from, {:analyze, file, reply_to}}, model) do
    {%{model | analyzed: model.analyzed + 1},
     [
       Directive.async(fn sender ->
         line_count =
           case File.read(file) do
             {:ok, content} -> content |> String.split("\n") |> length()
             {:error, _} -> 0
           end

         has_moduledoc =
           case File.read(file) do
             {:ok, content} -> String.contains?(content, "@moduledoc")
             {:error, _} -> false
           end

         sender.(
           {:report_to, reply_to,
            %{file: file, lines: line_count, has_docs: has_moduledoc}}
         )
       end)
     ]}
  end

  # When async work completes, send the report to the coordinator.
  # Directive.send_agent routes through the Registry by agent :id.
  @impl true
  def update({:command_result, {:report_to, reply_to, report}}, model) do
    {model, [Directive.send_agent(reply_to, {:file_report, report})]}
  end

  @impl true
  def update(_msg, model), do: {model, []}
end

defmodule ReviewCoordinator do
  @moduledoc "Coordinator that dispatches files to workers and collects reports."
  use Raxol.Agent

  @impl true
  def init(_context) do
    %{
      reports: [],
      pending: 0,
      workers: [:analyzer_1, :analyzer_2],
      status: :idle
    }
  end

  @impl true
  def update({:agent_message, _from, {:review, files}}, model) do
    assignments =
      files
      |> Enum.with_index()
      |> Enum.map(fn {file, idx} ->
        worker = Enum.at(model.workers, rem(idx, length(model.workers)))
        Directive.send_agent(worker, {:analyze, file, :coordinator})
      end)

    IO.puts(
      "[coordinator] Dispatching #{length(files)} files to #{length(model.workers)} workers"
    )

    {%{model | pending: length(files), status: :reviewing}, assignments}
  end

  @impl true
  def update({:agent_message, _from, {:file_report, report}}, model) do
    new_reports = [report | model.reports]
    remaining = model.pending - 1

    if remaining == 0 do
      IO.puts("\n=== Review Complete ===")
      IO.puts("Files analyzed: #{length(new_reports)}")
      IO.puts("")

      new_reports
      |> Enum.sort_by(& &1.file)
      |> Enum.each(fn r ->
        docs_marker = if r.has_docs, do: "[docs]", else: "[no docs]"
        IO.puts("  #{r.file}: #{r.lines} lines #{docs_marker}")
      end)

      undocumented =
        Enum.count(new_reports, fn r -> not r.has_docs end)

      IO.puts("")

      IO.puts(
        "Documentation coverage: #{length(new_reports) - undocumented}/#{length(new_reports)} files"
      )

      IO.puts("======================")

      {%{model | reports: new_reports, pending: 0, status: :done},
       [Directive.stop()]}
    else
      IO.puts(
        "[coordinator] Report received for #{report.file} (#{remaining} remaining)"
      )

      {%{model | reports: new_reports, pending: remaining}, []}
    end
  end

  @impl true
  def update(_msg, model), do: {model, []}
end

# -- Boot --
# Agent.Team is an OTP Supervisor. If a worker crashes, the supervisor
# restarts it without affecting the coordinator or other workers.
{:ok, _team_pid} =
  Raxol.Agent.Team.start_link(
    team_id: :review_team,
    coordinator: {ReviewCoordinator, [id: :coordinator]},
    workers: [
      {FileAnalyzer, [id: :analyzer_1]},
      {FileAnalyzer, [id: :analyzer_2]}
    ]
  )

# Give team time to start
Process.sleep(500)

# Kick off a review of agent source files
files = [
  "lib/raxol/agent.ex",
  "lib/raxol/agent/session.ex",
  "lib/raxol/agent/comm.ex",
  "lib/raxol/agent/team.ex"
]

Raxol.Agent.Session.send_message(:coordinator, {:review, files})

# Wait for completion
Process.sleep(5000)
