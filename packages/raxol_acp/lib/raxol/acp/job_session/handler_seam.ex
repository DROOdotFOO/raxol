defmodule Raxol.ACP.JobSession.HandlerSeam do
  @moduledoc """
  Maps a provider lifecycle point to the matching
  `Raxol.ACP.Offering.Handler` callback.

  The v2 provider driver (Phase 1) uses this to invoke an offering's handler
  at the right point in a `Raxol.ACP.JobSession` lifecycle:

  - `:request` -> `c:Raxol.ACP.Offering.Handler.handle_request/2` when a job
    is offered (before `set_budget`).
  - `:deliver` -> `c:Raxol.ACP.Offering.Handler.handle_deliver/2` once the
    job is funded (before `submit`).
  - `:evaluate` -> `c:Raxol.ACP.Offering.Handler.handle_evaluate/2` when the
    provider also acts as evaluator (before `complete`/`reject`).

  `handle_evaluate/2` is optional in the behaviour. When the handler does not
  implement it, an `:evaluate` invocation returns
  `{:error, :evaluate_not_supported}` so the driver can fall back to an
  external evaluator instead of crashing.

  This module is intentionally free of `JobSession` coupling: the caller
  builds the `ctx` (from the session's `job_id`/addresses/`state`) and threads
  the handler result into the appropriate `JobSession` transition.
  """

  @type point :: :request | :deliver | :evaluate
  @type ctx :: Raxol.ACP.Offering.Handler.ctx()

  @type result ::
          {:accept, map()}
          | {:deliver, map()}
          | {:approve, map()}
          | {:reject, term()}
          | {:error, term()}

  @doc """
  Invoke `handler`'s callback for `point` with `input` and `ctx`.

  `input` is the buyer's request for `:request`/`:deliver`, and the
  deliverable for `:evaluate`.
  """
  @spec invoke(module(), point(), map(), ctx()) :: result()
  def invoke(handler, :request, request, ctx) when is_atom(handler),
    do: handler.handle_request(request, ctx)

  def invoke(handler, :deliver, request, ctx) when is_atom(handler),
    do: handler.handle_deliver(request, ctx)

  def invoke(handler, :evaluate, deliverable, ctx) when is_atom(handler) do
    if function_exported?(handler, :handle_evaluate, 2) do
      handler.handle_evaluate(deliverable, ctx)
    else
      {:error, :evaluate_not_supported}
    end
  end
end
