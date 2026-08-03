defmodule Raxol.Earn.JobSession.Registry do
  @moduledoc """
  Process registry for active v2 ACP job sessions.

  Wraps `Registry` (`keys: :unique`) so that each `Raxol.Earn.JobSession`
  is addressable by `{chain_id, job_id}`. v2 jobs can run on multiple
  chains, so the key carries the chain id alongside the job id (v1's
  `Raxol.Earn.Job.Registry` keys by job_id alone because v1 was Base
  mainnet only).

  ## Usage

      # JobSession registers itself via:
      GenServer.start_link(JobSession, opts,
        name: Raxol.Earn.JobSession.Registry.via({8453, "job-123"})
      )

      # Anywhere else can resolve the pid:
      case Raxol.Earn.JobSession.Registry.whereis({8453, "job-123"}) do
        :undefined -> :no_such_session
        pid when is_pid(pid) -> pid
      end
  """

  @type job_key :: {pos_integer(), String.t() | non_neg_integer()}

  @doc "Build a `:via` tuple for registering or addressing a session."
  @spec via(job_key()) :: {:via, module(), {module(), job_key()}}
  def via({chain_id, job_id} = key)
      when is_integer(chain_id) and (is_binary(job_id) or is_integer(job_id)) do
    {:via, Registry, {__MODULE__, key}}
  end

  @doc "Look up the pid of a session by `{chain_id, job_id}`."
  @spec whereis(job_key()) :: pid() | :undefined
  def whereis({chain_id, job_id} = key)
      when is_integer(chain_id) and (is_binary(job_id) or is_integer(job_id)) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _}] -> pid
      [] -> :undefined
    end
  end

  @doc "Child spec for use under a supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
