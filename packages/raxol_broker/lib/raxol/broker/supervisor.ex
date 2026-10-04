defmodule Raxol.Broker.Supervisor do
  @moduledoc """
  Root supervisor for a broker install. Add it to your own supervision tree:

      children = [{Raxol.Broker.Supervisor, journal: [path: "/var/lib/broker/journal"]}]

  The package has no application callback, so nothing starts, and nothing
  touches the journal directory, until you start this supervisor.

  ## Strategy

  `:rest_for_one`. Children are ordered so that everything that records
  decisions starts after `Raxol.Broker.Journal` and restarts with it. The
  journal is first: a process that could place an order must never outlive it.

  ## Options

    * `:name` - supervisor name, default `#{inspect(__MODULE__)}`
    * `:journal` - options for `Raxol.Broker.Journal.start_link/1`
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    children = [{Raxol.Broker.Journal, Keyword.get(opts, :journal, [])}]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
