defmodule Raxol.ACP.Bench.Offering do
  @moduledoc """
  Echo offering used by `mix raxol_acp.bench`.

  Accepts every request, echoes the request map back as the
  deliverable. Picks `cluster: "information"` because that's the
  highest-volume ACP cluster -- matches the production realism of the
  bench without doing real work.

  Pair with `Raxol.ACP.Bench.Wallet` for signing. The bench runner
  registers this offering automatically.
  """

  use Raxol.ACP.Offering,
    name: "raxol.bench.echo",
    price_usdc: "0.01",
    sla_minutes: 1,
    cluster: "information"

  @impl Raxol.ACP.Offering
  def requirements_schema do
    %{
      type: "object",
      required: ["payload"],
      properties: %{"payload" => %{type: "object"}}
    }
  end

  @impl Raxol.ACP.Offering
  def deliverables_schema do
    %{type: "object", required: ["echo"], properties: %{"echo" => %{type: "object"}}}
  end

  @impl Raxol.ACP.Offering.Handler
  def handle_request(req, _ctx), do: {:accept, req}

  @impl Raxol.ACP.Offering.Handler
  def handle_deliver(req, _ctx), do: {:deliver, %{"echo" => req}}
end
