defmodule Raxol.Console.Scheduler.Wiring do
  @moduledoc """
  PROTOTYPE -- Console runtime integration spike, Stage 3 (persona/delivery seam).

  Composes the two scheduler primitives a Console agent needs into the option
  set `Raxol.Agent.Scheduler` expects, so a provisioned agent's scheduled tasks
  run with its `soul.md` persona and deliver results to its messaging channels:

    * runner  -- `Raxol.Agent.Scheduler.Fire.runner/1` with `:system_prompt`
      (the resolved soul.md) and `:agent_opts` (the executor). Each fire is a
      fresh, history-free agent turn; the job's skills are injected on top.
    * deliver -- `Raxol.Agent.Scheduler.Delivery.gateway/1`, which routes a
      job's `"platform:chat_id"` target through `Raxol.Gateway.Delivery` against
      the gateway's connected-adapters map.

  Both halves already ship with the cron scheduler; this module is pure
  composition -- the Stage-3 finding is that no net-new runtime code is needed,
  only the wiring below. It lives in test/support for the spike and graduates to
  `packages/raxol_console/` (the loader's `Boot` stage) when that package lands.
  """

  alias Raxol.Agent.Scheduler.{Delivery, Fire}
  alias Raxol.Agent.Skills

  @type config :: %{
          required(:adapters) => Delivery.adapters(),
          optional(:system_prompt) => String.t() | nil,
          optional(:agent_opts) => keyword(),
          optional(:skills_store) => GenServer.server(),
          optional(:dispatch) => ((-> any()) -> any())
        }

  @doc """
  Build the `:runner` / `:deliver` (and optional `:dispatch`) option set for
  `Raxol.Agent.Scheduler` from a Console runtime config.

  Merge the result into the scheduler's start opts (`:name`, `:now_fn`, DETS
  store, ...). `Boot` will feed this into `config :raxol_agent, :scheduler`.
  """
  @spec scheduler_opts(config()) :: keyword()
  def scheduler_opts(%{adapters: adapters} = config) do
    runner =
      Fire.runner(
        system_prompt: Map.get(config, :system_prompt),
        agent_opts: Map.get(config, :agent_opts, []),
        skills: Map.get(config, :skills_store, Skills.Store)
      )

    base = [runner: runner, deliver: Delivery.gateway(adapters)]

    case Map.get(config, :dispatch) do
      dispatch when is_function(dispatch, 1) -> Keyword.put(base, :dispatch, dispatch)
      _ -> base
    end
  end
end
