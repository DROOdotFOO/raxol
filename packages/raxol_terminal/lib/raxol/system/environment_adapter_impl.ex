defmodule Raxol.System.EnvironmentAdapterImpl do
  @moduledoc """
  Concrete implementation of EnvironmentAdapterBehaviour using Elixir's System module.
  """

  @behaviour Raxol.System.EnvironmentAdapterBehaviour

  @impl Raxol.System.EnvironmentAdapterBehaviour
  def get_env(variable) do
    System.get_env(variable)
  end

  @impl Raxol.System.EnvironmentAdapterBehaviour
  def cmd(command, args, options \\ []) do
    System.cmd(command, args, options)
  end
end
