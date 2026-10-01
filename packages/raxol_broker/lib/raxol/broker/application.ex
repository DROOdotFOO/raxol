defmodule Raxol.Broker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args), do: Raxol.Broker.Supervisor.start_link()
end
