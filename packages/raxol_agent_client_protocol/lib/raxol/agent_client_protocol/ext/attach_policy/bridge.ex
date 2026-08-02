defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.Bridge do
  @moduledoc """
  The BEAM-local `:authorize` bridge — make the in-process
  `Raxol.Agent.Reattach` attach seam defer to the SAME fail-closed admission
  funnel (`Ext.AttachPolicy.Runner`) the untrusted ACP boundary uses.

  ## Why this exists (the two-wire boundary — harness freeze §1.5, OQ-JS6/OQ-JS7)

  Admission is enforced at the process/trust boundary, NOT symmetrically on every
  wire:

    * **ACP boundary (untrusted peers) — HARD-GATED.** `session/load` and
      `_raxol/session.load` converge on `Ext.Reattach.attach/1`, which runs the
      Runner funnel before any read. This is the security boundary.
    * **BEAM-local `Raxol.Agent.Reattach.attach/4` (in-process) — OPTIONAL
      SEAM.** It carries `opts[:authorize]` (an `authorize_fun`, default
      `{:ok, :in_process}`): an in-process caller can already
      `FileStore.Reader.scan` the session dir directly, so a gate on the function
      is bypassable — it is a SEAM for a host that fronts reattach with its own
      transport, not a boundary.

  This module is that seam's ready-made implementation. `authorizer/1` returns an
  `authorize_fun` that translates the BEAM-local attach ctx into the CDI-2 Runner
  ctx and returns the Runner's verdict verbatim. A host that depends on both
  packages wires it:

      Raxol.Agent.Reattach.attach(session_id, from_offset, history_policy,
        authorize:
          Raxol.AgentClientProtocol.Ext.AttachPolicy.Bridge.authorizer(
            policy: MyPolicy,
            transport: %{kind: :process, peer: self()}
          ))

  ## Dependency direction (why it lives in THIS package)

  `raxol_agent` does not depend on `raxol_agent_client_protocol`, and this package
  has zero raxol-internal deps. The bridge references only THIS package's Runner /
  Grant / policies and produces a PLAIN closure; the BEAM ctx it receives is a
  duck-typed map, so there is no compile-time reference to `Raxol.Agent.Reattach`
  in either direction. The host (which depends on both) does the wiring.

  ## Fail-closed

  The Runner returns `{:ok, %Grant{}}` (admit) or `{:denied, reason}` (deny) — the
  exact `authorize_fun` contract `Raxol.Agent.Reattach.attach/4` consumes: it
  admits only on `{:ok, _grant}` and maps everything else to
  `{:error, :attach_denied}` (nothing read, nothing tailed), so a denied verdict
  cannot "mostly" admit. `transport` is Connection-sourced knowledge the host MUST
  supply; absent (`nil`) the default `LocalNode` policy denies (`:not_local` →
  `{:denied, :policy_error}`).
  """

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.{Grant, Runner}

  @typedoc """
  The BEAM-local attach ctx built by `Raxol.Agent.Reattach.attach/4`
  (`%{session_id, from_offset, policy, surface: :beam_local}`). Grow-only and
  duck-typed — only `:session_id` is dereferenced hard; the rest default.
  """
  @type beam_ctx :: %{
          required(:session_id) => String.t(),
          optional(:from_offset) => non_neg_integer(),
          optional(:surface) => atom(),
          optional(any()) => any()
        }

  @typedoc "The Runner verdict, which is exactly the `authorize_fun` contract."
  @type verdict :: {:ok, Grant.t()} | {:denied, atom()}

  @doc """
  Build an `authorize_fun` for `Raxol.Agent.Reattach.attach/4`'s `:authorize`
  option that defers to `Ext.AttachPolicy.Runner`.

  Options:

    * `:policy` — the `Ext.AttachPolicy` module (default
      `Ext.AttachPolicy.default_policy/0` = `LocalNode`, deny-by-default).
    * `:transport` — the Connection-sourced transport (`%{kind:, peer:}` | nil);
      NEVER peer-asserted. `LocalNode` denies a nil transport.
    * `:actor` — the audit actor map (`%{"id" => binary}`) | nil.
    * `:capability` — an `RXC1` capability token for the `Token` policy | nil.
    * `:task_supervisor`, `:timeout_ms` — passed through to `Runner.authorize/3`.

  The returned fun reads the BEAM ctx's `:session_id`/`:from_offset`/`:surface`
  and merges the config-supplied `:actor`/`:capability`/`:transport` into the
  CDI-2 Runner ctx, then calls `Runner.authorize/3`. The BEAM ctx's `:policy`
  (the HISTORY policy) is not an attach policy and is deliberately dropped —
  admission is one decision gating both history and live.
  """
  @spec authorizer(keyword()) :: (beam_ctx() -> verdict())
  def authorizer(opts \\ []) when is_list(opts) do
    policy = Keyword.get(opts, :policy) || AttachPolicy.default_policy()
    actor = Keyword.get(opts, :actor)
    capability = Keyword.get(opts, :capability)
    transport = Keyword.get(opts, :transport)
    runner_opts = Keyword.take(opts, [:task_supervisor, :timeout_ms])

    fn beam_ctx ->
      ctx = %{
        session_id: Map.fetch!(beam_ctx, :session_id),
        from_offset: Map.get(beam_ctx, :from_offset, 0),
        surface: Map.get(beam_ctx, :surface, :beam_local),
        actor: actor,
        capability: capability,
        transport: transport
      }

      Runner.authorize(policy, ctx, runner_opts)
    end
  end
end
