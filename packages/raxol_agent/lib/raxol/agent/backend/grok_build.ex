defmodule Raxol.Agent.Backend.GrokBuild do
  @moduledoc """
  AIBackend wrapping xAI's Grok CLI as a native harness.

  The CLI owns its agent loop. Selected via `backend: :grok_native` in a
  `Raxol.Agent.ExecutorConfig`. See `Raxol.Agent.Backend.Native` for options and
  `Raxol.Agent.Harness.GrokBuild` for the driver — including why this harness
  does not inject Raxol's tools over MCP.
  """

  use Raxol.Agent.Backend.Native, driver: Raxol.Agent.Harness.GrokBuild
end
