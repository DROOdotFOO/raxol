defmodule Raxol.Agent.Backend.Cursor do
  @moduledoc """
  AIBackend wrapping the Cursor agent CLI (`cursor-agent`) as a native harness.

  The CLI owns its agent loop; Raxol tools are injected over MCP. Selected via
  `backend: :cursor` in a `Raxol.Agent.ExecutorConfig`. See
  `Raxol.Agent.Backend.Native` for options and `Raxol.Agent.Harness.Cursor` for
  the driver.
  """

  use Raxol.Agent.Backend.Native, driver: Raxol.Agent.Harness.Cursor
end
