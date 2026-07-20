defmodule Raxol.ACP.Offering.Handler do
  @moduledoc """
  Behaviour for ACP offering handlers.

  An offering is the unit of work a seller agent performs. It implements
  three callbacks corresponding to the points in the job lifecycle where
  the seller has to make a decision:

  - `c:resolve_accept/2` -- *(optional)* runs at accept time BEFORE
    `handle_request/2`, to derive authoritative request data and size the
    job budget. An offering that settles through an external service (e.g.
    Xochi) uses it to fetch the buyer's intent, replace the buyer-declared
    corridor/amount with the authoritative values, and compute the budget as
    a percentage of that amount -- instead of trusting the relayed request.
    When absent, the seller runtime uses the offering's flat `price_usdc`.
  - `c:handle_request/2` -- the buyer has submitted a request. Decide
    whether to accept (entering `:negotiation`) or reject.
  - `c:handle_deliver/2` -- payment is escrowed (state has reached
    `:transaction`); produce the deliverable.
  - `c:handle_evaluate/2` -- *(optional)* used only when this seller
    also acts as evaluator. The default lets the buyer act as evaluator.

  Implementing modules typically `use Raxol.ACP.Offering` rather than
  declaring `@behaviour` directly. The DSL injects this behaviour plus
  metadata accessors and a `register/0` convenience.

  ## Context map

  Every callback receives a `ctx` with:

      %{
        job_id: binary(),
        buyer: String.t(),    # 0x address
        seller: String.t(),   # 0x address
        state: atom()         # current JobSession.Status status
      }
  """

  @type ctx :: %{
          required(:job_id) => binary(),
          required(:buyer) => String.t(),
          required(:seller) => String.t(),
          required(:state) => atom()
        }

  @type request :: map()
  @type deliverable :: map()

  @doc """
  Accept-time context, carrying the ACP `chain_id` and the Xochi client config
  (`nil` when unconfigured). Passed to `resolve_accept/2`.
  """
  @type accept_ctx :: %{
          required(:chain_id) => pos_integer(),
          required(:xochi_config) => map() | nil
        }

  @callback resolve_accept(request(), accept_ctx()) ::
              {:ok, request(), Raxol.ACP.AssetToken.t()}
              | {:reject, term()}
              | {:error, term()}

  @callback handle_request(request(), ctx()) ::
              {:accept, map()} | {:reject, term()}

  @callback handle_deliver(request(), ctx()) ::
              {:deliver, deliverable()} | {:error, term()}

  @callback handle_evaluate(deliverable(), ctx()) ::
              {:approve, map()} | {:reject, term()}

  @optional_callbacks handle_evaluate: 2, resolve_accept: 2
end
