defmodule Raxol.Plugins.MyBasicPlugin do
  @moduledoc """
  Basic template for Raxol plugins.
  """

  use Raxol.Plugin

  require Logger

  def manifest do
    %{
      id: "my-basic-plugin",
      name: "My Basic Plugin",
      version: "1.0.0",
      author: "Your Name",
      module: __MODULE__,
      description: "A basic plugin template",
      depends_on: [],
      provides: [:command_handler]
    }
  end

  defstruct [:config, :enabled, :data]

  @impl true
  def init(config) do
    state = %__MODULE__{config: config, enabled: true, data: %{}}
    Logger.info("[MyBasicPlugin] Initialized")
    {:ok, state}
  end

  @impl true
  def handle_command(:hello, _args, state) do
    {:ok, state, "Hello from #{__MODULE__}!"}
  end

  def handle_command(command, _args, state) do
    {:error, "Unknown command: #{command}", state}
  end

  @impl true
  def get_commands, do: [{:hello, :handle_command, 3}]
end
