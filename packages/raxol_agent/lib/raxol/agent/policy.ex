defmodule Raxol.Agent.Policy do
  @moduledoc """
  Umbrella for declarative `Raxol.Agent.PolicyApplier` policies.

  Each policy is a struct that wraps an operation with one
  side-condition: retry on failure, abort on timeout, short-circuit
  on cache hit. Policies are composable; the applier walks a list
  and wraps the operation outermost-first.

  ## Built-in policies

      Policy.Cache.ets(ttl_ms: 300_000, key_fn: &(&1.user_id))
      Policy.Timeout.new(30_000)
      Policy.Retry.exponential(max_attempts: 3, base_ms: 200)

  ## Composition order

  When passed to `Raxol.Agent.PolicyApplier.apply/3`:

      apply([Cache, RateLimit, Timeout, Retry, ...], fun, params)

  the runtime evaluates from outermost (head) to innermost (just
  before `fun`):

  1. **Cache** -- check; on hit, return the cached value and stop.
  2. **RateLimit** (deferred) -- check; on reject, return
     `{:error, :rate_limited}`.
  3. **Timeout** -- wrap; spawn `fun` in a `Task` and abort on
     `wall_ms` elapsed.
  4. **Retry** -- wrap; loop until success or attempts exhausted.
  5. **fun** -- the wrapped operation runs.

  The reverse of declaration order is intentional: the author lists
  "what I want true at the top" (cache first, then rate limits,
  then bounded wall time, then retry on failure); the runtime peels
  them off in order.

  ## Telemetry

  Every policy decision emits an event under
  `[:raxol, :agent, :policy, :*]`:

  - `:cache_hit`, `:cache_miss`
  - `:retry_attempt`, `:retry_exhausted`
  - `:timeout`
  - `:applied` (final outcome of the composed pipeline)

  Metadata: `policy_kind`, `params_digest` (a truncated hash of the
  operation's argument -- the argument itself is never emitted),
  `attempt` (where applicable), plus any trace context attached upstream.
  """

  alias __MODULE__.{Cache, Retry, Timeout}

  @type t :: Retry.t() | Timeout.t() | Cache.t()
end
