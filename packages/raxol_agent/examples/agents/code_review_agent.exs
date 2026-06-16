# Code Review Agent Example
#
# A headless AI agent that reads files via shell commands, simulates
# an LLM analysis pass, then prints findings and exits.
#
# What you'll learn:
#   - `use Raxol.Agent` gives you TEA + agent-specific commands
#   - Agents receive {:agent_message, from, payload} for inter-agent comms
#   - Directive.shell(cmd) runs a shell command; result arrives as
#     {:command_result, {:shell_result, %{output: ..., exit_status: ...}}}
#   - Directive.async(fn sender -> ... end) runs async work; the sender
#     callback delivers results back to update/2
#   - Agents are TEA apps where input comes from tools/messages, not keyboard
#
# Usage:
#   mix run examples/agents/code_review_agent.exs

Logger.configure(level: :warning)

defmodule CodeReviewAgent do
  # `use Raxol.Agent` imports everything from Raxol.Core.Runtime.Application
  # plus agent-specific helpers: Directive.shell/1, Directive.async/1,
  # Directive.send_agent/2, Directive.stop/0.
  use Raxol.Agent

  @impl true
  def init(_context) do
    files = ["lib/raxol/agent.ex", "lib/raxol/agent/session.ex"]

    %{
      files: files,
      current_file: nil,
      findings: [],
      status: :starting
    }
  end

  # {:agent_message, from, payload} is how agents receive messages from
  # other agents or from external code via Session.send_message/2.
  @impl true
  def update({:agent_message, _from, :start_review}, model) do
    case model.files do
      [file | rest] ->
        {%{model | current_file: file, files: rest, status: :reading},
         [Directive.shell("wc -l < #{file}")]}

      [] ->
        {%{model | status: :done}, []}
    end
  end

  # Shell command results arrive wrapped in {:command_result, {:shell_result, ...}}.
  # The result map contains :output (stdout string) and :exit_status (integer).
  @impl true
  def update({:command_result, {:shell_result, result}}, model) do
    finding = %{
      file: model.current_file,
      line_count: String.trim(result.output),
      exit_status: result.exit_status
    }

    new_model = %{model | findings: [finding | model.findings]}

    case model.files do
      [next | rest] ->
        {%{new_model | current_file: next, files: rest},
         [Directive.shell("wc -l < #{next}")]}

      [] ->
        # Directive.async runs a function in a spawned process. The sender
        # callback delivers results back to this agent's update/2 as
        # {:command_result, whatever_you_pass_to_sender}.
        {%{new_model | status: :analyzing},
         [
           Directive.async(fn sender ->
             Process.sleep(100)

             sender.(
               {:analysis_complete, "All files reviewed. No critical issues."}
             )
           end)
         ]}
    end
  end

  @impl true
  def update({:command_result, {:analysis_complete, summary}}, model) do
    IO.puts("\n--- Code Review Complete ---")
    IO.puts("Summary: #{summary}")
    IO.puts("Files reviewed: #{length(model.findings)}")

    Enum.each(model.findings, fn f ->
      IO.puts("  #{f.file}: #{f.line_count}")
    end)

    {%{model | status: :done}, [Directive.stop()]}
  end

  @impl true
  def update(msg, model) do
    IO.puts("[CodeReviewAgent] Unhandled: #{inspect(msg)}")
    {model, []}
  end

  # view/1 is optional for agents. Headless agents can skip it entirely.
  # This one renders a simple status display.
  @impl true
  def view(model) do
    column do
      [
        text("Code Review Agent", style: [:bold]),
        text("Status: #{model.status}"),
        text("Files remaining: #{length(model.files)}"),
        text("Findings: #{length(model.findings)}")
      ]
    end
  end
end

# -- Boot --
# Agent.Session wraps Lifecycle with environment: :agent (skips terminal
# driver and plugin manager). Agents discover each other via the unique
# Raxol.Agent.Registry, keyed by :id.
{:ok, _pid} =
  Raxol.Agent.Session.start_link(
    app_module: CodeReviewAgent,
    id: :code_reviewer
  )

# send_message/2 delivers a message that arrives in update/2 as
# {:agent_message, from, :start_review}
Raxol.Agent.Session.send_message(:code_reviewer, :start_review)

# Wait for it to finish
Process.sleep(3000)
