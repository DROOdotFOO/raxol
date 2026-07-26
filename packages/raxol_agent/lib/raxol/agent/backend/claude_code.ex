defmodule Raxol.Agent.Backend.ClaudeCode do
  @moduledoc """
  AIBackend wrapping the Claude Code CLI as a native harness.

  The CLI owns its agent loop; Raxol tools are injected over MCP. Selected via
  `backend: :claude_native` in a `Raxol.Agent.ExecutorConfig`. See
  `Raxol.Agent.Backend.Native` for options and `Raxol.Agent.Harness.ClaudeCode`
  for the driver.
  """

  use Raxol.Agent.Backend.Native, driver: Raxol.Agent.Harness.ClaudeCode
end
