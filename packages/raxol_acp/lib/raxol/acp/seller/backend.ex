defmodule Raxol.ACP.Seller.Backend do
  @moduledoc """
  Behaviour for the connection that delivers ACP backend events to the
  seller runtime.

  ## Why a behaviour, not a single hard-coded WebSocket client

  Same rationale as `Raxol.ACP.ContractClient`. The project rule is "no
  mocks", so we ship two real implementations and pick one via
  configuration:

  - `Raxol.ACP.Seller.Backend.InMemory` -- subscribers are notified when
    a caller calls `publish/1`. Used by tests and by the bench harness.
    A second real impl, not a mock.
  - `Raxol.ACP.Seller.Backend.WebSocket` -- live `mint_web_socket`
    connection to the ACP backend's notification socket. (Lands with
    `ContractClient.Onchain` in a follow-up; both need a live endpoint
    to be testable.)

  Pick the impl with:

      config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.InMemory

  ## Event shape

  Backends MUST deliver events to subscribers as Elixir messages of the
  shape `{:acp_event, event}` where `event` is a map with at minimum a
  `:type` key. The `Raxol.ACP.Seller.Queue` is the canonical consumer
  and understands the following event types:

  - `:job_offered` -- new buyer request landed; fields:
    `:job_id`, `:offering`, `:request`, `:buyer`
  - `:payment_received` -- buyer's payment authorization arrived;
    fields: `:job_id`, `:payload`, optional `:signature`
  - `:approval_received` -- buyer (or evaluator) approved the
    deliverable; fields: `:job_id`, `:payload`, optional `:signature`
  - `:job_expired` -- SLA timeout / cancellation; fields: `:job_id`,
    optional `:reason`

  ## Lifecycle

  Backend impls are GenServers (or whatever exposes
  `child_spec/1`). They must register under their own module name so
  `Raxol.ACP.Seller.Runtime` can subscribe to them by referring to the
  module:

      Raxol.ACP.Seller.Backend.subscribe(impl_module, self())

  ## Multi-subscriber

  Backends may support more than one subscriber. The Runtime is the
  default consumer; tests can subscribe directly to inspect events
  without going through the Queue.
  """

  @type event :: %{required(:type) => atom(), optional(atom()) => any()}

  @doc """
  Register `subscriber` to receive `{:acp_event, event}` messages.

  Returns `:ok`. Idempotent: subscribing the same pid twice is a no-op
  (but does not raise). Backends monitor subscribers and remove them on
  death.
  """
  @callback subscribe(subscriber :: pid()) :: :ok

  @doc """
  Stop delivering events to `subscriber`. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok

  @doc "Return the count of currently registered subscribers."
  @callback subscriber_count() :: non_neg_integer()

  # -- Delegating helpers --

  @doc "Subscribe `pid` to events from the given backend module."
  @spec subscribe(module(), pid()) :: :ok
  def subscribe(backend, pid) when is_atom(backend) and is_pid(pid) do
    backend.subscribe(pid)
  end

  @doc "Unsubscribe `pid` from the given backend module."
  @spec unsubscribe(module(), pid()) :: :ok
  def unsubscribe(backend, pid) when is_atom(backend) and is_pid(pid) do
    backend.unsubscribe(pid)
  end
end
