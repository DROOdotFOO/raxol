defmodule Raxol.ACP.JobSession.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Raxol.ACP.JobSession` processes.

  Sessions are transient -- a clean `:normal` exit (which happens on
  terminal status) means the supervisor does NOT restart the session.
  Crashes will be retried per the supervisor's restart policy.
  """

  use DynamicSupervisor

  alias Raxol.ACP.JobSession

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Spawn a new JobSession process. `opts` are forwarded to
  `Raxol.ACP.JobSession.start_link/1`.
  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) do
    spec = %{
      id: JobSession,
      start: {JobSession, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
