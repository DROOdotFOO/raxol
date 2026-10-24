defmodule Raxol.MCP.Test.Session do
  @moduledoc """
  Struct representing a test session for MCP testing.

  Holds references to the session ID, registry, and configuration.
  All mutable state lives in the Headless GenServer and Registry ETS tables.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          registry: GenServer.server(),
          registry_pid: pid(),
          module: module() | String.t()
        }

  defstruct [:id, :registry, :registry_pid, :module]
end
