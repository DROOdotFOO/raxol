defmodule Raxol.ACP.Job.Registry do
  @moduledoc """
  Process registry for active ACP jobs.

  Wraps Elixir's `Registry` (`keys: :unique`) so that each
  `Raxol.ACP.Job.Server` can be looked up by its job ID.

  ## Usage

      # Job.Server registers itself via:
      GenServer.start_link(Job.Server, opts, name: Raxol.ACP.Job.Registry.via("job-123"))

      # Anywhere else can resolve the pid:
      case Raxol.ACP.Job.Registry.whereis("job-123") do
        :undefined -> :no_such_job
        pid when is_pid(pid) -> pid
      end
  """

  @doc """
  Build a `:via` tuple for registering or addressing a job process.
  """
  @spec via(binary()) :: {:via, module(), {module(), binary()}}
  def via(job_id) when is_binary(job_id) do
    {:via, Registry, {__MODULE__, job_id}}
  end

  @doc """
  Look up the pid of a job by ID.

  Returns `:undefined` if no job with that ID is currently running.
  """
  @spec whereis(binary()) :: pid() | :undefined
  def whereis(job_id) when is_binary(job_id) do
    case Registry.lookup(__MODULE__, job_id) do
      [{pid, _}] -> pid
      [] -> :undefined
    end
  end

  @doc """
  Child spec for use under a supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
