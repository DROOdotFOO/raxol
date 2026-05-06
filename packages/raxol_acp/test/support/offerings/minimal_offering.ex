defmodule Raxol.ACP.TestSupport.MinimalOffering do
  @moduledoc """
  Offering that declares only the required `:name` use option, with no
  price/SLA/cluster/schemas. Verifies the DSL gracefully handles
  optional metadata.
  """

  use Raxol.ACP.Offering, name: "test.minimal"

  @impl true
  def handle_request(req, _ctx), do: {:accept, req}

  @impl true
  def handle_deliver(_req, _ctx), do: {:deliver, %{ok: true}}
end
