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
    * `:executor` - options for `Raxol.Broker.Executor.start_link/1`. When
      given, the executor starts after the journal and restarts with it; its
      `:journal` defaults to this supervisor's journal and its `:name` to
      `Raxol.Broker.Executor`. Omit it to run the journal alone.
  """

  use Supervisor

  alias Raxol.Broker.{Executor, Journal}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    journal_opts = Keyword.get(opts, :journal, [])
    journal = Keyword.get(journal_opts, :name, Journal)

    executor =
      case Keyword.fetch(opts, :executor) do
        {:ok, executor_opts} ->
          executor_opts =
            executor_opts
            |> Keyword.put_new(:journal, journal)
            |> Keyword.put_new(:name, Executor)

          [{Executor, executor_opts}]

        :error ->
          []
      end

    Supervisor.init([{Journal, journal_opts} | executor], strategy: :rest_for_one)
  end
end
