defmodule RaxolEarn.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The live Xochi solver runtime (auth + job stream + settlement) is opt-in via
    # `config :raxol_earn, xochi_solver_enabled: true`; off, only the local stack runs.
    solver_children =
      if Raxol.Earn.Xochi.SolverApplication.enabled?(),
        do: [Raxol.Earn.Xochi.SolverApplication],
        else: []

    children = [Raxol.Earn.Supervisor] ++ solver_children

    case Supervisor.start_link(children,
           strategy: :one_for_one,
           name: RaxolEarn.RootSupervisor
         ) do
      {:ok, _pid} = ok ->
        maybe_attach_payments_telemetry()
        ok

      other ->
        other
    end
  end

  # When accounting is on, log the payment telemetry (settlement + rebalance events)
  # via the stock handler. Gated so a deployment without accounting keeps its current
  # (silent) behavior. Metrics export to SigNoz is OTLP -> the local OTel Collector
  # (pending the ansible-riddler collector pipeline); wired here when that lands.
  defp maybe_attach_payments_telemetry do
    if Application.get_env(:raxol_earn, :accounting_enabled, false) do
      _ = Raxol.Payments.Telemetry.LoggerHandler.attach()
    end

    :ok
  end
end
