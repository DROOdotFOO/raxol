defmodule Raxol.ACP.Job.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns one `Raxol.ACP.Job.Server` per active job.

  Children are `restart: :transient` so a clean termination (the server
  hits a terminal state and stops with `:normal`) does not cause a
  restart. Crashes still restart per the strategy.
  """

  use DynamicSupervisor

  alias Raxol.ACP.Job

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new `Job.Server` under this supervisor.

  Forwards `opts` to `Job.Server.start_link/1` (which requires a
  `:job_id` key). Returns the standard `DynamicSupervisor.start_child/2`
  result.
  """
  @spec start_job(keyword()) :: DynamicSupervisor.on_start_child()
  def start_job(opts) do
    spec = %{
      id: Job.Server,
      start: {Job.Server, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Terminate the job process for a given `job_id`.

  Returns `:ok` if the job was running and is now stopped, or
  `{:error, :not_found}` if no such job exists.
  """
  @spec terminate_job(binary()) :: :ok | {:error, :not_found}
  def terminate_job(job_id) when is_binary(job_id) do
    case Job.Registry.whereis(job_id) do
      :undefined -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "Return the count of active job processes."
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: n} = DynamicSupervisor.count_children(__MODULE__)
    n
  end
end
