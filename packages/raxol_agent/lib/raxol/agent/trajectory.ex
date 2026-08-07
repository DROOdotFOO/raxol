defmodule Raxol.Agent.Trajectory do
  @moduledoc """
  Export a `raxol.p` run as one self-contained trajectory JSON file.

  Built from the contract events the run itself emitted on stderr -- the
  same `Raxol.Agent.Contract.Event` stream, so the file is a faithful
  restatement of the wire trace, not a second bookkeeping path. Written on
  EVERY exit (success, error, timeout, budget, SIGTERM): a harness must
  never lose the trace of a killed run.

  Shape (`schema: "raxol-trajectory/1"`):

    * `metadata` — prompt, backend/model, profile flags, raxol version
    * `steps`    — one entry per contract event, in emission order
    * `totals`   — completed turns, accumulated token usage, cost (when
      rates were configured)
    * `outcome`  — exit code + reason (`completed`, `error`, `timeout`,
      `budget_exhausted`, `terminated`)
  """

  alias Raxol.Agent.BenchmarkProfile
  alias Raxol.Agent.Contract

  @schema "raxol-trajectory/1"

  @doc """
  Build the trajectory map from accumulated run state.

  `events` is the list of `Contract.Event` structs oldest-first; `meta`
  carries `%{prompt, backend, model, profile, turns, usage, exit_code,
  reason}`.
  """
  @spec build([struct()], map()) :: map()
  def build(events, meta) do
    profile = Map.get(meta, :profile) || %BenchmarkProfile{}
    usage = Map.get(meta, :usage, %{})

    %{
      schema: @schema,
      metadata: %{
        prompt: Map.get(meta, :prompt),
        backend: Map.get(meta, :backend),
        model: Map.get(meta, :model),
        profile: if(profile.active?, do: "benchmark", else: "default"),
        max_turns: profile.max_turns,
        max_cost_usd: profile.max_cost_usd,
        raxol_agent_version: version()
      },
      steps: Enum.map(events, &step/1),
      totals: %{
        turns: Map.get(meta, :turns, 0),
        usage: usage,
        cost_usd: BenchmarkProfile.cost_usd(profile, usage)
      },
      outcome: %{
        exit_code: Map.get(meta, :exit_code),
        reason: Map.get(meta, :reason)
      }
    }
  end

  @doc """
  Write the trajectory to `path` (parent dirs created). Failures are
  reported on stderr but never crash the exiting run -- losing the
  trajectory must not also lose the exit status.
  """
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, trajectory) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(trajectory, pretty: true),
         :ok <- File.write(path, [json, "\n"]) do
      :ok
    else
      {:error, reason} = error ->
        IO.puts(
          :stderr,
          ~s({"type":"error","payload":{"reason":"trajectory_write_failed","detail":#{inspect(inspect(reason))}}})
        )

        error
    end
  end

  # Payloads can carry non-JSON terms (error-reason tuples, structs); run
  # them through the same boundary sanitization the stderr stream and the
  # durable journal use, so a failed run's trajectory always encodes.
  defp step(%{type: type, payload: payload} = event) do
    %{
      type: type,
      turn_id: Map.get(event, :turn_id),
      payload: Contract.sanitize_payload(payload || %{})
    }
  end

  defp version do
    case :application.get_key(:raxol_agent, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
