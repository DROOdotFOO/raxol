defmodule Raxol.Broker.Supervisor do
  @moduledoc "Top-level supervisor for broker runtime processes."

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :rest_for_one)
  end
end
