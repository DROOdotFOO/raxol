defmodule Raxol.ACP.TestSupport.EchoOffering do
  @moduledoc """
  Real example offering used by the Offering test suite.

  Echoes the buyer's request back as the deliverable. Demonstrates the
  full `use Raxol.ACP.Offering` DSL surface: name, price_usdc,
  sla_minutes, cluster, both schema callbacks, and both required
  Handler callbacks.
  """

  use Raxol.ACP.Offering,
    name: "test.echo",
    price_usdc: "0.01",
    sla_minutes: 1,
    cluster: "information"

  @impl true
  def requirements_schema do
    %{
      type: "object",
      required: ["text"],
      properties: %{"text" => %{type: "string"}}
    }
  end

  @impl true
  def deliverables_schema do
    %{
      type: "object",
      required: ["echo"],
      properties: %{"echo" => %{type: "string"}}
    }
  end

  @impl true
  def handle_request(req, _ctx), do: {:accept, req}

  @impl true
  def handle_deliver(%{"text" => text}, _ctx) do
    {:deliver, %{"echo" => text}}
  end

  def handle_deliver(_req, _ctx), do: {:error, :missing_text}
end
