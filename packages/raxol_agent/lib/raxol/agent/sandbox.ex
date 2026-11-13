defprotocol Raxol.Agent.Sandbox do
  @moduledoc """
  Multi-dimensional isolation protocol for agent operations.

  Each `Sandbox` struct is a declarative statement about what an
  agent may do along one dimension (Shell, SendAgent, Async, ...).
  Implementations return `:ok` to allow, `{:deny, reason}` to block,
  or `:ok` as an *abstention* when the action is outside the
  sandbox's dimension. Walking a list of sandboxes (via
  `Raxol.Agent.Sandbox.authorize_chain/4`) and short-circuiting on
  the first `:deny` is the canonical composition.

  ## Built-in dimensions

  - `Raxol.Agent.Sandbox.Shell` -- gates `Raxol.Agent.Directive.Shell`
    via allowlist / denylist / `deny_all`.
  - `Raxol.Agent.Sandbox.SendAgent` -- gates
    `Raxol.Agent.Directive.SendAgent` via allow_only / deny.
  - `Raxol.Agent.Sandbox.Async` -- gates
    `Raxol.Agent.Directive.Async` (wholesale allow / deny).

  Filesystem, Network, and Resource dimensions are planned
  but deferred to a follow-up because their enforcement layer
  is different (Action integration for filesystem / network;
  OS-level quotas for Resource).

  ## Action atoms

  The protocol's `action` argument identifies what's being
  authorized. Built-in atoms:

  - `:shell` -- `Directive.Shell` (payload: `%{command, opts}`)
  - `:send_agent` -- `Directive.SendAgent` (payload: `%{target_id,
    message}`)
  - `:async` -- `Directive.Async` (payload: `%{fun}`)

  A sandbox's `authorize/4` returns `:ok` for any action that
  doesn't match its dimension; that's the abstention case.

  ## Context

  `ctx` is a map opaquely passed through. The integration layer
  populates it with at least:

  - `:agent_id` -- the calling agent
  - `:agent_module` -- the agent's module

  Dimension implementations may inspect or ignore `ctx` as they
  see fit.
  """

  @typedoc "Authorization decision."
  @type decision :: :ok | {:deny, reason :: term()}

  @doc """
  Decide whether the agent may perform `action` with the given
  `payload`. Return `:ok` to allow or abstain (when `action` is
  outside the sandbox's dimension), `{:deny, reason}` to block.
  """
  @spec authorize(t(), action :: atom(), payload :: term(), ctx :: map()) ::
          decision()
  def authorize(sandbox, action, payload, ctx)
end

defmodule Raxol.Agent.Sandbox.Chain do
  @moduledoc """
  Walk a list of sandboxes for a single authorization decision.

  Each sandbox is queried in order. The first `{:deny, reason}`
  short-circuits; otherwise `:ok` after all sandboxes have
  abstained or allowed.
  """

  alias Raxol.Agent.Sandbox

  @doc """
  Authorize an action against a list of sandboxes, first-deny-wins.

  Returns `:ok` when every sandbox abstained or allowed,
  `{:deny, reason}` on the first deny.
  """
  @spec authorize(
          [Sandbox.t()],
          action :: atom(),
          payload :: term(),
          ctx :: map()
        ) :: Sandbox.decision()
  def authorize([], _action, _payload, _ctx), do: :ok

  def authorize([sandbox | rest], action, payload, ctx) do
    case Sandbox.authorize(sandbox, action, payload, ctx) do
      :ok -> authorize(rest, action, payload, ctx)
      {:deny, _reason} = denied -> denied
    end
  end
end
