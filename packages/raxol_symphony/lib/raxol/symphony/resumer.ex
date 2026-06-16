defmodule Raxol.Symphony.Resumer do
  @moduledoc """
  Auto-resume bridge: telemetry event -> `Orchestrator.resume_run/3`.

  A Symphony runner pauses with a `resume_token` that may carry a
  `:resume_on` spec describing the external event the run is waiting
  for:

      {:pause, :awaiting_buyer_payment,
       %{
         resume_on: %{
           telemetry: [:raxol, :acp, :job, :transition],
           match: %{job_id: "job-1", to: :transaction}
         }
       }}

  Start the Resumer once per orchestrator with the telemetry event
  prefix it should observe:

      Raxol.Symphony.Resumer.start_link(
        orchestrator: Raxol.Symphony.Orchestrator,
        telemetry_event: [:raxol, :acp, :job, :transition]
      )

  On every emitted telemetry event matching that prefix the Resumer
  reads the orchestrator's `paused/1` map, finds entries whose
  `resume_token.resume_on.match` is a subset of the event metadata,
  and calls `Orchestrator.resume_run/3` with the event metadata as
  the resume value.

  ## What this does not do

  - Durably persist paused runs across BEAM restart. The orchestrator
    keeps `state.paused` in-memory; this bridge inherits that scope.
  - Decide WHEN a runner should pause. Runners encode their own
    `resume_on` spec in the token.
  - Reject events. A match always fires `resume_run/3`; the runner is
    responsible for idempotency on resume.
  """

  use GenServer

  require Logger

  alias Raxol.Symphony.Orchestrator

  @type opts :: [
          orchestrator: GenServer.server(),
          telemetry_event: [atom(), ...],
          name: GenServer.name()
        ]

  # -- Public API -------------------------------------------------------------

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(opts()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    orchestrator = Keyword.fetch!(opts, :orchestrator)
    telemetry_event = Keyword.fetch!(opts, :telemetry_event)
    handler_id = "raxol-symphony-resumer-#{:erlang.unique_integer([:positive])}"

    me = self()

    :ok =
      :telemetry.attach(
        handler_id,
        telemetry_event,
        &__MODULE__.__handle_event__/4,
        %{resumer: me}
      )

    Process.flag(:trap_exit, true)

    {:ok,
     %{
       orchestrator: orchestrator,
       telemetry_event: telemetry_event,
       handler_id: handler_id
     }}
  end

  @impl true
  def handle_info({:telemetry, _event, _measurements, metadata}, state) do
    {:noreply, fan_out_matches(state, metadata)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Telemetry callback -----------------------------------------------------
  #
  # `:telemetry` runs handlers in the EMITTER's process, so we forward
  # to the Resumer GenServer to keep the orchestrator lookup off the
  # hot path. Public for `:telemetry.attach/4`; not part of the public
  # API.

  @doc false
  def __handle_event__(event, measurements, metadata, %{resumer: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  # -- Matching ---------------------------------------------------------------

  defp fan_out_matches(%{orchestrator: orchestrator} = state, metadata) do
    paused = Orchestrator.paused(orchestrator)

    Enum.each(paused, fn {issue_id, entry} ->
      if subset?(extract_match(entry.resume_token), metadata) do
        case Orchestrator.resume_run(orchestrator, issue_id, metadata) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "raxol.symphony.resumer.resume_failed issue=#{issue_id} " <>
                "reason=#{inspect(reason)}"
            )
        end
      end
    end)

    state
  end

  defp extract_match(%{resume_on: %{match: match}}) when is_map(match), do: match
  defp extract_match(_), do: nil

  defp subset?(nil, _metadata), do: false

  defp subset?(match, metadata) when is_map(match) and is_map(metadata) do
    Enum.all?(match, fn {k, v} -> Map.get(metadata, k) == v end)
  end

  defp subset?(_, _), do: false
end
