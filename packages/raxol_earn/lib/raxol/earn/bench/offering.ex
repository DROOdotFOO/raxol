defmodule Raxol.Earn.Bench.Offering do
  @moduledoc """
  Echo offering used by `mix raxol_earn.bench`.

  Accepts every request, echoes the request map back as the
  deliverable. Picks `cluster: "information"` because that's the
  highest-volume ACP cluster -- matches the production realism of the
  bench without doing real work.

  Pair with `Raxol.Earn.Bench.Wallet` for signing. The bench runner
  registers this offering automatically.
  """

  use Raxol.Earn.Offering,
    name: "raxol.bench.echo",
    price_usdc: "0.01",
    sla_minutes: 1,
    cluster: "information"

  @impl Raxol.Earn.Offering
  def requirements_schema do
    %{
      type: "object",
      required: ["payload"],
      properties: %{"payload" => %{type: "object"}}
    }
  end

  @impl Raxol.Earn.Offering
  def deliverables_schema do
    %{type: "object", required: ["echo"], properties: %{"echo" => %{type: "object"}}}
  end

  @impl Raxol.Earn.Offering.Handler
  def handle_request(req, _ctx), do: {:accept, req}

  @impl Raxol.Earn.Offering.Handler
  def handle_deliver(req, _ctx), do: {:deliver, %{"echo" => req}}
end
